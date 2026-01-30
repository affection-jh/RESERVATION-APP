/// 날짜별 수용인원 오버라이드 모델
///
/// 특정 세션의 특정 날짜에 대한 수용인원을 기본값과 다르게 설정
class DateCapacityOverride {
  final String id;
  final String placeId;
  final String? courseId; // 쿼리 최적화용 (sessionId에서 유도 가능)
  final String sessionId; // "courseId_dayOfWeek_startTime"
  final String date; // "YYYY-MM-DD"
  final int capacity; // 오버라이드된 수용인원
  final DateTime createdAt;
  final DateTime? updatedAt;

  DateCapacityOverride({
    required this.id,
    required this.placeId,
    this.courseId,
    required this.sessionId,
    required this.date,
    required this.capacity,
    required this.createdAt,
    this.updatedAt,
  });

  /// 복사본 생성
  DateCapacityOverride copyWith({
    String? id,
    String? placeId,
    String? courseId,
    String? sessionId,
    String? date,
    int? capacity,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return DateCapacityOverride(
      id: id ?? this.id,
      placeId: placeId ?? this.placeId,
      courseId: courseId ?? this.courseId,
      sessionId: sessionId ?? this.sessionId,
      date: date ?? this.date,
      capacity: capacity ?? this.capacity,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'placeId': placeId,
      'courseId': courseId,
      'sessionId': sessionId,
      'date': date,
      'capacity': capacity,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  /// JSON에서 생성
  factory DateCapacityOverride.fromJson(Map<String, dynamic> json) {
    return DateCapacityOverride(
      id: json['id'] as String,
      placeId: json['placeId'] as String? ?? '',
      courseId: json['courseId'] as String?,
      sessionId: json['sessionId'] as String,
      date: json['date'] as String,
      capacity: json['capacity'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt:
          json['updatedAt'] != null
              ? DateTime.parse(json['updatedAt'] as String)
              : null,
    );
  }

  @override
  String toString() {
    return 'DateCapacityOverride(placeId: $placeId, sessionId: $sessionId, date: $date, capacity: $capacity)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DateCapacityOverride &&
        other.sessionId == sessionId &&
        other.date == date;
  }

  @override
  int get hashCode => sessionId.hashCode ^ date.hashCode;
}
