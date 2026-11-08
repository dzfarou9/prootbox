import 'package:flutter/material.dart';

class AppColors {
  static const Color background = Color(0xFF080B10);
  static const Color surface = Color(0xFF101821);
  static const Color surfaceAlt = Color(0xFF18242F);
  static const Color border = Color(0xFF22303C);
  static const Color accent = Color(0xFF38E8A0);
  static const Color accentDeep = Color(0xFF13543C);
  static const Color text = Color(0xFFE6EDF3);
  static const Color muted = Color(0xFF8FA3B0);
  static const Color danger = Color(0xFFFF6B6B);
  static const Color warning = Color(0xFFFFC65C);
}

ThemeData buildAppTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    surface: AppColors.surface,
    primary: AppColors.accent,
    onPrimary: const Color(0xFF04150E),
    error: AppColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.text,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
      iconTheme: IconThemeData(color: AppColors.text, size: 22),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: const Color(0xFF04150E),
        minimumSize: const Size(140, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle:
            const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.3),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        minimumSize: const Size(140, 46),
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceAlt,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1),
  );
}
