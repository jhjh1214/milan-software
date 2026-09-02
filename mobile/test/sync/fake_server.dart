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

  /// Quote ids already accepted, for the idempotency check.
  final Set<String> accepted = {};

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
      final body =
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
      final id = body['id'] as String;
      final duplicate = !accepted.add(id);
      return _json({
        'quote_id': id,
        'duplicate': duplicate,
        'server_total_sen': body['device_total_sen'],
        'device_total_sen': body['device_total_sen'],
        'discrepancies': <Map<String, dynamic>>[],
      });
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
