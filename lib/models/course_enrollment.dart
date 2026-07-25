import 'enrollment_action.dart';
import '../utils/timezone_utils.dart';

class CourseEnrollment {
  //primary keys
  final String id;
  final String userId;
  final String placeId;
  final String courseId;

  /// 유저가 설정한 본인 이름
  final String userName;

  /// 관리자가 설정한 표시 이름
  final String adminDisplayName;

  // 현재 등록회차 기준으로 정의된 정보
  final DateTime validFrom;
  final DateTime validUntil;
  final DateTime enrolledAt;
  final int totalReservations;
  final int remainingReservations;

  //statistic
  final int totalEnrollmentCount;

  /// 코스별 탭에서 비활성 처리 시 true → 해당 코스 목록에서만 숨김
  final bool isInactive;

  /// 비활성/관리용 메모 (코스 단위)
  final String? inactiveMemo;

  /// 관리자가 이 수강에 대해 한 모든 중요 조치 (횟수조정, 유효기간 조정, 재등록, 수강 취소, 예약 이동/취소 등). 감사·분쟁 대비.
  final List<EnrollmentAction>? actionHistory;

  CourseEnrollment({
    required this.id,
    required this.userId,
    required this.courseId,
    required this.userName,
    required this.adminDisplayName,
    required this.placeId,
    required this.enrolledAt,
    this.totalEnrollmentCount = 1,
    required this.validFrom,
    required this.validUntil,
    required this.totalReservations,
    required this.remainingReservations,
    this.isInactive = false,
    this.inactiveMemo,
    this.actionHistory,
  });

  DateTime get firstEnrolledAt => enrolledAt;

  /// 서울 기준 오늘 날짜와 validUntil 날짜만 비교 (시간대/시각 해석 오류 방지)
  bool get isExpired {
    final todaySeoul = TimezoneUtils.getSeoulToday();
    final validUntilDateSeoul = TimezoneUtils.getSeoulDateOnly(validUntil);
    return todaySeoul.isAfter(validUntilDateSeoul);
  }

  /// 서울 기준 날짜만 비교: 오늘이 validFrom~validUntil 구간 안에 있을 때만 유효 (시작일·마감일 포함).
  bool get isValid {
    final todaySeoul = TimezoneUtils.getSeoulToday();
    final validFromDateSeoul = TimezoneUtils.getSeoulDateOnly(validFrom);
    final validUntilDateSeoul = TimezoneUtils.getSeoulDateOnly(validUntil);
    return !todaySeoul.isBefore(validFromDateSeoul) &&
        !todaySeoul.isAfter(validUntilDateSeoul);
  }

  bool get canReserve => isValid && remainingReservations > 0;

  /// 비활성 처리 가능: 유효기간 만료 또는 남은 횟수 0
  bool get isDeactivatable => isExpired || remainingReservations <= 0;

  /// 서울 기준 날짜만 비교: 세션 날짜가 validFrom~validUntil 구간 안인지 (시작일·마감일 포함).
  bool isSessionDateWithinValidity(DateTime sessionDate) {
    final sessionDateSeoul = TimezoneUtils.getSeoulDateOnly(sessionDate);
    final validFromDateSeoul = TimezoneUtils.getSeoulDateOnly(validFrom);
    final validUntilDateSeoul = TimezoneUtils.getSeoulDateOnly(validUntil);
    return !sessionDateSeoul.isBefore(validFromDateSeoul) &&
        !sessionDateSeoul.isAfter(validUntilDateSeoul);
  }

  /// 세션 날짜 기준 예약 가능 여부 (유효기간 + 남은 횟수).
  bool canReserveForSessionDate(DateTime sessionDate) =>
      isSessionDateWithinValidity(sessionDate) && remainingReservations > 0;

  bool get isOneTime => totalReservations == 1 && totalEnrollmentCount == 1;

  CourseEnrollment useReservation() {
    if (remainingReservations <= 0) {
      throw Exception('남은 예약 횟수가 없습니다.');
    }
    return copyWith(remainingReservations: remainingReservations - 1);
  }

  CourseEnrollment cancelReservation() {
    if (remainingReservations >= totalReservations) {
      throw Exception('남은 횟수가 이미 최대값입니다.');
    }
    return copyWith(remainingReservations: remainingReservations + 1);
  }

  CourseEnrollment copyWith({
    String? id,
    String? userId,
    String? userName,
    String? courseId,
    String? placeId,
    DateTime? enrolledAt,
    int? totalEnrollmentCount,
    DateTime? validFrom,
    DateTime? validUntil,
    int? totalReservations,
    int? remainingReservations,
    String? memo,
    bool clearMemo = false,
    String? adminDisplayName,
    bool? isInactive,
    String? inactiveMemo,
    bool clearInactiveMemo = false,
    List<EnrollmentAction>? actionHistory,
  }) {
    return CourseEnrollment(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      courseId: courseId ?? this.courseId,
      placeId: placeId ?? this.placeId,
      enrolledAt: enrolledAt ?? this.enrolledAt,
      totalEnrollmentCount: totalEnrollmentCount ?? this.totalEnrollmentCount,
      validFrom: validFrom ?? this.validFrom,
      validUntil: validUntil ?? this.validUntil,
      totalReservations: totalReservations ?? this.totalReservations,
      remainingReservations:
          remainingReservations ?? this.remainingReservations,
      adminDisplayName: adminDisplayName ?? this.adminDisplayName,
      isInactive: isInactive ?? this.isInactive,
      inactiveMemo:
          clearInactiveMemo ? null : (inactiveMemo ?? this.inactiveMemo),
      actionHistory: actionHistory ?? this.actionHistory,
    );
  }

  /// Firestore 저장 시 userName은 쓰지 않고 adminDisplayName만 저장
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'courseId': courseId,
      'placeId': placeId,
      'enrolledAt': enrolledAt.toIso8601String(),
      'totalEnrollmentCount': totalEnrollmentCount,
      'validFrom': validFrom.toIso8601String(),
      'validUntil': validUntil.toIso8601String(),
      'totalReservations': totalReservations,
      'remainingReservations': remainingReservations,
      'adminDisplayName': adminDisplayName,
      'isInactive': isInactive,
      if (inactiveMemo != null) 'inactiveMemo': inactiveMemo,
    };
  }

  factory CourseEnrollment.fromJson(Map<String, dynamic> json) {
    return CourseEnrollment(
      id: json['id'] as String,
      userId: json['userId'] as String,
      userName:
          (json['userName'] as String?) ??
          (json['adminDisplayName'] as String?) ??
          '',
      courseId: json['courseId'] as String,
      placeId: json['placeId'] as String,
      enrolledAt: DateTime.parse(json['enrolledAt'] as String),
      totalEnrollmentCount: json['totalEnrollmentCount'] as int? ?? 1,
      validFrom: DateTime.parse(json['validFrom'] as String),
      validUntil: DateTime.parse(json['validUntil'] as String),
      totalReservations: json['totalReservations'] as int,
      remainingReservations: json['remainingReservations'] as int,
      adminDisplayName:
          (json['adminDisplayName'] as String?) ??
          (json['displayName'] as String?) ??
          '',
      isInactive: json['isInactive'] == true,
      inactiveMemo: json['inactiveMemo'] as String?,
    );
  }

  @override
  String toString() {
    return 'CourseEnrollment(courseId: $courseId, remaining: $remainingReservations/$totalReservations, validUntil: $validUntil)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CourseEnrollment && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
