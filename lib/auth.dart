import 'dart:convert';
import 'dart:io';

import 'package:barmaid/types.dart';
import 'package:endec_json/endec_json.dart';
import 'package:shelf/shelf.dart';

class TokenStore {
  static final _authPattern = RegExp('Bearer (.*)');

  final Map<String, TokenProperties> tokens;
  TokenStore._(this.tokens);

  factory TokenStore.read(String filePath) =>
      TokenStore._(fromJson(TokenProperties.endec.mapOf(), jsonDecode(File('tokens.json').readAsStringSync())));

  String? getToken(Request request) {
    final authHeader = request.headers[HttpHeaders.authorizationHeader];
    if (authHeader == null) return null;

    return _authPattern.firstMatch(authHeader)?[1];
  }

  TokenProperties getTokenProps(Request request) {
    return tokens[getToken(request)!]!;
  }

  Response? checkAuth(Request request, [String? package]) {
    final token = getToken(request);
    if (token == null) {
      return Response.unauthorized(
        null,
        headers: {HttpHeaders.wwwAuthenticateHeader: 'Bearer realm="pub", message="no token provided"'},
      );
    }

    if (!tokens.containsKey(token)) {
      return Response.unauthorized(
        null,
        headers: {HttpHeaders.wwwAuthenticateHeader: 'Bearer realm="pub", message="invalid token"'},
      );
    }

    if (package == null) {
      return null;
    }

    final tokenProps = tokens[token]!;
    if (tokenProps.isAuthorized(package)) return null;

    return Response.forbidden(
      null,
      headers: {
        HttpHeaders.wwwAuthenticateHeader: 'Bearer realm="pub", message="insufficient authorization for package"'
      },
    );
  }
}
