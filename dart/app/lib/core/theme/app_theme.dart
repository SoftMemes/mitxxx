import 'package:flutter/material.dart';

class AppTheme {
  static const Color brandSeed = Color(0xFFA31F34); // MIT red

  static ThemeData get light => ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: brandSeed),
        useMaterial3: true,
      );

  static ThemeData get dark => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: brandSeed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      );
}
