import 'package:flutter/foundation.dart';
import 'enrollment_action.dart';
import 'session_reservation.dart';

/// 예약 + 관리자 조치를 통합한 타임라인 아이템
/// dateTime 기준으로 정렬 (최신순)
@immutable
sealed class EnrollmentTimelineItem {
  final DateTime dateTime;

  const EnrollmentTimelineItem(this.dateTime);
}

/// 예약 이벤트 (reservedAt 또는 reservedDate+startTime 기준)
final class ReservationTimelineItem extends EnrollmentTimelineItem {
  final SessionReservation reservation;

  const ReservationTimelineItem({
    required DateTime dateTime,
    required this.reservation,
  }) : super(dateTime);
}

/// 관리자 조치 이벤트
final class ActionTimelineItem extends EnrollmentTimelineItem {
  final EnrollmentAction action;

  const ActionTimelineItem({
    required DateTime dateTime,
    required this.action,
  }) : super(dateTime);
}
