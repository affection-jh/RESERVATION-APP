import 'package:cloud_firestore/cloud_firestore.dart';

/// 관리자가 해당 수강(enrollment)에 대해 수행한 모든 중요 조치의 히스토리.
/// 법적·감사 목적, 과하지 않은 범위로 기록한다.
///
/// 기록 대상: 횟수조정, 유효기간 조정, 재등록, 수강 취소, 관리자 권한 예약 이동/취소.
/// enrollments/{enrollmentId}/actionHistory 서브컬렉션에서 온디멘드 조회.
/// performedAt: Firestore에는 Timestamp(서버 시간)로 저장.
///
/// 각 액션 타입별 상세 저장 권장:
/// - [EnrollmentActionType.adjustCount]: oldValue/newValue에 totalReservations, remainingReservations. details에 요약 문구.
/// - [EnrollmentActionType.periodAdjust]: oldValue/newValue에 validFrom, validUntil(ISO8601). details에 "연장" 또는 "단축" 요약.
/// - [EnrollmentActionType.reenroll]: newValue에 새 validFrom, validUntil, totalReservations 등. details에 사유/요약.
/// - [EnrollmentActionType.cancel]: oldValue에 취소 시점 상태. details에 사유(선택).
/// - [EnrollmentActionType.reservationMove]: oldValue에 sessionId, fromDate 등, newValue에 toSessionId, toDate 등. details에 "A일 → B일" 요약.
/// - [EnrollmentActionType.reservationCancel]: oldValue에 sessionId, sessionDate 등. details에 세션 식별 요약.
class EnrollmentAction {
  final String id;
  final EnrollmentActionType actionType;
  final DateTime performedAt;
  final String performedBy; // adminId
  final String? details;
  final Map<String, dynamic>? oldValue;
  final Map<String, dynamic>? newValue;

  EnrollmentAction({
    required this.id,
    required this.actionType,
    required this.performedAt,
    required this.performedBy,
    this.details,
    this.oldValue,
    this.newValue,
  });

  /// Firestore 저장 시 performedAt은 서비스에서 FieldValue.serverTimestamp()로 덮어씀.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'actionType': actionType.name,
      'performedAt': performedAt.toIso8601String(),
      'performedBy': performedBy,
      'details': details,
      'oldValue': oldValue,
      'newValue': newValue,
    };
  }

  factory EnrollmentAction.fromJson(Map<String, dynamic> json) {
    return EnrollmentAction(
      id: json['id'] as String,
      actionType: _parseActionType(json['actionType'] as String?),
      performedAt: _parsePerformedAt(json['performedAt']),
      performedBy: json['performedBy'] as String,
      details: json['details'] as String?,
      oldValue: json['oldValue'] as Map<String, dynamic>?,
      newValue: json['newValue'] as Map<String, dynamic>?,
    );
  }

  static DateTime _parsePerformedAt(dynamic value) {
    if (value == null) return DateTime.now();
    if (value is String) return DateTime.parse(value);
    if (value is Timestamp) return value.toDate();
    return DateTime.now();
  }

  /// 기존 저장값 호환: extendPeriod → periodAdjust, memoUpdated → other
  static EnrollmentActionType _parseActionType(String? value) {
    if (value == null || value.isEmpty) return EnrollmentActionType.other;
    if (value == 'extendPeriod') return EnrollmentActionType.periodAdjust;
    if (value == 'memoUpdated') return EnrollmentActionType.other;
    return EnrollmentActionType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => EnrollmentActionType.other,
    );
  }
}

enum EnrollmentActionType {
  /// 횟수 조정. oldValue/newValue: totalReservations, remainingReservations. details: 요약.
  adjustCount,

  /// 유효기간 조정(연장·단축). oldValue/newValue: validFrom, validUntil(ISO8601). details: "연장" 또는 "단축" 요약.
  periodAdjust,

  /// 재등록. newValue: validFrom, validUntil, totalReservations 등. details: 사유/요약.
  reenroll,

  /// 수강 취소. oldValue: 취소 시점 상태. details: 사유(선택).
  cancel,

  /// 관리자 권한 예약 이동. oldValue: sessionId, fromDate. newValue: toSessionId, toDate. details: "A일 → B일" 요약.
  reservationMove,

  /// 관리자 권한 예약 취소. oldValue: sessionId, sessionDate. details: 세션 식별 요약.
  reservationCancel,

  other,
}
