/// Talking to the server.
///
/// Everything here is written around one rule (CLAUDE.md 9): **offline is the
/// default, not a fallback.** So:
///
/// - Nothing throws a raw socket exception at a caller. A network failure comes
///   back as [SyncOutcome.offline], which the UI shows as a quiet line rather
///   than a dialog.
/// - Every request has a short timeout. A fair's connection does not fail, it
///   *hangs*, and a spinner that never resolves is worse than a failure.
/// - There is no call the app must make before it can quote. Sign-in happens
///   once, before the fair; after that the handset works for days with nothing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// How long to wait before deciding there is no usable connection.
///
/// Deliberately short. At a fair the phone often has one bar and a captive
/// portal; the useful answer is "not now", quickly, so the app can carry on.
const Duration kRequestTimeout = Duration(seconds: 8);

/// Why a call did not produce data.
enum SyncFailure {
  /// No usable network. Not an error the user did anything about.
  offline,

  /// The server answered, and said this handset is not signed in. Either the
  /// session was revoked or the token is gone.
  unauthenticated,

  /// Signed in, but not allowed. Staff trying to publish a price, say.
  forbidden,

  /// The server answered with something unexpected. Worth surfacing, because
  /// it usually means the app and the server are different versions.
  serverError,
}

/// The result of a call: data, or a reason there is none.
///
/// A sealed result rather than exceptions, because at every call site here the
/// "no data" branch is normal operation and has to be handled. An exception is
/// too easy to leave uncaught, and an uncaught one at a fair is a crash in
/// front of a customer.
sealed class SyncResult<T> {
  const SyncResult();

  bool get ok => this is SyncOk<T>;

  T? get valueOrNull => switch (this) {
    SyncOk<T>(:final value) => value,
    _ => null,
  };
}

class SyncOk<T> extends SyncResult<T> {
  final T value;
  const SyncOk(this.value);
}

class SyncFailed<T> extends SyncResult<T> {
  final SyncFailure failure;

  /// For the log and the diagnostics screen. Never shown raw to a part-timer.
  final String detail;

  const SyncFailed(this.failure, [this.detail = '']);
}

/// What the server said about the current session.
class Identity {
  final String id;
  final String name;
  final String role;
  final String language;

  const Identity({
    required this.id,
    required this.name,
    required this.role,
    required this.language,
  });

  factory Identity.fromJson(Map<String, dynamic> json) => Identity(
    id: json['id'] as String,
    name: json['name'] as String,
    role: json['role'] as String,
    language: json['language'] as String? ?? 'zh',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'role': role,
    'language': language,
  };

  /// §3. Only rate visibility differs between roles — there is one wizard, not
  /// three.
  bool get maySeeRates => role == 'admin' || role == 'staff';
  bool get mayPublishRates => role == 'admin';
}

/// A signed-in session: the token, and who it belongs to.
class Credentials {
  final String token;
  final Identity user;

  const Credentials({required this.token, required this.user});

  Map<String, dynamic> toJson() => {'token': token, 'user': user.toJson()};

  factory Credentials.fromJson(Map<String, dynamic> json) => Credentials(
    token: json['token'] as String,
    user: Identity.fromJson(json['user'] as Map<String, dynamic>),
  );
}

/// One rate card, as pulled.
class BundleResponse {
  final int version;
  final String listId;

  /// Null when the device is already current — §9.1 does not spend a fair's
  /// connection re-sending a card the phone already has.
  final Map<String, dynamic>? payload;
  final bool upToDate;

  const BundleResponse({
    required this.version,
    required this.listId,
    required this.payload,
    required this.upToDate,
  });
}

/// The server's verdict on a pushed quote.
class PushResponse {
  final String quoteId;

  /// True when the server had already accepted this exact quote. **A success**,
  /// not an error: the device cannot know whether the first attempt landed, and
  /// treating a retry as a failure would have the outbox retry forever.
  final bool duplicate;
  final int? serverTotalSen;
  final int? deviceTotalSen;

  /// Non-empty means the two engines disagreed. The order was still accepted.
  final List<Map<String, dynamic>> discrepancies;

  const PushResponse({
    required this.quoteId,
    required this.duplicate,
    required this.serverTotalSen,
    required this.deviceTotalSen,
    required this.discrepancies,
  });

  bool get agreed => discrepancies.isEmpty;
}

/// What the server made of a pushed payment.
class ReceiptIssued {
  final String paymentId;

  /// True when the server had already accepted this payment. **A success**:
  /// the same RM300 was not taken twice, and the receipt number below is the
  /// one it was given the first time.
  final bool duplicate;

  /// Issued by the server and never by the device. Until this arrives the app
  /// shows "pending sync" rather than a number it invented.
  final String receiptNo;

