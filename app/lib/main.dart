import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dioClient = await buildDioClient();
  runApp(
    ProviderScope(
      overrides: [dioClientProvider.overrideWithValue(dioClient)],
      child: const EmajteeApp(),
    ),
  );
}

class EmajteeApp extends ConsumerWidget {
  const EmajteeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'MITxxx',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFA31F34), // MIT red
        ),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}
