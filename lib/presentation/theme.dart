// Application theme constants and helpers.
import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // ── Monochrome UI palette ──
  static const Color appBg = Color(0xFFFFFFFF);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceElevated = Color(0xFFF5F7FA);
  static const Color border = Color(0xFFD8DDE5);
  static const Color textPrimary = Color(0xFF111827);
  static const Color textMuted = Color(0xFF6B7280);

  // ── Notification accents ──
  static const Color newMessage = Color(0xFF2FB7FF);
  static const Color notification = Color(0xFFFF5A5F);

  // ── Organization colors ──
  static const Color magicPrimary = Color(0xFF2A6FBB); // dashboard-aligned blue
  static const Color maidanPrimary = Color(0xFFD97706); // dashboard-aligned amber-orange
  static const Color freeSlot = Color(0xFF90A4AE);

  // ── Calendar background tints ──
  static Color magicBackground = const Color(0xFF2A6FBB).withAlpha(70);
  static Color maidanBackground = const Color(0xFFD97706).withAlpha(70);
  static Color freeBackground = const Color(0xFF90A4AE).withAlpha(64);

  // ── Request colors ──
  static const Color requestCreated = Color(0xA6EF5350); // light red ~65% α
  static const Color requestReceived = Color(0xA6B71C1C); // dark red ~65% α

  // ── Appointment event colors ──
  static const Color magicEvent = Color(0xFF1E4F86);
  static const Color maidanEvent = Color(0xFF9A4D03);
  static const Color requestCreatedEvent = Color(0xFFD84A4A);
  static const Color requestReceivedEvent = Color(0xFF8E2E2E);

  // ── Helpers ──
  static Color eventColorForOrg(String orgId, String? magicId) {
    return orgId == magicId ? magicEvent : maidanEvent;
  }

  // Keep org identity color but shift lightness by event type for better scanning.
  static Color eventColorForOrgAndType({
    required String orgId,
    required String? magicId,
    required String eventType,
  }) {
    final base = eventColorForOrg(orgId, magicId);
    final normalized = eventType
        .toLowerCase()
        .replaceAll('ă', 'a')
        .replaceAll('â', 'a')
        .replaceAll('î', 'i')
        .replaceAll('ș', 's')
        .replaceAll('ş', 's')
        .replaceAll('ț', 't')
        .replaceAll('ţ', 't')
        .trim();

    double delta;
    if (normalized.contains('spectacol') || normalized.contains('concert')) {
      delta = -0.10;
    } else if (normalized.contains('atelier') || normalized.contains('repetitie')) {
      delta = 0.08;
    } else if (normalized.contains('conferinta') || normalized.contains('expozitie')) {
      delta = 0.02;
    } else if (normalized.contains('petrecere') || normalized.contains('casting')) {
      delta = 0.12;
    } else if (normalized.contains('proiect cultural')) {
      delta = -0.04;
    } else {
      delta = 0.0;
    }

    final hsl = HSLColor.fromColor(base);
    final adjusted = hsl.withLightness((hsl.lightness + delta).clamp(0.20, 0.78));
    return adjusted.toColor();
  }

  static Color requestColor({required bool isCreatedByMe}) {
    return isCreatedByMe ? requestCreatedEvent : requestReceivedEvent;
  }

  static Color backgroundForOrg(String? orgId, String? magicId, String? maidanId) {
    if (orgId == magicId) return magicBackground;
    if (orgId == maidanId) return maidanBackground;
    return freeBackground;
  }

  // ── Busy member colors ──
  static Color memberColor(double ratio) {
    if (ratio >= 1.0) return notification;
    if (ratio <= 0.0) return textMuted;
    return Color.lerp(textMuted, notification, ratio)!;
  }

  // ── ThemeData factory ──
  static ThemeData lightTheme() {
    const scheme = ColorScheme.light(
      primary: magicPrimary,
      secondary: maidanPrimary,
      surface: Colors.white,
      onSurface: Colors.black,
    );

    return ThemeData(
      brightness: Brightness.light,
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: appBg,
      cardColor: surface,
      dividerColor: border,
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surfaceElevated,
        contentTextStyle: TextStyle(color: textPrimary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceElevated,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: magicPrimary, width: 1.4),
        ),
        labelStyle: const TextStyle(color: textMuted),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: textPrimary),
        bodySmall: TextStyle(color: textMuted),
        titleMedium: TextStyle(color: textPrimary),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: textPrimary,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: textPrimary,
        ),
      ),
    );
  }
}
