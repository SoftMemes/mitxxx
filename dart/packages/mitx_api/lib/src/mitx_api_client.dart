import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import 'dio_client.dart';

final _log = Logger('mitx_api');

class AuthError implements Exception {
  AuthError(this.message);
  final String message;
  @override
  String toString() => 'AuthError: $message';
}

/// High-level MITx API client with programmatic login and all data API methods.
///
/// Inject any [DioClient] — the Flutter app passes one backed by
/// FlutterSecureStorage; the CLI passes one backed by FileStorage.
class MitxApiClient {
  MitxApiClient(this._client);

  final DioClient _client;

  // ---------------------------------------------------------------------------
  // Authentication — 3-stage OAuth2
  // (ported from python-tools/mitx-client/client.py)
  // ---------------------------------------------------------------------------

  static final _kcLoginActionPattern =
      RegExp(r'"loginAction":\s*"(https://[^"]+)"');

  String _extractKcLoginAction(String html) {
    final match = _kcLoginActionPattern.firstMatch(html);
    if (match == null) {
      throw AuthError(
        'Could not find Keycloak loginAction in page. '
        'The login page HTML may have changed.',
      );
    }
    // Keycloak JSON-escapes forward slashes as \/
    return match.group(1)!.replaceAll(r'\/', '/');
  }

  /// Walk a redirect chain manually, picking the right Dio instance per hop
  /// based on host. Returns the final non-redirect response.
  ///
  /// When [CookieManager] throws on a hop because the server set a JWT cookie
  /// with characters that dart:io rejects, we recover the response, save any
  /// parseable cookies ourselves, and continue the chain.
  Future<Response<String>> _followRedirects(
    String startUrl, {
    int maxHops = 15,
  }) async {
    String nextUrl = startUrl;
    for (var hop = 0; hop < maxHops; hop++) {
      final uri = Uri.parse(nextUrl);
      // Use mitxOnline Dio for mitxonline.mit.edu, lms Dio for everything else
      // (LMS, Keycloak — they all share the same cookie jar).
      final dio =
          uri.host == 'mitxonline.mit.edu' ? _client.mitxOnline : _client.lms;

      final resp = await dio.getUri<String>(
        uri,
        options: Options(
          followRedirects: false,
          validateStatus: (s) => s != null && s < 400,
          responseType: ResponseType.plain,
        ),
      );

      final status = resp.statusCode ?? 0;
      final location = resp.headers.value('location');
      _log.fine('_followRedirects[$hop]: $status ${uri.host}${uri.path} → ${location ?? "(done)"}');
      if (status >= 300 && status < 400 && location != null) {
        nextUrl = location.startsWith('http')
            ? location
            : uri.resolve(location).toString();
      } else {
        return resp;
      }
    }
    throw AuthError('Too many redirects during auth flow');
  }

  /// POST [data] to [url] as form-urlencoded, then follow any redirect chain.
  Future<Response<String>> _postFollowRedirects(
    String url,
    Map<String, String> data, {
    int maxHops = 15,
  }) async {
    final uri = Uri.parse(url);
    final dio =
        uri.host == 'mitxonline.mit.edu' ? _client.mitxOnline : _client.lms;

    final resp = await dio.postUri<String>(
      uri,
      data: data,
      options: Options(
        followRedirects: false,
        validateStatus: (s) => s != null && s < 400,
        contentType: 'application/x-www-form-urlencoded',
        responseType: ResponseType.plain,
      ),
    );

    final status = resp.statusCode ?? 0;
    final location = resp.headers.value('location');
    _log.fine('_postFollowRedirects: $status ${uri.host}${uri.path} → ${location ?? "(done)"}');
    if (status >= 300 && status < 400 && location != null) {
      final nextUrl = location.startsWith('http')
          ? location
          : uri.resolve(location).toString();
      return _followRedirects(nextUrl, maxHops: maxHops - 1);
    }
    return resp;
  }