  const ReceiptIssued({
    required this.paymentId,
    required this.duplicate,
    required this.receiptNo,
  });
}

/// The server's answer to a pushed order.
class OrderAccepted {
  final String orderId;

  /// True when the server had already accepted this exact order. **A success**:
  /// one deposit produced one order, and the number below is the one it was
  /// given the first time.
  final bool duplicate;

  /// Issued by the server and never by the device. Until this arrives the app
  /// shows "pending sync" rather than a number it invented.
  final String orderNo;

  /// Set when the server would not have allowed the status the device pushed.
  /// The order was still accepted — the money is taken — and this says what it
  /// was left at instead.
  final String? statusRefusedBecause;

  /// Overrides the server would not store, by id. Their lines keep the totals
  /// they arrived with.
  final Map<String, String> overridesRefused;

  const OrderAccepted({
    required this.orderId,
    required this.duplicate,
    required this.orderNo,
    this.statusRefusedBecause,
    this.overridesRefused = const {},
  });

  /// True when everything the device sent was taken as sent.
  bool get fullyAccepted =>
      statusRefusedBecause == null && overridesRefused.isEmpty;
}

/// The server's answer to one step along the pipeline.
class StatusAccepted {
  final String orderId;

  /// True when this exact move had already been applied.
  final bool duplicate;

  /// Where the order actually is now — which is where it was, if refused.
  final String status;

  /// Why the server would not make the move, null when it did.
  final String? refusedBecause;

  const StatusAccepted({
    required this.orderId,
    required this.duplicate,
    required this.status,
    this.refusedBecause,
  });

  bool get accepted => refusedBecause == null;
}

class ApiClient {
  final Uri baseUrl;
  final http.Client _http;
  final Duration timeout;

  ApiClient({required this.baseUrl, http.Client? client, Duration? timeout})
    : _http = client ?? http.Client(),
      timeout = timeout ?? kRequestTimeout;

  void close() => _http.close();

  Uri _url(String path, [Map<String, String>? query]) =>
      baseUrl.replace(path: path, queryParameters: query);

  Map<String, String> _headers(String? token) => {
    'Content-Type': 'application/json; charset=utf-8',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  /// Runs a request and turns everything that can go wrong into a [SyncResult].
  ///
  /// The catch is broad on purpose. Between DNS, TLS, captive portals and a
  /// phone switching from wifi to 4G mid-request, the set of exceptions is
  /// open-ended, and every one of them means the same thing to the app: not
  /// now, carry on offline.
  Future<SyncResult<T>> _send<T>(
    Future<http.Response> Function() request,
    T Function(Map<String, dynamic>) parse,
  ) async {
    late http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      return const SyncFailed(SyncFailure.offline, 'timed out');
    } on SocketException catch (e) {
      return SyncFailed(SyncFailure.offline, e.message);
    } on http.ClientException catch (e) {
      return SyncFailed(SyncFailure.offline, e.message);
    } catch (e) {
      return SyncFailed(SyncFailure.offline, '$e');
    }

    if (response.statusCode == 401) {
      return const SyncFailed(SyncFailure.unauthenticated, 'sign in required');
    }
    if (response.statusCode == 403) {
      return const SyncFailed(SyncFailure.forbidden, 'not allowed');
    }
    if (response.statusCode >= 400) {
      return SyncFailed(
        SyncFailure.serverError,
        'HTTP ${response.statusCode}: ${response.body}',
      );
    }

    try {
      // A 204 has no body by definition — logout is one. Parsing it would fail
      // and report a server error for a call that worked perfectly.
      if (response.statusCode == 204 || response.bodyBytes.isEmpty) {
        return SyncOk(parse(const {}));
      }
      // utf8.decode rather than response.body: without a charset in the header
      // http falls back to latin-1, which turns every Chinese room name into
      // mojibake.
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return SyncOk(parse(decoded as Map<String, dynamic>));
    } catch (e) {
      return SyncFailed(SyncFailure.serverError, 'unreadable response: $e');
    }
  }

  /// Signs a handset in. Once, before the fair.
  Future<SyncResult<Credentials>> login({
    required String phone,
    required String pin,
    required String deviceId,
    String? deviceLabel,
  }) => _send(
    () => _http.post(
      _url('/api/auth/login'),
      headers: _headers(null),
      body: jsonEncode({
        'phone': phone,
        'pin': pin,
        'device_id': deviceId,
        'device_label': ?deviceLabel,
      }),
    ),
    Credentials.fromJson,
  );

  /// Who the server thinks this token is. Used on reconnect to notice a
  /// revoked session, and to pick up a role changed in the office.
  Future<SyncResult<Identity>> me(String token) => _send(
    () => _http.get(_url('/api/auth/me'), headers: _headers(token)),
    Identity.fromJson,
  );

