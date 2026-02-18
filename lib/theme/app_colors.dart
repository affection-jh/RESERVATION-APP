import 'package:flutter/material.dart';

class AppColors {
  // Primary Colors
  static const Color primaryGreen = Color.fromARGB(255, 59, 59, 59);
  static const Color secondaryBrown = Color(0xFF27251F);

  // Brand Color Series (브랜드 컬러 팔레트)
  // STARBUCKS GREEN - 깊은 에메랄드 그린 (기본 브랜드 컬러)
  static const Color brandStarbucksGreen = Color.fromARGB(
    255,
    0,
    102,
    68,
  ); // #006644

  // ACCENT GREEN - 세련된 중간 톤 그린
  static const Color brandAccentGreen = Color.fromARGB(
    255,
    0,
    130,
    85,
  ); // #008255

  // LIGHT GREEN - 차분한 연한 그린 (유치하지 않은 톤)
  static const Color brandLightGreen = Color.fromARGB(
    255,
    140,
    180,
    160,
  ); // #8CB4A0

  // HOUSE GREEN - 어두운 숲 그린
  static const Color brandHouseGreen = Color.fromARGB(
    255,
    0,
    55,
    35,
  ); // #003723

  // BLACK - 검은색
  static const Color brandBlack = Color.fromARGB(255, 0, 0, 0); // #000000

  // WARM NEUTRAL - 따뜻한 크림 오프화이트
  static const Color brandWarmNeutral = Color.fromARGB(
    255,
    250,
    245,
    240,
  ); // #FAF5F0

  // COOL NEUTRAL - 차가운 회색빛 화이트
  static const Color brandCoolNeutral = Color.fromARGB(
    255,
    245,
    245,
    250,
  ); // #F5F5FA

  // WHITE - 순수한 흰색
  static const Color brandWhite = Color.fromARGB(255, 255, 255, 255); // #FFFFFF

  // Brand Color Series List (코스 색상 선택용 - 제한된 브랜드 컬러만 사용)
  static const List<Color> brandColorSeries = [
    brandStarbucksGreen,
    brandAccentGreen,
    brandLightGreen,
    brandHouseGreen,
    brandBlack,
    brandWarmNeutral,
    brandCoolNeutral,
    brandWhite,
  ];

  // Brand Color Series as Int List (ARGB hex 값)
  static const List<int> brandColorSeriesInt = [
    0xFF006644, // brandStarbucksGreen
    0xFF008255, // brandAccentGreen
    0xFF8CB4A0, // brandLightGreen
    0xFF003723, // brandHouseGreen
    0xFF000000, // brandBlack
    0xFFFAF5F0, // brandWarmNeutral
    0xFFF5F5FA, // brandCoolNeutral
    0xFFFFFFFF, // brandWhite
  ];

  // Primary Green Series List (색상 선택용 - 브랜드 컬러 시리즈 사용)
  static const List<Color> primaryGreenSeries = brandColorSeries;

  // Background Colors
  static const Color backgroundLight = Color(0xFFF5F5F5); // 약간 회색빛
  static const Color backgroundWhite = Color(0xFFFFFFFF);

  // Text Colors
  static const Color textPrimary = Color(0xFF27251F);
  static const Color textSecondary = Color(0xFF666666);
  static const Color textLight = Color(0xFF999999);

  // Reserved Colors (예약 가능/완료 등)
  static const Color reservedGrey = Color.fromARGB(255, 226, 226, 226);
  /// 자물쇠(잠김) 세션 전용 — 예약가능 박스보다 더 연한 회색
  static const Color sessionLockedGrey = Color.fromARGB(255, 240, 240, 240);
  static const Color reservedTextGrey = Color.fromARGB(255, 44, 44, 44);
  static const Color reservedIconGrey = Color.fromARGB(255, 60, 60, 60);

  // Border & Divider
  static const Color borderLight = Color(0xFFE0E0E0);

  // Private constructor to prevent instantiation
  AppColors._();
}
