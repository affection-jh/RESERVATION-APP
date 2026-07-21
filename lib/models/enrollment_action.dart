import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/timezone_utils.dart';

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
/// - [EnrollmentActionType.reservationCreate]: oldValue에 sessionId, sessionDate, dayOfWeek 등. details에 세션 식별 요약.
/// - [EnrollmentActionType.reservationCancel]: oldValue에 sessionId, sessionDate, cancelledByAdmin 등. details에 세션 식별 요약.
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
    if (value == null) return DateTime.fromMillisecondsSinceEpoch(0);
    if (value is String) return DateTime.parse(value);
    if (value is Timestamp) return value.toDate();
    return DateTime.fromMillisecondsSinceEpoch(0);
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

  /// 예약 취소가 관리자에 의해 수행됐는지 (oldValue.cancelledByAdmin)
  bool get isReservationCancelledByAdmin {
    if (actionType != EnrollmentActionType.reservationCancel) return false;
    if (oldValue?['cancelledByAdmin'] == true) return true;
    final text = details ?? '';
    return text.contains('관리자 취소');
  }

  /// 관리자가 대신 예약했는지 (newValue.createdByAdmin)
  bool get isReservationCreatedByAdmin =>
      actionType == EnrollmentActionType.reservationCreate &&
      newValue?['createdByAdmin'] == true;

  /// 타임라인 카드 제목 — 관리자 취소일 때만 (관리자) 표시
  String get reservationCancelDisplayLabel =>
      isReservationCancelledByAdmin ? '예약 취소 (관리자)' : '예약 취소';

  /// 타임라인 카드 제목 — 관리자 예약일 때만 (관리자) 표시
  String get reservationCreateDisplayLabel =>
      isReservationCreatedByAdmin ? '예약 (관리자)' : '예약';

  String? get reservationId =>
      oldValue?['reservationId'] as String? ??
      newValue?['reservationId'] as String?;

  Map<String, dynamic>? get _sessionFields => oldValue ?? newValue;

  int? get reservationDayOfWeek {
    final raw = _sessionFields?['dayOfWeek'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return null;
  }

  String? get reservationSessionDate =>
      _sessionFields?['sessionDate'] as String?;

  String? get reservationStartTime => _sessionFields?['startTime'] as String?;

  static const _dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];

  String? get reservationWeekdayLabel {
    final dow = reservationDayOfWeek;
    if (dow == null || dow < 1 || dow > 7) return null;
    return _dayNames[dow];
  }

  /// UI 「일시」 — 조치 수행 시각 (performedAt)
  String get performedDateTimeLine =>
      '일시: ${TimezoneUtils.formatDateTimeToSeoul(performedAt)}';

  /// UI 「일시」 — 예약/취소를 수행한 시각 (performedAt)
  String get reservationPerformedDateTimeLine => performedDateTimeLine;

  /// UI 「내용」용 — 세션 날짜·요일·시간
  String get reservationSessionInfoLabel {
    final sessionDate = reservationSessionDate;
    final startTime = reservationStartTime;
    final weekday = reservationWeekdayLabel;
    if (sessionDate != null && sessionDate.isNotEmpty) {
      final dateLabel = TimezoneUtils.formatDateStringDisplay(sessionDate);
      final weekdayPart = weekday != null ? ' ($weekday)' : '';
      final timePart =
          startTime != null && startTime.isNotEmpty ? ' $startTime' : '';
      return '$dateLabel$weekdayPart$timePart 세션';
    }
    if (details != null && details!.isNotEmpty) {
      return TimezoneUtils.formatDetailsDisplay(details);
    }
    return '세션';
  }

  /// UI 「내용」 — details (날짜 포맷 통일)
  String get detailsDisplayLine {
    final text = TimezoneUtils.formatDetailsDisplay(details);
    if (text.isEmpty) return '';
    return '내용: $text';
  }

  /// UI 「내용」 — 세션 정보
  String get reservationCreateContentLine =>
      '내용: $reservationSessionInfoLabel 예약';

  /// UI 「내용」 — 세션 정보 + 취소 주체
  String get reservationCancelContentLine {
    final actor = isReservationCancelledByAdmin ? '관리자 취소' : '본인 취소';
    return '내용: $reservationSessionInfoLabel · $actor';
  }

  String _sessionInfoLabelFrom(Map<String, dynamic>? fields) {
    if (fields == null) return '';
    final sessionDate = fields['sessionDate'] as String?;
    final startTime = fields['startTime'] as String?;
    final rawDow = fields['dayOfWeek'];
    final dow =
        rawDow is int
            ? rawDow
            : rawDow is num
            ? rawDow.toInt()
            : null;
    final weekday =
        (dow != null && dow >= 1 && dow <= 7) ? _dayNames[dow] : null;
    if (sessionDate != null && sessionDate.isNotEmpty) {
      final dateLabel = TimezoneUtils.formatDateStringDisplay(sessionDate);
      final weekdayPart = weekday != null ? ' ($weekday)' : '';
      final timePart =
          startTime != null && startTime.isNotEmpty ? ' $startTime' : '';
      return '$dateLabel$weekdayPart$timePart 세션';
    }
    return '';
  }

  /// UI 「내용」 — 이전 세션 → 새 세션
  String get reservationMoveContentLine {
    final from = _sessionInfoLabelFrom(oldValue);
    final to = _sessionInfoLabelFrom(newValue);
    if (from.isNotEmpty && to.isNotEmpty) {
      return '내용: $from → $to';
    }
    if (to.isNotEmpty) return '내용: $to로 이동';
    final text = TimezoneUtils.formatDetailsDisplay(details);
    if (text.isNotEmpty) return '내용: $text';
    return '내용: 예약 이동';
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

  /// 예약 생성. oldValue: sessionId, sessionDate, dayOfWeek. details: 세션 식별 요약.
  reservationCreate,

  /// 예약 취소. oldValue: sessionId, sessionDate, cancelledByAdmin. details: 세션 식별 요약.
  reservationCancel,

  other,
}