  /// The reference-data pull. §9.1.
  ///
  /// [sinceVersion] is what the device already holds. When it matches, the
  /// server sends no payload at all.
  Future<SyncResult<BundleResponse>> bundle({
    required String token,
    required String listId,
    int? sinceVersion,
  }) => _send(
    () => _http.get(
      _url('/api/bundle', {
        'list_id': listId,
        if (sinceVersion != null) 'since_version': '$sinceVersion',
      }),
      headers: _headers(token),
    ),
    (json) => BundleResponse(
      version: json['rate_card_version'] as int,
      listId: json['list_id'] as String,
      payload: json['payload'] as Map<String, dynamic>?,
      upToDate: json['up_to_date'] as bool,
    ),
  );

  /// Pushes one quote. §9.2 — idempotent on the quote's own id, so this is
  /// safe to call again after any failure.
  Future<SyncResult<PushResponse>> pushQuote(
    String token,
    Map<String, dynamic> quote,
  ) => _send(
    () => _http.post(
      _url('/api/quotes'),
      headers: _headers(token),
      body: jsonEncode(quote),
    ),
    (json) => PushResponse(
      quoteId: json['quote_id'] as String,
      duplicate: json['duplicate'] as bool,
      serverTotalSen: json['server_total_sen'] as int?,
      deviceTotalSen: json['device_total_sen'] as int?,
      discrepancies: ((json['discrepancies'] as List?) ?? const [])
          .cast<Map<String, dynamic>>(),
    ),
  );

  /// Pushes one payment. §6.4, §9.2.
  ///
  /// Idempotent on the payment's own id, and a retry gets back the **same**
  /// receipt number — the customer may already be holding a printed one.
  Future<SyncResult<ReceiptIssued>> pushPayment(
    String token,
    Map<String, dynamic> payment,
  ) => _send(
    () => _http.post(
      _url('/api/payments'),
      headers: _headers(token),
      body: jsonEncode(payment),
    ),
    (json) => ReceiptIssued(
      paymentId: json['payment_id'] as String,
      duplicate: json['duplicate'] as bool,
      receiptNo: json['receipt_no'] as String,
    ),
  );

  /// Pushes a confirmed order, and gets back the number the server issued.
  ///
  /// Idempotent on the order's own id, and a retry gets back the **same**
  /// number — the customer may already be holding paperwork with it on.
  Future<SyncResult<OrderAccepted>> pushOrder(
    String token,
    Map<String, dynamic> order,
  ) => _send(
    () => _http.post(
      _url('/api/orders'),
      headers: _headers(token),
      body: jsonEncode(order),
    ),
    (json) => OrderAccepted(
      orderId: json['order_id'] as String,
      duplicate: json['duplicate'] as bool,
      orderNo: json['order_no'] as String,
      statusRefusedBecause: json['status_refused_because'] as String?,
      overridesRefused: {
        for (final e
            in (json['overrides_refused'] as Map<String, dynamic>? ?? {})
                .entries)
          e.key: e.value as String,
      },
    ),
  );

  /// Pushes one step along the pipeline.
  ///
  /// Idempotent on the **event id**, not the order — an order walks the
  /// pipeline many times, and keying on the order would make the second
  /// legitimate move look like a retry of the first.
  ///
  /// A refusal comes back as a successful response with `refusedBecause` set,
  /// not as a transport failure. The device may be hours ahead of the server
  /// and needs to know *which* move was rejected rather than lose the batch.
  Future<SyncResult<StatusAccepted>> pushStatusChange(
    String token,
    Map<String, dynamic> change,
  ) => _send(
    () => _http.post(
      _url('/api/orders/status'),
      headers: _headers(token),
      body: jsonEncode(change),
    ),
    (json) => StatusAccepted(
      orderId: json['order_id'] as String,
      duplicate: json['duplicate'] as bool,
      status: json['status'] as String,
      refusedBecause: json['refused_because'] as String?,
    ),
  );

  /// Publishes a rate card. Admin only, and refused by the server otherwise —
  /// the check here is a courtesy, not the control.
  Future<SyncResult<Map<String, dynamic>>> publishCard({
    required String token,
    required String listId,
    required Map<String, dynamic> payload,
  }) => _send(
    () => _http.post(
      _url('/api/rate-cards'),
      headers: _headers(token),
      body: jsonEncode({'list_id': listId, 'payload': payload}),
    ),
    (json) => json,
  );

  /// Ends this handset's session on the server.
  Future<SyncResult<Map<String, dynamic>>> logout(String token) => _send(
    () => _http.post(_url('/api/auth/logout'), headers: _headers(token)),
    // 204, so there is no body to read; an empty map keeps the shape.
    (json) => json,
  );
}
