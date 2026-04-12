import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:logging/logging.dart';

const String kMitxOnlineBaseUrl = 'https://mitxonline.mit.edu';
const String kLmsBaseUrl = 'https://courses.learn.mit.edu';

final _log = Logger('http');

class DioClient {
  DioClient({CookieJar? cookieJar}) : _cookieJar = cookieJar ?? CookieJar() {
    _mitxOnlineDio = _buildDio(kMitxOnlineBaseUrl);
    _lmsDio = _buildDio(kLmsBaseUrl);
  }

  final CookieJar _cookieJar;
  late final Dio _mitxOnlineDio;
  late final Dio _lmsDio;
  bool _authInterceptorAttached = false;

  Dio get mitxOnline => _mitxOnlineDio;
  Dio get lms => _lmsDio;
  CookieJar get cookieJar => _cookieJar;

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

  /// Logs outgoing request cookies and response status. Dev-only diagnostic.
  InterceptorsWrapper _diagnosticsInterceptor() {
    return InterceptorsWrapper(
      onRequest: (options, handler) async {
        // Log cookies currently loaded into the jar for this request.
        final jarCookies = await _cookieJar.loadForRequest(options.uri);
        final cookieNames = jarCookies.map((c) => c.name).join(', ');
        _log.fine(
          '→ ${options.method} ${options.uri}  '
          'cookies=[${cookieNames.isEmpty ? '(none)' : cookieNames}]',
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

  /// Walks the LMS OAuth redirect chain manually so that Dio attaches the
  /// correct session cookies at each cross-domain hop.
  ///
  /// When the LMS responds with Set-Cookie headers containing values that
  /// dart:io's strict parser rejects (common with JWT cookies),
  /// [CookieManager] throws. We catch that, extract the response, save any
  /// parseable cookies ourselves, and keep following the chain.
  Future<void> establishLmsSession() async {
    var nextUrl = '$kLmsBaseUrl/auth/login/ol-oauth2/?auth_entry=login';
    for (var hop = 0; hop < 15; hop++) {
      final uri = Uri.parse(nextUrl);
      final dio =
          uri.host == 'mitxonline.mit.edu' ? _mitxOnlineDio : _lmsDio;

      // ignore: omit_local_variable_types
      Response<dynamic>? resp;
      try {
        resp = await dio.getUri<dynamic>(
          uri,
          options: Options(
            followRedirects: false,
            validateStatus: (s) => s != null && s < 400,
          ),
        );
      } on DioException catch (e) {
        // CookieManager throws when Set-Cookie values contain characters
        // that dart:io considers invalid (e.g. LMS JWT cookies).
        resp = e.response;
        if (resp == null) rethrow;
        await _saveCookiesLeniently(uri, resp);
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
  }

  /// Saves cookies from a response one-by-one, skipping any that dart:io
  /// refuses to parse.
  Future<void> _saveCookiesLeniently(Uri uri, Response<dynamic> resp) async {
    final headers = resp.headers['set-cookie'] ?? <String>[];
    for (final raw in headers) {
      try {
        final cookie = Cookie.fromSetCookieValue(raw);
        await _cookieJar.saveFromResponse(uri, [cookie]);
      } on Object {
        // Skip unparseable cookie — usually a JWT value with special chars.
      }
    }
  }

  /// Attach a 401 interceptor to the LMS Dio instance.
  /// On 401: attempts silent LMS re-auth, retries original request.
  /// If re-auth fails, calls [onAuthFailed].
  void addAuthInterceptor({required void Function() onAuthFailed}) {
    if (_authInterceptorAttached) return;
    _authInterceptorAttached = true;
    _lmsDio.interceptors.add(
      InterceptorsWrapper(
        onError: (err, handler) async {
          if (err.response?.statusCode != 401) {
            return handler.next(err);
          }

          // Attempt silent LMS re-auth — manually walk the cross-domain
          // redirect chain so the mitxonline session cookie reaches the
          // OAuth authorize endpoint (Dio's CookieManager only fires for
          // the initial request domain, not for cross-domain redirects).
          try {
            await establishLmsSession();
            // Re-auth succeeded — retry original request.
            final retryResponse = await _lmsDio.fetch<dynamic>(err.requestOptions);
            return handler.resolve(retryResponse);
          } on Object {
            // Re-auth failed — notify caller to sign out.
            onAuthFailed();
            return handler.next(err);
          }
        },
      ),
    );
  }
}
