import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import 'constants.dart';
import 'cookie_store.dart';

export 'constants.dart';
export 'cookie_store.dart';

final _log = Logger('http');

class DioClient {
  DioClient._(this._store, Map<String, Map<String, String>> cookies)
      : _cookies = cookies {
    _mitxOnlineDio = _buildDio(kMitxOnlineBaseUrl);
    _lmsDio = _buildDio(kLmsBaseUrl);
    _learnApiDio = _buildDio(kLearnApiBaseUrl);
  }

  /// Async factory — loads cookies from [store] before constructing.
  static Future<DioClient> create(CookieStore store) async {
    final cookies = await store.loadAll();
    return DioClient._(store, cookies);
  }

  final CookieStore _store;

  /// In-memory cookie store: host → {name → value}.
  /// Updated by the response interceptor and persisted via [_store].
  Map<String, Map<String, String>> _cookies;

  late final Dio _mitxOnlineDio;
  late final Dio _lmsDio;
  late final Dio _learnApiDio;
  bool _authInterceptorAttached = false;

  Dio get mitxOnline => _mitxOnlineDio;
  Dio get lms => _lmsDio;
  Dio get learnApi => _learnApiDio;

  /// Returns true if any cookies are stored (i.e. the user has logged in before).
  bool get hasCookies => _cookies.isNotEmpty;

  /// Returns merged cookies for [host], including parent-domain matches.
  ///
  /// A cookie stored under `learn.mit.edu` matches a request to
  /// `courses.learn.mit.edu` (domain-suffix rule, RFC 6265 §5.1.3).
  Map<String, String> cookiesForHost(String host) {
    final result = <String, String>{};
    for (final entry in _cookies.entries) {
      final storedHost = entry.key;
      if (host == storedHost || host.endsWith('.$storedHost')) {
        result.addAll(entry.value);
      }
    }
    return Map.unmodifiable(result);
  }

