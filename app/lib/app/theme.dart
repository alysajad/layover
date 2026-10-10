import 'package:flutter/material.dart';

class LayoverColors {
  const LayoverColors._();
  static const ink = Color(0xFF20211F);
  static const paper = Color(0xFFF6F5F1);
  static const muted = Color(0xFF696A65);
  static const line = Color(0xFFD5D5CF);
  static const wash = Color(0xFFECEDE7);
  static const mint = Color(0xFFB8C9AE);
  static const blue = wash;
  static const coral = wash;
  static const mango = wash;
  static const lilac = wash;
}

ThemeData buildLayoverTheme() {
  const ink = LayoverColors.ink;
  const paper = LayoverColors.paper;
  final outline = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(22),
    side: const BorderSide(color: ink),
  );
  const scheme = ColorScheme.light(
    primary: ink,
    onPrimary: Colors.white,
    secondary: ink,
    onSecondary: Colors.white,
    primaryContainer: LayoverColors.wash,
    onPrimaryContainer: ink,
    secondaryContainer: ink,
    onSecondaryContainer: Colors.white,
    tertiary: LayoverColors.muted,
    surface: paper,
    onSurface: ink,
    onSurfaceVariant: LayoverColors.muted,
    surfaceContainerHighest: LayoverColors.wash,
    outline: LayoverColors.muted,
    outlineVariant: LayoverColors.line,
    error: Color(0xFFA1392E),
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Lato',
  );
  return base.copyWith(
    scaffoldBackgroundColor: paper,
    textTheme: base.textTheme.copyWith(
      displaySmall: const TextStyle(
        fontFamily: 'Lato',
        fontSize: 48,
        height: 1.04,
        letterSpacing: -2.2,
        fontWeight: FontWeight.w900,
        color: ink,
      ),
      headlineMedium: const TextStyle(
        fontFamily: 'Lato',
        fontSize: 34,
        height: 1.08,
        letterSpacing: -1.2,
        fontWeight: FontWeight.w400,
        color: ink,
      ),
      titleLarge: const TextStyle(
        fontFamily: 'Lato',
        fontSize: 22,
        height: 1.2,
        letterSpacing: -.5,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      titleMedium: const TextStyle(
        fontFamily: 'Lato',
        fontSize: 16,
        height: 1.3,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      bodyLarge: const TextStyle(
        fontFamily: 'Lato',
        fontSize: 16,
        height: 1.45,
        color: ink,
      ),
      bodyMedium: const TextStyle(
        fontFamily: 'Lato',
        fontSize: 14,
        height: 1.45,
        color: ink,
      ),
      labelLarge: const TextStyle(
        fontFamily: 'Lato',
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: outline,
      clipBehavior: Clip.antiAlias,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 72,
      titleTextStyle: TextStyle(
        fontFamily: 'Lato',
        fontSize: 23,
        fontWeight: FontWeight.w900,
        letterSpacing: -.8,
        color: ink,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: LayoverColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: ink, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ink,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 52),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontFamily: 'Lato',
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(48, 50),
        side: const BorderSide(color: ink),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(48, 48),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(48, 48),
        shape: const CircleBorder(),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 76,
      indicatorColor: ink,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 23,
          color: states.contains(WidgetState.selected) ? Colors.white : ink,
        ),
      ),
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(
          fontFamily: 'Lato',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: ink,
        ),
      ),
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: paper,
      indicatorColor: ink,
      selectedIconTheme: IconThemeData(color: Colors.white),
      unselectedIconTheme: IconThemeData(color: ink),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: paper,
      selectedColor: ink,
      checkmarkColor: Colors.white,
      labelStyle: TextStyle(
        color: WidgetStateColor.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? Colors.white : ink,
        ),
        fontFamily: 'Lato',
        fontSize: 13,
      ),
      shape: const StadiumBorder(),
      side: const BorderSide(color: LayoverColors.line),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: LayoverColors.line,
      thickness: 1,
      space: 28,
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      iconColor: ink,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ink,
      linearTrackColor: LayoverColors.line,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: ink,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    badgeTheme: const BadgeThemeData(
      backgroundColor: ink,
      textColor: Colors.white,
    ),
  );
}
