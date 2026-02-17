import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// 캘린더 세션 블록의 표시 타입 (용도별 일관된 디자인 적용)
enum SessionBlockType {
  /// 예약 가능
  available,
  /// 내 예약됨
  reserved,
  /// 잠김 (만석/정책/미오픈 등)
  locked,
  /// 예약/취소/변경 처리 중
  processing,
  /// 정기 일정 (편집 UI용)
  regularSchedule,
  /// 비정기 일정 (편집 UI용)
  overrideSchedule,
  /// 드래그 미리보기
  preview,
  /// 코스 상세용 단순 블록
  courseDetail,
}

/// 세션 블록 타입별 스타일 (색상·모서리·그림자)
///
/// calendar_screen, compact_calendar_widget, drag_calendar_editor 등
/// 모든 캘린더에서 동일한 타입이 동일하게 보이도록 정의.
class SessionBlockStyle {
  const SessionBlockStyle({
    required this.backgroundColor,
    required this.textColor,
    required this.iconColor,
    this.borderRadius = 12,
    this.showShadow = true,
  });

  final Color backgroundColor;
  final Color textColor;
  final Color iconColor;
  final double borderRadius;
  final bool showShadow;

  /// 타입 + 코스색(또는 회색)으로 스타일 생성
  static SessionBlockStyle fromType(
    SessionBlockType type, {
    Color? courseColor,
  }) {
    final base = courseColor ?? AppColors.primaryGreen;

    switch (type) {
      case SessionBlockType.available:
        return SessionBlockStyle(
          backgroundColor: AppColors.reservedGrey,
          textColor: AppColors.textPrimary,
          iconColor: AppColors.textPrimary,
          borderRadius: 12,
          showShadow: false,
        );
      case SessionBlockType.reserved:
        return SessionBlockStyle(
          backgroundColor: base,
          textColor: _textColorForBackground(base),
          iconColor: _textColorForBackground(base),
          borderRadius: 12,
          showShadow: true,
        );
      case SessionBlockType.locked:
        // 색상은 available과 동일, 자물쇠 아이콘으로만 구분
        return SessionBlockStyle(
          backgroundColor: AppColors.reservedGrey,
          textColor: AppColors.textPrimary,
          iconColor: AppColors.textPrimary,
          borderRadius: 12,
          showShadow: false,
        );
      case SessionBlockType.processing:
        return SessionBlockStyle(
          backgroundColor: base.withOpacity(0.65),
          textColor: Colors.white,
          iconColor: Colors.white,
          borderRadius: 12,
          showShadow: true,
        );
      case SessionBlockType.regularSchedule:
        return SessionBlockStyle(
          backgroundColor: Colors.grey[400]!,
          textColor: _textColorForBackground(Colors.grey[400]!),
          iconColor: _textColorForBackground(Colors.grey[400]!),
          borderRadius: 8,
          showShadow: true,
        );
      case SessionBlockType.overrideSchedule:
        return SessionBlockStyle(
          backgroundColor: base,
          textColor: _textColorForBackground(base),
          iconColor: _textColorForBackground(base),
          borderRadius: 8,
          showShadow: true,
        );
      case SessionBlockType.preview:
        return SessionBlockStyle(
          backgroundColor: base.withOpacity(0.3),
          textColor: _textColorForBackground(base.withOpacity(0.3)),
          iconColor: _textColorForBackground(base.withOpacity(0.3)),
          borderRadius: 8,
          showShadow: false,
        );
      case SessionBlockType.courseDetail:
        return SessionBlockStyle(
          backgroundColor: base,
          textColor: Colors.white,
          iconColor: Colors.white,
          borderRadius: 12,
          showShadow: true,
        );
    }
  }

  static Color _textColorForBackground(Color background) {
    return textColorForBackground(background);
  }

  /// 배경색에 맞는 텍스트/아이콘 색상
  static Color textColorForBackground(Color background) {
    final luminance = background.computeLuminance();
    return luminance > 0.5 ? AppColors.textPrimary : Colors.white;
  }

  /// BoxDecoration (세션 블록 Container용)
  BoxDecoration toBoxDecoration() {
    return BoxDecoration(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(borderRadius),
      boxShadow: showShadow
          ? [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ]
          : null,
    );
  }
}