  Dio _buildDio(String baseUrl) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
        headers: {'Accept': 'application/json'},
      ),
    );
    dio.interceptors.add(_cookieInterceptor());
    dio.interceptors.add(_diagnosticsInterceptor());
    return dio;
  }

  /// Cookie interceptor: reads from / writes to [_cookies] as raw strings.
  /// No dart:io Cookie parsing is used.
  InterceptorsWrapper _cookieInterceptor() {
    return InterceptorsWrapper(
      onRequest: (options, handler) {
        final hostCookies = cookiesForHost(options.uri.host);
        if (hostCookies.isNotEmpty) {
          options.headers['cookie'] = hostCookies.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; ');
        }
        handler.next(options);
      },
      onResponse: (response, handler) {
        _processSetCookieHeaders(response.requestOptions.uri, response.headers);
        handler.next(response);
      },
      onError: (err, handler) {
        final resp = err.response;
        if (resp != null) {
          _processSetCookieHeaders(
              err.requestOptions.uri, resp.headers);
        }
        handler.next(err);
      },
    );
  }

  void _processSetCookieHeaders(Uri requestUri, Headers headers) {
    final setCookies = headers['set-cookie'];
    if (setCookies == null || setCookies.isEmpty) return;
    var changed = false;
    for (final raw in setCookies) {
      if (_parseSetCookieInto(requestUri, raw, _cookies)) {
        changed = true;
      }
    }
    if (changed) {
      _store.saveAll(_cookies);
    }
  }

  InterceptorsWrapper _diagnosticsInterceptor() {
    return InterceptorsWrapper(
      onRequest: (options, handler) {
        final hostCookies = cookiesForHost(options.uri.host);
        final names = hostCookies.isEmpty ? '(none)' : hostCookies.keys.join(', ');
        _log.fine(
          '→ ${options.method} ${options.uri}  cookies=[$names]',
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

  /// Walks the LMS OAuth redirect chain with a bare Dio instance.
  /// Cookies are tracked entirely as raw header strings — no dart:io parsing.
  ///
  /// Seeds from the current in-memory [_cookies], then writes results back
  /// to both [_cookies] and [_store].
  Future<void> establishLmsSession() async {
    final bare = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );

    // Seed the hop-store from the current in-memory cookie map.
    // Deep-copy so we don't mutate _cookies mid-redirect.
    final store = <String, Map<String, String>>{};
    for (final entry in _cookies.entries) {
      store[entry.key] = Map<String, String>.from(entry.value);
    }

    // Forward Keycloak cookies to SSO if they ended up under mitxonline
    // (happens because the Dio cookie interceptor routes the SSO redirect
    // response under the mitxonline host).
    final ssoStore = store.putIfAbsent('sso.ol.mit.edu', () => {});
    final mitxStore = store['mitxonline.mit.edu'] ?? {};
    for (final key in ['KEYCLOAK_IDENTITY', 'KEYCLOAK_SESSION']) {
      if (mitxStore.containsKey(key) && !ssoStore.containsKey(key)) {
        ssoStore[key] = mitxStore[key]!;
      }
    }

    var nextUrl = '$kLmsBaseUrl/auth/login/ol-oauth2/?auth_entry=login';
    for (var hop = 0; hop < 15; hop++) {
      final uri = Uri.parse(nextUrl);

      // Domain-suffix matching: include cookies stored under parent domains.
      final host = uri.host;
      final merged = <String, String>{};
      for (final e in store.entries) {
        if (host == e.key || host.endsWith('.${e.key}')) {
          merged.addAll(e.value);
        }
      }
      final cookieHeader =
          merged.entries.map((e) => '${e.key}=${e.value}').join('; ');

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

    // Merge hop-store results back into the in-memory cookie map.
    for (final entry in store.entries) {
      _cookies.putIfAbsent(entry.key, () => {}).addAll(entry.value);
    }
    await _store.saveAll(_cookies);
    _log.info('establishLmsSession: complete');
  }

  /// Walks the MIT Learn API SSO handshake with a bare Dio instance to pick up
  /// `session_mitlearn` + `learn_csrftoken` cookies on api.learn.mit.edu.
  ///
  /// The `session` cookie (set on `.learn.mit.edu`) authenticates userlists;
  /// it can be present but silently expired, in which case the API returns
  /// 200 with empty results instead of 401. Cookie presence is not a
  /// trustworthy health signal — callers should use [refreshLearnSession],
  /// which re-runs this handshake and verifies the result with an
  /// authenticated probe.
  Future<void> establishLearnApiSession() async {
    final bare = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );

    final store = <String, Map<String, String>>{};
    for (final entry in _cookies.entries) {
      store[entry.key] = Map<String, String>.from(entry.value);
    }

    // Forward Keycloak identity cookies to sso.ol.mit.edu if they're only
    // stored under one of the app hosts (happens because Dio routes SSO
    // redirect responses under the originating host).
    final ssoStore = store.putIfAbsent('sso.ol.mit.edu', () => {});
    for (final host in ['mitxonline.mit.edu', 'courses.learn.mit.edu']) {
      final hostStore = store[host] ?? {};
      for (final key in ['KEYCLOAK_IDENTITY', 'KEYCLOAK_SESSION']) {
        if (hostStore.containsKey(key) && !ssoStore.containsKey(key)) {
          ssoStore[key] = hostStore[key]!;
        }
      }
    }

    var nextUrl = '$kLearnApiBaseUrl/login';
    for (var hop = 0; hop < 15; hop++) {
      final uri = Uri.parse(nextUrl);

      final host = uri.host;
      final merged = <String, String>{};
      for (final e in store.entries) {
        if (host == e.key || host.endsWith('.${e.key}')) {
          merged.addAll(e.value);
        }
      }
      final cookieHeader =
          merged.entries.map((e) => '${e.key}=${e.value}').join('; ');

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

      for (final raw in resp.headers['set-cookie'] ?? <String>[]) {
        _parseSetCookieInto(uri, raw, store);
      }

      final status = resp.statusCode ?? 0;
      final location = resp.headers.value('location');
      _log.info(
        'establishLearnApiSession[$hop]: $status ${uri.host}${uri.path}'
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

    for (final entry in store.entries) {
      _cookies.putIfAbsent(entry.key, () => {}).addAll(entry.value);
    }
    await _store.saveAll(_cookies);
    _log.info('establishLearnApiSession: complete');
  }

  /// Eagerly re-bootstrap the api.learn.mit.edu session and verify it's
  /// actually accepted by the server. Returns `true` if the fresh `session`
  /// cookie authenticates, `false` if the SSO chain couldn't produce a valid
  /// session (upstream Keycloak identity expired, network failure, etc).
  ///
  /// Why this exists: the userlists endpoint returns 200 with `count: 0`
  /// when `session` is stale — no 4xx to catch. The probe against
  /// `/api/v0/users/me/` is the cheapest call that actually exposes
  /// `is_authenticated`, so we use it as the health check.
  ///
  /// Callers: every logical op that touches api.learn.mit.edu should call
  /// this at its start. A `false` return must be turned into a
  /// [StaleSessionException] so the manager's escalation chain runs
  /// (silent WebView bootstrap → reauth dialog).
  Future<bool> refreshLearnSession() async {
    try {
      await establishLearnApiSession();
    } on Object catch (e, st) {
      _log.warning('refreshLearnSession: bootstrap chain failed', e, st);
      return false;
    }
    try {
      final resp = await _learnApiDio.get<dynamic>('/api/v0/users/me/');
      final body = resp.data;
      if (body is Map<String, dynamic>) {
        return body['is_authenticated'] == true;
      }
      return false;
    } on Object catch (e, st) {
      _log.warning('refreshLearnSession: verify probe failed', e, st);
      return false;
    }
  }

  /// Save [cookies] for [host] to the in-memory store and persist.
  /// Used by the Flutter login screen to inject WebView cookies.
  Future<void> saveCookies(String host, Map<String, String> cookies) async {
    _cookies.putIfAbsent(host, () => {}).addAll(cookies);
    await _store.saveAll(_cookies);
  }

  /// Delete all in-memory and persisted cookies.
  Future<void> clearCookies() async {
    _cookies = {};
    await _store.deleteAll();
  }

  /// Parses a single Set-Cookie header string into [store].
  /// Returns true if any value was added/changed.
  static bool _parseSetCookieInto(
    Uri requestUri,
    String raw,
    Map<String, Map<String, String>> store,
  ) {
    final parts = raw.split(';');
    if (parts.isEmpty) return false;
    final nameValue = parts.first;
    final eq = nameValue.indexOf('=');
    if (eq <= 0) return false;
    final name = nameValue.substring(0, eq).trim();
    final value = nameValue.substring(eq + 1);

    var host = requestUri.host;
    for (final attr in parts.skip(1)) {
      final trimmed = attr.trim();
      if (trimmed.toLowerCase().startsWith('domain=')) {
        host = trimmed.substring(7);
        if (host.startsWith('.')) host = host.substring(1);
        break;
      }
    }

    final existing = store.putIfAbsent(host, () => {});
    if (existing[name] == value) return false;
    existing[name] = value;
    return true;
  }

  /// Attach a 401 interceptor to the LMS Dio instance that re-establishes
  /// the LMS session and retries once.
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
