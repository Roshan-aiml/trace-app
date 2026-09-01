import 'package:flutter/material.dart';

/// TRACE visual language. One seed colour, Material 3, plus the verdict palette
/// shared by every badge / banner / chart bar.
class TraceTheme {
  static const seed = Color(0xFF1F6FEB);

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          b == Brightness.light ? const Color(0xFFF6F7F9) : null,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        scrolledUnderElevation: 2,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}

class Verdict {
  static const pass = 'PASS';
  static const review = 'REVIEW';
  static const hold = 'HOLD';
  static const rejected = 'REJECTED';

  static Color color(String? v) {
    switch ((v ?? '').toUpperCase()) {
      case pass:
        return const Color(0xFF1E874B);
      case review:
        return const Color(0xFFB26A00);
      case hold:
        return const Color(0xFFB3261E);
      case rejected:
        return const Color(0xFF6B6B6B);
      case 'PROCESSING':
        return const Color(0xFF1F6FEB);
      case 'FAILED':
        return const Color(0xFFB3261E);
      default:
        return const Color(0xFF6B6B6B);
    }
  }

  static IconData icon(String? v) {
    switch ((v ?? '').toUpperCase()) {
      case pass:
        return Icons.check_circle;
      case review:
        return Icons.error;
      case hold:
        return Icons.pan_tool;
      case rejected:
        return Icons.block;
      case 'PROCESSING':
        return Icons.hourglass_top;
      case 'FAILED':
        return Icons.report_gmailerrorred;
      default:
        return Icons.help;
    }
  }
}
