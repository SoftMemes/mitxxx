import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

const String kMitxOnlineBaseUrl = 'https://mitxonline.mit.edu';
const String kLmsBaseUrl = 'https://courses.learn.mit.edu';

class DioClient {
  DioClient({CookieJar? cookieJar}) : _cookieJar = cookieJar ?? CookieJar() {
    _mitxOnlineDio = _buildDio(kMitxOnlineBaseUrl);
    _lmsDio = _buildDio(kLmsBaseUrl);
  }

  final CookieJar _cookieJar;
  late final Dio _mitxOnlineDio;
  late final Dio _lmsDio;

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
    return dio;
  }

  /// Attach a 401 interceptor to the LMS Dio instance.
  /// On 401: attempts silent LMS re-auth, retries original request.
  /// If re-auth fails, calls [onAuthFailed].
  void addAuthInterceptor({required void Function() onAuthFailed}) {
    _lmsDio.interceptors.add(
      InterceptorsWrapper(
        onError: (err, handler) async {
          if (err.response?.statusCode != 401) {
            return handler.next(err);
          }

          // Attempt silent LMS re-auth.
          try {
            await _lmsDio.get(
              '/auth/login/ol-oauth2/',
              queryParameters: {'auth_entry': 'login'},
              options: Options(followRedirects: true, maxRedirects: 10),
            );
            // Re-auth succeeded — retry original request.
            final retryResponse = await _lmsDio.fetch(err.requestOptions);
            return handler.resolve(retryResponse);
          } catch (_) {
            // Re-auth failed — notify caller to sign out.
            onAuthFailed();
            return handler.next(err);
          }
        },
      ),
    );
  }
}
