import 'package:flutter/material.dart';

class LayoverColors {
  const LayoverColors._();

  static const ink = Color(0xFF171717);
  static const paper = Color(0xFFF5F8F7);
  static const mint = Color(0xFF7AC49B);
  static const blue = Color(0xFF6EC6E9);
  static const coral = Color(0xFFF78086);
  static const mango = Color(0xFFF6B63D);
  static const lilac = Color(0xFFC8C2F2);
}

ThemeData buildLayoverTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: LayoverColors.mint,
    brightness: Brightness.light,
    primary: LayoverColors.ink,
    surface: LayoverColors.paper,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: LayoverColors.paper,
    fontFamily: 'Roboto',
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFFDCE5E1)),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: Color(0xFFD5EBDD),
    ),
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        fontSize: 32,
        height: 1,
        fontWeight: FontWeight.w900,
        color: LayoverColors.ink,
      ),
      headlineMedium: TextStyle(
        fontSize: 24,
        height: 1.1,
        fontWeight: FontWeight.w900,
        color: LayoverColors.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        height: 1.2,
        fontWeight: FontWeight.w800,
        color: LayoverColors.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        height: 1.2,
        fontWeight: FontWeight.w800,
        color: LayoverColors.ink,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        height: 1.35,
        fontWeight: FontWeight.w500,
        color: LayoverColors.ink,
      ),
      bodyMedium: TextStyle(
        fontSize: 13,
        height: 1.35,
        fontWeight: FontWeight.w500,
        color: LayoverColors.ink,
      ),
      labelLarge: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w900,
        color: LayoverColors.ink,
      ),
      labelMedium: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        color: LayoverColors.ink,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: LayoverColors.ink,
      elevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: LayoverColors.mango,
        foregroundColor: LayoverColors.ink,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: LayoverColors.ink, width: 1.5),
        ),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: LayoverColors.ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
  );
}
