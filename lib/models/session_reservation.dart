/// 세션별 예약 집계 모델
///
/// 특정 세션의 특정 날짜에 대한 예약 현황을 집계하여 저장
/// 캘린더 화면 성능 최적화를 위한 컬렉션
class SessionReservation {
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
  final bool isCancelled; // 세션 취소 여부

  SessionReservation({
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
    this.isCancelled = false,
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
  SessionReservation copyWith({
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
    bool? isCancelled,
  }) {
    return SessionReservation(
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
      isCancelled: isCancelled ?? this.isCancelled,
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

  /// JSON에서 생성
  factory SessionReservation.fromJson(Map<String, dynamic> json) {
    return SessionReservation(
      id: json['id'] as String,
      sessionId: json['sessionId'] as String,
      courseId: json['courseId'] as String,
      placeId: json['placeId'] as String,
      dayOfWeek: json['dayOfWeek'] as int,
      startTime: json['startTime'] as String,
      date: json['date'] as String,
      capacity: json['capacity'] as int,
      reservedCount: json['reservedCount'] as int,
      lastUpdated: DateTime.parse(json['lastUpdated'] as String),
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : null,
      isCancelled: json['isCancelled'] as bool? ?? false,
    );
  }

  @override
  String toString() {
    return 'SessionReservation(sessionId: $sessionId, date: $date, reserved: $reservedCount/$capacity)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SessionReservation &&
        other.sessionId == sessionId &&
        other.date == date;
  }

  @override
  int get hashCode => sessionId.hashCode ^ date.hashCode;
}
