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
}
