import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';

void main() {
  runApp(const ProviderScope(child: EmajteeApp()));
}

class EmajteeApp extends StatelessWidget {
  const EmajteeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'MITxxx',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFA31F34), // MIT red
        ),
        useMaterial3: true,
      ),
      routerConfig: appRouter,
    );
  }
}