  /// Perform the full 3-stage auth flow:
  ///   1. GET mitxonline/login/ → follow redirects → land on Keycloak SPA
  ///   2a. POST username to Keycloak loginAction URL
  ///   2b. POST password to new loginAction URL
  ///   3. LMS OAuth2 handshake (via DioClient.establishLmsSession)
  ///
  /// Returns the authenticated user map on success, throws [AuthError] on failure.
  Future<Map<String, dynamic>> login(String email, String password) async {
    _log.info('login: starting 3-stage auth for $email');

    // Stage 1: GET mitxonline/login/, follow redirects to Keycloak SPA
    final stage1 = await _followRedirects('$kMitxOnlineBaseUrl/login/');
    final actionUrl1 = _extractKcLoginAction(stage1.data ?? '');
    _log.info('login: stage 1 complete, loginAction found');

    // Stage 2a: POST username to Keycloak (step 1 of 2-step login)
    final stage2a = await _postFollowRedirects(
      actionUrl1,
      {'username': email},
    );
    if ((stage2a.statusCode ?? 0) != 200) {
      throw AuthError(
        'Keycloak username step failed with status ${stage2a.statusCode}',
      );
    }
    final actionUrl2 = _extractKcLoginAction(stage2a.data ?? '');
    _log.info('login: stage 2a complete, got password action URL');

    // Stage 2b: POST password to new action URL
    final stage2b = await _postFollowRedirects(
      actionUrl2,
      {'password': password, 'credentialId': ''},
    );
    if ((stage2b.statusCode ?? 0) >= 400) {
      throw AuthError(
        'Keycloak password step failed with status ${stage2b.statusCode}',
      );
    }
    _log.info('login: stage 2b complete');

    // Verify mitxonline session
    final user = await currentUser();
    if (user['is_authenticated'] != true) {
      throw AuthError(
        'mitxonline session not established after OAuth callback',
      );
    }
    _log.info('login: mitxonline verified, user=${user['username']}');

    // Stage 3: Establish LMS session
    await _client.establishLmsSession();
    _log.info('login: LMS session established, login complete');

    return user;
  }

  // ---------------------------------------------------------------------------
  // Session check / resume
  // ---------------------------------------------------------------------------

  Future<bool> isAuthenticated() async {
    try {
      final user = await currentUser();
      return user['is_authenticated'] == true;
    } on Object {
      return false;
    }
  }

  /// Ensure the LMS session is valid. LMS JWT cookies are short-lived; if
  /// only the mitxonline session survived (e.g. loaded from a persisted
  /// cookie jar on a subsequent CLI invocation), re-establish the LMS session
  /// via the OAuth redirect chain.
  Future<void> ensureLmsSession() async {
    _log.info('ensureLmsSession: refreshing LMS cookies');
    await _client.establishLmsSession();
  }

  // ---------------------------------------------------------------------------
  // mitxonline.mit.edu APIs
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> currentUser() async {
    final resp = await _client.mitxOnline
        .get<Map<String, dynamic>>('/api/v0/users/current_user/');
    return resp.data!;
  }

  /// The learn.mit.edu v3 proxy (`/mitxonline/api/v3/enrollments/`) returns
  /// a trimmed `run.course` (no `feature_image_src`, `description`, or
  /// `page_url`), so we stay on the mitxonline v1 endpoint which returns
  /// everything we need in one round trip.
  Future<List<dynamic>> enrollments() async {
    final resp = await _client.mitxOnline
        .get<List<dynamic>>('/api/v1/enrollments/');
    return resp.data!;
  }

  // ---------------------------------------------------------------------------
  // LMS (courses.learn.mit.edu) APIs
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> courseMetadata(String courseId) async {
    final resp = await _client.lms
        .get<Map<String, dynamic>>('/api/course_home/course_metadata/$courseId');
    return resp.data!;
  }

  Future<Map<String, dynamic>> courseOutline(String courseId) async {
    final resp = await _client.lms.get<Map<String, dynamic>>(
      '/api/learning_sequences/v1/course_outline/$courseId',
    );
    return resp.data!;
  }

  Future<Map<String, dynamic>> sequence(String blockId) async {
    final resp = await _client.lms
        .get<Map<String, dynamic>>('/api/courseware/sequence/$blockId');
    return resp.data!;
  }

  Future<String> xblockHtml(String blockId) async {
    final resp = await _client.lms.get<String>(
      '/xblock/$blockId',
      options: Options(responseType: ResponseType.plain),
    );
    return resp.data!;
  }

  Future<String> transcript(
    String courseId,
    String videoBlockId, {
    String lang = 'en',
  }) async {
    final path =
        '/courses/$courseId/xblock/$videoBlockId/handler/transcript/translation/$lang';
    final resp = await _client.lms.get<String>(
      path,
      options: Options(responseType: ResponseType.plain),
    );
    return resp.data!;
  }
}
