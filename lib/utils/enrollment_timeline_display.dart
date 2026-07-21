import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../models/enrollment_action.dart';
import '../models/enrollment_timeline_item.dart';

/// 수강 상세 타임라인 — 예약/취소·조치 카드 공통 포맷
class EnrollmentTimelineDisplay {
  EnrollmentTimelineDisplay._();

  static String filterCategory(EnrollmentTimelineItem item) {
    if (item is! ActionTimelineItem) return '기타';
    return switch (item.action.actionType) {
      EnrollmentActionType.adjustCount => '횟수조정',
      EnrollmentActionType.periodAdjust => '기간조정',
      EnrollmentActionType.reenroll => '재등록',
      EnrollmentActionType.reservationCreate => '예약',
      EnrollmentActionType.reservationCancel => '예약 취소',
      EnrollmentActionType.reservationMove => '예약 이동',
      EnrollmentActionType.cancel || EnrollmentActionType.other => '기타',
    };
  }

  static Widget buildTimelineEntry({required EnrollmentTimelineItem item}) {
    if (item is ActionTimelineItem) {
      return _actionCard(item.action);
    }
    return const SizedBox.shrink();
  }

  static Widget _actionCard(EnrollmentAction action) {
    final title = switch (action.actionType) {
      EnrollmentActionType.adjustCount => '횟수 조정',
      EnrollmentActionType.periodAdjust => '유효기간 조정',
      EnrollmentActionType.reenroll => '재등록',
      EnrollmentActionType.cancel => '수강 취소',
      EnrollmentActionType.reservationMove => '예약 이동',
      EnrollmentActionType.reservationCreate => action.reservationCreateDisplayLabel,
      EnrollmentActionType.reservationCancel => action.reservationCancelDisplayLabel,
      EnrollmentActionType.other => '기타',
    };

    final lines = switch (action.actionType) {
      EnrollmentActionType.reservationCreate => [
        action.reservationPerformedDateTimeLine,
        action.reservationCreateContentLine,
      ],
      EnrollmentActionType.reservationCancel => [
        action.reservationPerformedDateTimeLine,
        action.reservationCancelContentLine,
      ],
      _ => [
        action.performedDateTimeLine,
        if (action.detailsDisplayLine.isNotEmpty) action.detailsDisplayLine,
      ],
    };

    return _timelineCard(title: title, lines: lines);
  }

  static Widget _timelineCard({
    required String title,
    required List<String> lines,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          ...lines.map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                line,
                style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
