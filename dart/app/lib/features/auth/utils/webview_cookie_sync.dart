import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/core/network/dio_client.dart';

final _log = Logger('auth.cookie_sync');

/// Pulls cookies for [hosts] from the InAppWebView's persistent cookie jar
/// into the Dio-backed cookie store. Use before an OAuth redirect chain so
/// the server-side SSO sees a valid Keycloak identity and completes silently
/// instead of bouncing to the login page.
///
/// Safe to call repeatedly; cookies are merged into the existing store.
Future<void> syncWebViewCookiesToDio(
  DioClient client,
  List<String> hosts,
) async {
  final cookieManager = CookieManager.instance();
  for (final host in hosts) {
    final url = WebUri('https://$host');
    final cookies = await cookieManager.getCookies(url: url);
    if (cookies.isEmpty) continue;
    final raw = <String, String>{
      for (final c in cookies) c.name: c.value as String,
    };
    await client.saveCookies(host, raw);
    _log.fine('synced ${raw.length} cookies for $host from webview');
  }
}
