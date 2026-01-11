import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// 텍스트 필드 데코레이션 유틸리티
class TextFieldDecorationUtil {
  TextFieldDecorationUtil._();

  /// 기본 라벨 스타일 (전화번호, 인증번호 등)
  static TextStyle defaultLabelStyle({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return TextStyle(
      fontSize: fontSize ?? 18,
      color: color ?? AppColors.primaryGreen,
      fontWeight: fontWeight ?? FontWeight.w600,
    );
  }

  /// 에러 라벨 스타일
  static TextStyle errorLabelStyle({double? fontSize, FontWeight? fontWeight}) {
    return TextStyle(
      fontSize: fontSize ?? 18,
      color: Colors.red,
      fontWeight: fontWeight ?? FontWeight.w500,
    );
  }

  /// 기본 힌트 스타일
  static TextStyle defaultHintStyle({
    Color? color,
    double? fontSize,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontSize: fontSize ?? 18,
      color: color ?? AppColors.textLight,
      fontWeight: FontWeight.w500,
      letterSpacing: letterSpacing ?? 0,
    );
  }

  /// 기본 에러 스타일
  static TextStyle defaultErrorStyle({double? fontSize, double? height}) {
    return TextStyle(
      fontSize: fontSize ?? 14,
      color: Colors.red,
      height: height ?? 1.4,
    );
  }

  /// 읽기 전용 라벨 스타일
  static TextStyle readOnlyLabelStyle({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? opacity,
  }) {
    return TextStyle(
      fontSize: fontSize ?? 18,
      color: (color ?? AppColors.textSecondary).withOpacity(opacity ?? 0.8),
      fontWeight: fontWeight ?? FontWeight.w600,
    );
  }

  /// 기본 텍스트 필드 데코레이션 (전화번호, 인증번호 등)
  ///
  /// 보더 없이 fillColor만 적용, borderRadius는 유지
  ///
  /// [hasError] 에러 상태 여부
  /// [hasFocus] 포커스 상태 여부 (기본값: false)
  /// [fillColor] 배경색 (기본값: backgroundLight)
  /// [borderRadius] 보더 반경 (기본값: 16)
  /// [contentPadding] 내부 패딩 (기본값: horizontal 16, vertical 18)
  static InputDecoration defaultDecoration({
    String? hintText,
    String? errorText,
    Widget? prefixIcon,
    bool hasError = false,
    bool hasFocus = false,
    Color? fillColor,
    double borderRadius = 16,
    EdgeInsetsGeometry? contentPadding,
    FloatingLabelBehavior? floatingLabelBehavior,
  }) {
    final defaultFillColor = fillColor ?? AppColors.backgroundLight;
    final defaultContentPadding =
        contentPadding ??
        const EdgeInsets.symmetric(horizontal: 16, vertical: 18);

    return InputDecoration(
      hintText: hintText,
      errorText: errorText,
      prefixIcon: prefixIcon,
      labelStyle: hasError ? errorLabelStyle() : defaultLabelStyle(),
      hintStyle: defaultHintStyle(),
      errorStyle: defaultErrorStyle(),
      floatingLabelBehavior:
          floatingLabelBehavior ?? FloatingLabelBehavior.always,
      filled: true,
      fillColor: defaultFillColor,
      contentPadding: defaultContentPadding,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide.none,
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide.none,
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide.none,
      ),
    );
  }

  /// 읽기 전용 텍스트 필드 데코레이션 (전화번호 표시 등)
  static InputDecoration readOnlyDecoration({
    String? labelText,
    Widget? prefixIcon,
    Color? fillColor,
    double borderRadius = 16,
    EdgeInsetsGeometry? contentPadding,
  }) {
    return InputDecoration(
      labelText: labelText,
      prefixIcon: prefixIcon,
      labelStyle: readOnlyLabelStyle(),
      filled: true,
      fillColor: fillColor ?? AppColors.backgroundLight,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide.none,
      ),
      contentPadding:
          contentPadding ??
          const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
    );
  }

  /// 일반 입력 필드 데코레이션 (관리자 화면 등)
  static InputDecoration standardDecoration({
    String? hintText,
    String? errorText,
    bool hasError = false,
    double borderWidth = 1,
    Color? fillColor,
    double borderRadius = 16,
    EdgeInsetsGeometry? contentPadding,
  }) {
    final defaultFillColor = fillColor ?? AppColors.backgroundLight;
    final defaultContentPadding =
        contentPadding ??
        const EdgeInsets.symmetric(horizontal: 16, vertical: 16);

    return InputDecoration(
      hintText: hintText,
      errorText: errorText,
      hintStyle: defaultHintStyle(fontSize: 16),
      errorStyle: defaultErrorStyle(),
      filled: true,
      fillColor: defaultFillColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide(
          color: hasError ? Colors.red : Colors.transparent,
          width: borderWidth,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide(
          color: hasError ? Colors.red : Colors.transparent,
          width: borderWidth,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide(
          color: hasError ? Colors.red : Colors.transparent,
          width: borderWidth,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide(color: Colors.red, width: 1),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide(color: Colors.red, width: 1),
      ),
      contentPadding: defaultContentPadding,
    );
  }
}
