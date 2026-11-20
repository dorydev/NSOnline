import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

abstract final class AppColors {
  static const background = Color(0xFF1B1C1F);
  static const card = Color(0xFF26282C);
  static const raised = Color(0xFF32353A);
  static const divider = Color(0xFF1E1F23);
  static const avatar = Color(0xFF3A3D43);
  static const thumbnail = Color(0xFF45484F);

  static const text = Color(0xFFF2F2F2);
  static const textMuted = Color(0xFF9A9DA3);
  static const textFaint = Color(0xFF6B6E75);

  static const accent = Color(0xFF00C3E3);

  static const alert = Color(0xFFFF4554);
  static const online = Color(0xFF3DDC84);

  static const warning = Color(0xFFFFB547);
}

abstract final class AppRadii {
  static const card = 22.0;
  static const tile = 20.0;
  static const thumb = 12.0;
}

abstract final class AppMotion {
  static const screen = Duration(milliseconds: 230);
  static const fast = Duration(milliseconds: 160);
  static const crossfade = Duration(milliseconds: 280);
  static const pulse = Duration(milliseconds: 1100);
  static const hoverScale = 1.03;
  static const ringWidth = 3.0;

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration of(BuildContext context, Duration d) =>
      reduced(context) ? Duration.zero : d;
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: const ColorScheme.dark(
      surface: AppColors.card,
      primary: AppColors.accent,
      secondary: AppColors.online,
      error: AppColors.alert,
      onSurface: AppColors.text,
    ),
    dividerColor: AppColors.divider,
    focusColor: AppColors.accent.withValues(alpha: 0.18),
    hoverColor: AppColors.text.withValues(alpha: 0.05),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
      ),
      textStyle: const TextStyle(color: AppColors.text, fontSize: 13),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.raised,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
      linearTrackColor: AppColors.raised,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
    ),
  );
  return base.copyWith(
    textTheme: GoogleFonts.nunitoTextTheme(
      base.textTheme,
    ).apply(bodyColor: AppColors.text, displayColor: AppColors.text),
  );
}

extension AppText on BuildContext {
  TextStyle get _base => Theme.of(this).textTheme.bodyMedium!;

  TextStyle get pageTitle =>
      _base.copyWith(fontSize: 30, fontWeight: FontWeight.w800);
  TextStyle get sectionTitle =>
      _base.copyWith(fontSize: 19, fontWeight: FontWeight.w800);
  TextStyle get cardTitle =>
      _base.copyWith(fontSize: 21, fontWeight: FontWeight.w800);
  TextStyle get label =>
      _base.copyWith(fontSize: 16, fontWeight: FontWeight.w700);
  TextStyle get body =>
      _base.copyWith(fontSize: 15, color: AppColors.textMuted);
  TextStyle get caption =>
      _base.copyWith(fontSize: 13.5, color: AppColors.textMuted);
}
