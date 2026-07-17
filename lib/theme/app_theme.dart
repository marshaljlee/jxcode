import 'package:flutter/material.dart';

class JXCODETheme {
  // ═══ Brand Colors ═══
  static const Color terracotta = Color(0xFFD97757);
  static const Color terracottaLight = Color(0xFFF0A88A);
  static const Color terracottaDark = Color(0xFFB85A3A);

  // ═══ Surfaces ═══
  static const Color surfaceLight = Color(0xFFF8F7F4);
  static const Color surfaceDark = Color(0xFF1A1A2E);
  static const Color cardLight = Color(0xFFFFFFFF);
  static const Color cardDark = Color(0xFF252540);
  static const Color elevatedDark = Color(0xFF2E2E4A);
  static const Color scaffoldDark = Color(0xFF12122A);

  // ═══ Text ═══
  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textPrimaryDark = Color(0xFFF0F0F0);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textTertiary = Color(0xFF9CA3AF);

  // ═══ Semantic ═══
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color info = Color(0xFF3B82F6);

  // ═══ Code/Block Colors ═══
  static const Color codeBg = Color(0xFF1E1E2E);
  static const Color codeBgLight = Color(0xFFF4F4F5);
  static const Color codeText = Color(0xFFE0E0E0);
  static const Color dividerLight = Color(0xFFE5E7EB);
  static const Color dividerDark = Color(0xFF374151);

  // ═══ Spacing Scale (4px base) ═══
  static const double s2 = 2;
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s40 = 40;
  static const double s48 = 48;
  static const double s64 = 64;

  // ═══ Corner Radius ═══
  static const double rCard = 12;
  static const double rButton = 8;
  static const double rInput = 8;
  static const double rModal = 12;
  static const double rSheet = 16;
  static const double rChip = 999;

  // ═══ Animations ═══
  static const Duration dHover = Duration(milliseconds: 120);
  static const Duration dTransition = Duration(milliseconds: 200);
  static const Duration dPage = Duration(milliseconds: 300);
  static const Duration dMicro = Duration(milliseconds: 100);
  static const Curve easeOut = Curves.easeOut;
  static const Curve easeInOut = Curves.easeInOut;
  static const Curve spring = Curves.easeInOutCubic;

  static ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorSchemeSeed: terracotta,
    scaffoldBackgroundColor: surfaceLight,

    appBarTheme: const AppBarTheme(
      elevation: 0,
      centerTitle: false,
      backgroundColor: Colors.transparent,
      foregroundColor: textPrimary,
      titleTextStyle: TextStyle(
        color: textPrimary,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),

    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: dividerLight),
      ),
      color: cardLight,
    ),

    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rInput),
        borderSide: BorderSide(color: dividerLight),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rInput),
        borderSide: BorderSide(color: dividerLight),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rInput),
        borderSide: const BorderSide(color: terracotta, width: 1.5),
      ),
      filled: true,
      fillColor: Colors.grey.shade50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),

    navigationBarTheme: NavigationBarThemeData(
      elevation: 1,
      indicatorColor: terracotta.withAlpha(38),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const TextStyle(fontSize: 12, fontWeight: FontWeight.w600);
        }
        return const TextStyle(fontSize: 12);
      }),
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: terracotta,
      foregroundColor: Colors.white,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rSheet)),
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      actionTextColor: terracottaLight,
    ),

    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rModal)),
      elevation: 4,
    ),

    bottomSheetTheme: BottomSheetThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
      ),
      elevation: 4,
    ),

    dividerTheme: DividerThemeData(
      color: dividerLight,
      thickness: 1,
      space: 1,
    ),

    chipTheme: ChipThemeData(
      shape: StadiumBorder(),
      side: BorderSide.none,
    ),

    textTheme: const TextTheme(
      headlineLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
      headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
      headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      titleLarge: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      bodyLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
      bodyMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
      bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
      labelLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
    ),
  );

  static ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorSchemeSeed: terracotta,
    scaffoldBackgroundColor: scaffoldDark,

    appBarTheme: const AppBarTheme(
      elevation: 0,
      centerTitle: false,
      backgroundColor: Colors.transparent,
      foregroundColor: textPrimaryDark,
      titleTextStyle: TextStyle(
        color: textPrimaryDark,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),

    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: dividerDark),
      ),
      color: cardDark,
    ),

    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rInput),
        borderSide: BorderSide(color: dividerDark),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rInput),
        borderSide: BorderSide(color: dividerDark),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rInput),
        borderSide: const BorderSide(color: terracotta, width: 1.5),
      ),
      filled: true,
      fillColor: const Color(0xFF1E1E38),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),

    navigationBarTheme: NavigationBarThemeData(
      elevation: 1,
      indicatorColor: terracotta.withAlpha(38),
      backgroundColor: cardDark,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const TextStyle(fontSize: 12, fontWeight: FontWeight.w600);
        }
        return const TextStyle(fontSize: 12);
      }),
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: terracotta,
      foregroundColor: Colors.white,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rSheet)),
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      actionTextColor: terracottaLight,
      backgroundColor: elevatedDark,
    ),

    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rModal)),
      elevation: 4,
      backgroundColor: cardDark,
    ),

    bottomSheetTheme: BottomSheetThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
      ),
      elevation: 4,
      backgroundColor: cardDark,
    ),

    dividerTheme: DividerThemeData(
      color: dividerDark,
      thickness: 1,
      space: 1,
    ),

    chipTheme: ChipThemeData(
      shape: StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: elevatedDark,
    ),

    textTheme: const TextTheme(
      headlineLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: textPrimaryDark),
      headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: textPrimaryDark),
      headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: textPrimaryDark),
      titleLarge: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: textPrimaryDark),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: textPrimaryDark),
      bodyLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: textPrimaryDark),
      bodyMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: textPrimaryDark),
      bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: textTertiary),
      labelLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: textPrimaryDark),
      labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: textPrimaryDark),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w400, color: textTertiary),
    ),
  );
}
