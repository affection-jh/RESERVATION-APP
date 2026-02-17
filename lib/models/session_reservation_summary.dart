/// 세션별 예약 집계 모델
///
/// 특정 세션의 특정 날짜에 대한 예약 현황을 집계하여 저장
/// 캘린더 화면 성능 최적화를 위한 컬렉션
class SessionReservationSummary {
  final String id;
  final String sessionId; // "courseId_dayOfWeek_startTime"
  final String courseId;
  final String placeId;
  final int dayOfWeek;
  final String startTime;
  final String date; // "YYYY-MM-DD"
  final int capacity; // 해당 날짜의 수용인원
  final int reservedCount; // 예약된 인원 수
  final DateTime lastUpdated;
  final DateTime? createdAt;

  SessionReservationSummary({
    required this.id,
    required this.sessionId,
    required this.courseId,
    required this.placeId,
    required this.dayOfWeek,
    required this.startTime,
    required this.date,
    required this.capacity,
    required this.reservedCount,
    required this.lastUpdated,
    this.createdAt,
  });

  /// 남은 좌석 수
  int get remainingSeats => capacity - reservedCount;

  /// 예약 가능 여부
  bool get isAvailable => remainingSeats > 0;

  /// 세션 ID 생성 헬퍼
  static String generateSessionId(
    String courseId,
    int dayOfWeek,
    String startTime,
  ) {
    return '${courseId}_${dayOfWeek}_${startTime}';
  }

  /// 복사본 생성
  SessionReservationSummary copyWith({
    String? id,
    String? sessionId,
    String? courseId,
    String? placeId,
    int? dayOfWeek,
    String? startTime,
    String? date,
    int? capacity,
    int? reservedCount,
    DateTime? lastUpdated,
    DateTime? createdAt,
  }) {
    return SessionReservationSummary(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      courseId: courseId ?? this.courseId,
      placeId: placeId ?? this.placeId,
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      startTime: startTime ?? this.startTime,
      date: date ?? this.date,
      capacity: capacity ?? this.capacity,
      reservedCount: reservedCount ?? this.reservedCount,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sessionId': sessionId,
      'courseId': courseId,
      'placeId': placeId,
      'dayOfWeek': dayOfWeek,
      'startTime': startTime,
      'date': date,
      'capacity': capacity,
      'reservedCount': reservedCount,
      'lastUpdated': lastUpdated.toIso8601String(),
      'createdAt': createdAt?.toIso8601String(),
    };
  }

  /// JSON에서 생성 (Firestore 문서에 null 필드가 있어도 안전)
  factory SessionReservationSummary.fromJson(Map<String, dynamic> json) {
    return SessionReservationSummary(
      id: json['id'] as String,
      sessionId: json['sessionId'] as String,
      courseId: json['courseId'] as String,
      placeId: json['placeId'] as String,
      dayOfWeek: (json['dayOfWeek'] as num?)?.toInt() ?? 0,
      startTime: json['startTime'] as String,
      date: json['date'] as String,
      capacity: (json['capacity'] as num?)?.toInt() ?? 0,
      reservedCount: (json['reservedCount'] as num?)?.toInt() ?? 0,
      lastUpdated: DateTime.parse(json['lastUpdated'] as String),
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : null,
    );
  }

  @override
  String toString() {
    return 'SessionReservationSummary(sessionId: $sessionId, date: $date, reserved: $reservedCount/$capacity)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SessionReservationSummary &&
        other.sessionId == sessionId &&
        other.date == date;
  }

  @override
  int get hashCode => sessionId.hashCode ^ date.hashCode;
}
