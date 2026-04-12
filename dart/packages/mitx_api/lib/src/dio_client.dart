import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:logging/logging.dart';

import 'constants.dart';

export 'constants.dart';

final _log = Logger('http');

class DioClient {
  DioClient({CookieJar? cookieJar}) : _cookieJar = cookieJar ?? CookieJar() {
    _mitxOnlineDio = _buildDio(kMitxOnlineBaseUrl);
    _lmsDio = _buildDio(kLmsBaseUrl);
    // Insert after CookieManager (index 0) so it runs second on requests,
    // appending raw LMS cookies that dart:io's Cookie class can't represent.
    _lmsDio.interceptors.insert(
      1,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (_rawLmsCookies.isNotEmpty) {
            final existing = options.headers['cookie'] as String? ?? '';
            final rawPart = _rawLmsCookies.entries
                .map((e) => '${e.key}=${e.value}')
                .join('; ');
            options.headers['cookie'] =
                existing.isEmpty ? rawPart : '$existing; $rawPart';
          }
          handler.next(options);
        },
      ),
    );
  }

  final CookieJar _cookieJar;
  late final Dio _mitxOnlineDio;
  late final Dio _lmsDio;
  bool _authInterceptorAttached = false;

  /// Raw name→value pairs for LMS cookies whose values dart:io's Cookie class
  /// rejects (typically JWT tokens). Populated by [establishLmsSession],
  /// appended to every LMS request via the raw-cookie interceptor above.
  Map<String, String> _rawLmsCookies = {};

  Dio get mitxOnline => _mitxOnlineDio;
  Dio get lms => _lmsDio;
  CookieJar get cookieJar => _cookieJar;

  /// Expose raw LMS cookies so login_screen can inject them into WebViews.
  Map<String, String> get rawLmsCookies => Map.unmodifiable(_rawLmsCookies);

  Dio _buildDio(String baseUrl) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
        headers: {'Accept': 'application/json'},
      ),
    );
    dio.interceptors.add(CookieManager(_cookieJar));
    dio.interceptors.add(_diagnosticsInterceptor());
    return dio;
  }

  InterceptorsWrapper _diagnosticsInterceptor() {
    return InterceptorsWrapper(
      onRequest: (options, handler) async {
        final jarCookies = await _cookieJar.loadForRequest(options.uri);
        final names = [
          ...jarCookies.map((c) => c.name),
          if (_rawLmsCookies.isNotEmpty &&
              options.uri.host.contains('learn.mit.edu'))
            ..._rawLmsCookies.keys,
        ].join(', ');
        _log.fine(
          '→ ${options.method} ${options.uri}  '
          'cookies=[${names.isEmpty ? "(none)" : names}]',
        );
        handler.next(options);
      },
      onResponse: (response, handler) {
        _log.fine(
          '← ${response.statusCode} ${response.requestOptions.method} '
          '${response.realUri}',
        );
        handler.next(response);
      },
      onError: (err, handler) {
        _log.fine(
          '✗ ${err.response?.statusCode} ${err.requestOptions.method} '
          '${err.requestOptions.uri}',
        );
        handler.next(err);
      },
    );
  }

  /// Walks the LMS OAuth redirect chain using a bare Dio instance that has
  /// no CookieManager, because dart:io's Cookie class rejects characters in
  /// LMS JWT cookie values. Cookies are tracked as raw header strings,
  /// bypassing dart:io validation entirely.
  ///
  /// After the chain completes:
  /// - Cookies whose values dart:io accepts are saved to [_cookieJar].
  /// - Cookies whose values dart:io rejects are stored in [_rawLmsCookies]
  ///   and appended to every subsequent LMS request via interceptor.
  Future<void> establishLmsSession() async {
    final bare = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );

    // Seed the raw cookie store from the existing Dio jar.
    // For each (host, path) pair: load cookies and merge into store[host].
    // We need to load from multiple paths because Keycloak cookies are stored
    // at /realms/olapps/ rather than /. Some Keycloak cookies end up under
    // mitxonline.mit.edu (due to redirect routing during login) and need to
    // be forwarded to sso.ol.mit.edu.
    final store = <String, Map<String, String>>{};
    final seedEntries = [
      ('courses.learn.mit.edu', '/'),
      ('mitxonline.mit.edu', '/'),
      ('mitxonline.mit.edu', '/realms/olapps/'),
      ('sso.ol.mit.edu', '/'),
      ('sso.ol.mit.edu', '/realms/olapps/'),
    ];
    for (final (host, path) in seedEntries) {
      final jarCookies =
          await _cookieJar.loadForRequest(Uri.parse('https://$host$path'));
      final existing = store.putIfAbsent(host, () => {});
      for (final c in jarCookies) {
        existing[c.name] = c.value;
      }
    }
    // Forward Keycloak persistent cookies to SSO if they ended up under
    // mitxonline (happens because CookieManager routes the SSO redirect
    // response through the mitxOnline Dio instance).
    final ssoStore = store.putIfAbsent('sso.ol.mit.edu', () => {});
    final mitxStore = store['mitxonline.mit.edu'] ?? {};
    for (final key in ['KEYCLOAK_IDENTITY', 'KEYCLOAK_SESSION']) {
      if (mitxStore.containsKey(key) && !ssoStore.containsKey(key)) {
        ssoStore[key] = mitxStore[key]!;
      }
    }
    // Also seed from previously stored raw LMS cookies.
    if (_rawLmsCookies.isNotEmpty) {
      store.putIfAbsent('courses.learn.mit.edu', () => {})
          .addAll(_rawLmsCookies);
    }

    var nextUrl = '$kLmsBaseUrl/auth/login/ol-oauth2/?auth_entry=login';
    for (var hop = 0; hop < 15; hop++) {
      final uri = Uri.parse(nextUrl);

      // Build Cookie header from the raw store for this host.
      final hostCookies = store[uri.host] ?? {};
      final cookieHeader =
          hostCookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

      final resp = await bare.getUri<dynamic>(
        uri,
        options: Options(
          followRedirects: false,
          validateStatus: (s) => s != null && s < 400,
          headers: {
            if (cookieHeader.isNotEmpty) 'cookie': cookieHeader,
          },
        ),
      );

      // Parse Set-Cookie response headers into the raw store.
      for (final raw in resp.headers['set-cookie'] ?? <String>[]) {
        _parseSetCookieInto(uri, raw, store);
      }

      final status = resp.statusCode ?? 0;
      final location = resp.headers.value('location');
      _log.info(
        'establishLmsSession[$hop]: $status ${uri.host}${uri.path}'
        ' → ${location ?? "(done)"}',
      );

      if (status >= 300 && status < 400 && location != null) {
        nextUrl = location.startsWith('http')
            ? location
            : uri.resolve(location).toString();
      } else {
        break;
      }
    }

    bare.close();

    // Persist cookies back: save parseable ones to the jar, store the rest
    // in _rawLmsCookies so the interceptor can attach them to LMS requests.
    final newRaw = <String, String>{};
    for (final domainEntry in store.entries) {
      final host = domainEntry.key;
      final uri = Uri.parse('https://$host/');
      for (final e in domainEntry.value.entries) {
        try {
          final c = Cookie(e.key, e.value)
            ..domain = host
            ..path = '/';
          await _cookieJar.saveFromResponse(uri, [c]);
        } on Object {
          if (host == 'courses.learn.mit.edu') {
            newRaw[e.key] = e.value;
          }
        }
      }
    }
    _rawLmsCookies = newRaw;

    if (newRaw.isNotEmpty) {
      _log.info(
        'establishLmsSession: ${newRaw.length} raw LMS cookies '
        '(dart:io parse failure): ${newRaw.keys.join(", ")}',
      );
    }
    _log.info('establishLmsSession: complete');
  }

  /// Parses a single Set-Cookie header string into [store].
  /// Extracts name, value, and optional Domain attribute.
  static void _parseSetCookieInto(
    Uri requestUri,
    String raw,
    Map<String, Map<String, String>> store,
  ) {
    final parts = raw.split(';');
    if (parts.isEmpty) return;
    final nameValue = parts.first;
    final eq = nameValue.indexOf('=');
    if (eq <= 0) return;
    final name = nameValue.substring(0, eq).trim();
    final value = nameValue.substring(eq + 1);

    var host = requestUri.host;
    for (final attr in parts.skip(1)) {
      final lower = attr.trim().toLowerCase();
      if (lower.startsWith('domain=')) {
        host = attr.trim().substring(7);
        if (host.startsWith('.')) host = host.substring(1);
        break;
      }
    }

    store.putIfAbsent(host, () => {})[name] = value;
  }

  /// Attach a 401 interceptor to the LMS Dio instance.
  void addAuthInterceptor({required void Function() onAuthFailed}) {
    if (_authInterceptorAttached) return;
    _authInterceptorAttached = true;
    _lmsDio.interceptors.add(
      InterceptorsWrapper(
        onError: (err, handler) async {
          if (err.response?.statusCode != 401) {
            return handler.next(err);
          }
          try {
            await establishLmsSession();
            final retryResponse =
                await _lmsDio.fetch<dynamic>(err.requestOptions);
            return handler.resolve(retryResponse);
          } on Object {
            onAuthFailed();
            return handler.next(err);
          }
        },
      ),
    );
  }
}
