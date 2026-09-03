/// A stand-in for the backend, so the sync tests never touch a network.
///
/// It mirrors only the behaviour the app depends on: the 401, the up-to-date
/// short circuit, and idempotent push. Anything past that is the Python
/// suite's job — `shared/pricing-fixtures.json` is what keeps the two engines
/// honest, not this.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeServer {
  /// listId -> the card it will serve.
  final Map<String, Map<String, dynamic>> cards;

  /// Tokens this server considers signed in.
  final Set<String> validTokens;

  /// Set to have every call fail as if there were no signal.
  bool offline = false;

  /// Set to have every call hang past the client's timeout.
  bool hang = false;

  /// Set to have `POST /api/quotes` refuse everything, as it would for a quote
  /// priced against a rate card version this server never published.
  bool rejectQuotes = false;

  /// When set, the server reports this total instead of agreeing with the
  /// device — the §9.4 disagreement path.
  int? serverTotalOverrideSen;

  /// The body of the last quote pushed, so a test can assert what was sent
  /// rather than only what came back.
  List<int>? lastQuoteBody;

  /// Quote ids already accepted, for the idempotency check.
  final Set<String> accepted = {};

  /// Payment id -> the receipt number issued for it. Issued once and handed
  /// back on every retry, because a second number for one payment is a second
  /// receipt for money taken once.
  final Map<String, String> receipts = {};

  /// Order id -> the number issued for it. Issued once and handed back on
  /// every retry, because a second number for one order is a second piece of
  /// paperwork for a sale that happened once.
  final Map<String, String> orderNumbers = {};

  /// Order id -> where the server thinks it is.
  final Map<String, String> orderStatus = {};

  /// Event ids already applied. Idempotency for a status move hangs on the
  /// event, not the order -- an order walks the pipeline many times.
  final Set<String> appliedEvents = {};

  /// The body of the last order pushed, so a test can assert what was sent.
  List<int>? lastOrderBody;

  /// When set, POST /api/orders reports the status it would not apply.
  String? refuseOrderStatusBecause;

  /// When set, POST /api/orders reports these overrides as refused.
  Map<String, String> refuseOverrides = const {};

  /// When set, POST /api/orders/status refuses every move with this reason.
  String? refuseStatusBecause;

  /// customer_key -> the holds this server will serve for them, as a handset
  /// other than this one would have left them.
  final Map<String, List<Map<String, dynamic>>> heldRates = {};

  /// Lock ids already accepted, for the idempotency check.
  final Set<String> acceptedLocks = {};

  /// Prompt ids already accepted.
  final Set<String> acceptedPrompts = {};

  /// Set to have the lock endpoints refuse everything.
  bool rejectLocks = false;

  /// Every request that arrived, in order. Lets a test assert what was *not*
  /// sent — the up-to-date short circuit is only worth anything if the payload
  /// really is skipped.
  final List<http.BaseRequest> seen = [];

  FakeServer({Map<String, Map<String, dynamic>>? cards, Set<String>? tokens})
    : cards = cards ?? {},
      validTokens = tokens ?? {'good-token'};

  http.Client get client => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    seen.add(request);

    if (offline) {
      throw const SocketExceptionLike('no route to host');
    }
    if (hang) {
      await Future<void>.delayed(const Duration(days: 1));
    }

    final path = request.url.path;
    final token = (request.headers['Authorization'] ?? '').replaceFirst(
      'Bearer ',
      '',
    );

    if (path == '/api/auth/login') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['pin'] != '4821') return _json({'detail': 'wrong'}, 401);
      return _json({
        'token': 'good-token',
        'user': {
          'id': 'u1',
          'name': 'Ah Lian',
          'role': 'parttime',
          'language': 'zh',
        },
      });
    }

    if (!validTokens.contains(token)) {
      return _json({'detail': 'sign in required'}, 401);
    }

    if (path == '/api/auth/me') {
      return _json({
        'id': 'u1',
        'name': 'Ah Lian',
        'role': 'parttime',
        'language': 'zh',
      });
    }

    if (path == '/api/bundle') {
      final listId = request.url.queryParameters['list_id'] ?? 'fair';
      final card = cards[listId];
      if (card == null) return _json({'detail': 'no card'}, 404);

      final since = int.tryParse(
        request.url.queryParameters['since_version'] ?? '',
      );
      final version = card['version'] as int;
      if (since != null && since == version) {
        return _json({
          'rate_card_version': version,
          'list_id': listId,
          'payload': null,
          'up_to_date': true,
        });
      }
      return _json({
        'rate_card_version': version,
        'list_id': listId,
        'payload': card,
        'up_to_date': false,
      });
    }

    if (path == '/api/quotes') {
      lastQuoteBody = request.bodyBytes;
      if (rejectQuotes) {
        return _json({'detail': 'no such rate card version'}, 409);
      }

      final body =
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
      final id = body['id'] as String;
      final duplicate = !accepted.add(id);
      final deviceTotal = body['device_total_sen'];
      final serverTotal = serverTotalOverrideSen ?? deviceTotal;
      return _json({
        'quote_id': id,
        'duplicate': duplicate,
        'server_total_sen': serverTotal,
        'device_total_sen': deviceTotal,
        'discrepancies': serverTotal == deviceTotal
            ? <Map<String, dynamic>>[]
            : [
                {
                  'line_id': (body['lines'] as List).first['id'],
                  'server_total_sen': serverTotal,
                  'device_total_sen': deviceTotal,
                  'agreed': false,
                  'detail': null,
                },
              ],
      });
    }

    if (path == '/api/payments') {
      final body =
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
      final id = body['id'] as String;

      // Idempotent, and the receipt number is issued once. A retry gets the
      // same one back, because the customer may already be holding it.
      final existing = receipts[id];
      if (existing != null) {
        return _json({
          'payment_id': id,
          'duplicate': true,
          'receipt_no': existing,
        });
      }
      final issued =
          'R2608-${(receipts.length + 1).toString().padLeft(4, '0')}';
      receipts[id] = issued;
      return _json({
        'payment_id': id,
        'duplicate': false,
        'receipt_no': issued,
      });
    }

    if (path == '/api/orders') {
      final body =
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
      final id = body['id'] as String;
      lastOrderBody = request.bodyBytes;

      // Idempotent, and the number is issued once. A retry gets the same one
      // back, because the customer may already be holding paperwork with it.
      final existing = orderNumbers[id];
      if (existing != null) {
        return _json({
          'order_id': id,
          'duplicate': true,
          'order_no': existing,
          'status_refused_because': null,
          'overrides_refused': <String, dynamic>{},
        });
      }
      final issued =
          'MLK-2608-${(orderNumbers.length + 1).toString().padLeft(4, '0')}';
      orderNumbers[id] = issued;
      orderStatus[id] = 'confirmed';
      return _json({
        'order_id': id,
        'duplicate': false,
        'order_no': issued,
        'status_refused_because': refuseOrderStatusBecause,
        'overrides_refused': refuseOverrides,
      });
    }

    if (path == '/api/orders/status') {
      final body =
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
      final orderId = body['order_id'] as String;
      final eventId = body['event_id'] as String;

      if (appliedEvents.contains(eventId)) {
        return _json({
          'order_id': orderId,
          'duplicate': true,
          'status': orderStatus[orderId] ?? 'confirmed',
          'refused_because': null,
        });
      }

      if (refuseStatusBecause != null) {
        return _json({
          'order_id': orderId,
          'duplicate': false,
          'status': orderStatus[orderId] ?? 'confirmed',
          'refused_because': refuseStatusBecause,
        });
      }

      appliedEvents.add(eventId);
      orderStatus[orderId] = body['to'] as String;
      return _json({
        'order_id': orderId,
        'duplicate': false,
        'status': orderStatus[orderId]!,
        'refused_because': null,
      });
    }

    if (path == '/api/locks' && request.method == 'GET') {
      if (rejectLocks) return _json({'detail': 'nope'}, 500);
      final key = request.url.queryParameters['customer_key'] ?? '';
      return _json({'locks': heldRates[key] ?? const []});
    }

    if (path == '/api/locks') {
      if (rejectLocks) return _json({'detail': 'nope'}, 500);
      final body =
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
      final id = body['id'] as String;
      final duplicate = !acceptedLocks.add(id);

      // A hold for a customer and category this server already holds. Both
      // RM300s are real; the first keeps pricing.
      final key = body['customer_key'] as String;
      final clash = (heldRates[key] ?? const [])
          .cast<Map<String, dynamic>>()
          .where(
            (l) =>
                l['category'] == body['category'] &&
                l['status'] == 'active' &&
                l['id'] != id,
          )
          .toList();

      if (!duplicate && clash.isEmpty) {
        heldRates.putIfAbsent(key, () => []).add({
          'id': id,
          'customer_key': key,
          'category': body['category'],
          'held_rate_card_version': body['held_rate_card_version'],
          'held_discount_pct': body['held_discount_pct'],
          'held_until': body['held_until'],
          'status': body['status'] ?? 'active',
        });
      }

      return _json({
        'lock_id': id,
        'duplicate': duplicate,
        'conflicts_with': clash.isEmpty ? null : clash.first['id'],
      });
    }

    if (path == '/api/deposit-prompts') {
      if (rejectLocks) return _json({'detail': 'nope'}, 500);
      final body =
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
      final id = body['id'] as String;
      return _json({'prompt_id': id, 'duplicate': !acceptedPrompts.add(id)});
    }

    return _json({'detail': 'not found'}, 404);
  }

  http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
      http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
}

/// `SocketException` is `dart:io` and the client catches it by type; in a test
/// what matters is that *something* is thrown from inside the request, so the
/// broad catch is what gets exercised. That catch existing is the point — at a
/// fair the set of things that can go wrong is open-ended.
class SocketExceptionLike implements Exception {
  final String message;
  const SocketExceptionLike(this.message);

  @override
  String toString() => 'SocketExceptionLike: $message';
}
