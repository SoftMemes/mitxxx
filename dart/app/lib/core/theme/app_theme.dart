import 'package:flutter/material.dart';

class AppTheme {
  static const Color brandSeed = Color(0xFFA31F34); // MIT red

  // Shared AppBar style: MIT red background, white icons/text, no elevation tint.
  static const AppBarTheme _appBarTheme = AppBarTheme(
    backgroundColor: brandSeed,
    foregroundColor: Colors.white,
    elevation: 0,
    scrolledUnderElevation: 0,
    iconTheme: IconThemeData(color: Colors.white),
    actionsIconTheme: IconThemeData(color: Colors.white),
  );

  static ThemeData get light => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: brandSeed,
          // Pin primary to the exact brand colour — fromSeed generates a
          // tone-40 tonal primary (pink-ish) by default.
          primary: brandSeed,
          onPrimary: Colors.white,
        ),
        appBarTheme: _appBarTheme,
        useMaterial3: true,
      );

  static ThemeData get dark => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: brandSeed,
          brightness: Brightness.dark,
          primary: brandSeed,
          onPrimary: Colors.white,
        ),
        appBarTheme: _appBarTheme,
        useMaterial3: true,
      );
}
