/// 예약 모델 (개별 사용자 예약)
class SessionReservation {
  final String id;
  final String userId;
  final String courseId;
  final String placeId;
  final String enrollmentId; // 등록권 문서 ID (차감/환불/조회용)
  final int dayOfWeek;
  final String startTime;
  final DateTime reservedAt;
  final DateTime reservedDate;
  /// courseId_reservedDateString_startTime (조회/인덱스 단순화용)
  final String sessionKey;

  SessionReservation({
    required this.id,
    required this.userId,
    required this.courseId,
    required this.placeId,
    this.enrollmentId = '',
    required this.dayOfWeek,
    required this.startTime,
    required this.reservedAt,
    required this.reservedDate,
    this.sessionKey = '',
  });

  SessionReservation copyWith({
    String? id,
    String? userId,
    String? courseId,
    String? placeId,
    String? enrollmentId,
    int? dayOfWeek,
    String? startTime,
    DateTime? reservedAt,
    DateTime? reservedDate,
    String? sessionKey,
  }) {
    return SessionReservation(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      courseId: courseId ?? this.courseId,
      placeId: placeId ?? this.placeId,
      enrollmentId: enrollmentId ?? this.enrollmentId,
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      startTime: startTime ?? this.startTime,
      reservedAt: reservedAt ?? this.reservedAt,
      reservedDate: reservedDate ?? this.reservedDate,
      sessionKey: sessionKey ?? this.sessionKey,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'courseId': courseId,
      'placeId': placeId,
      if (enrollmentId.isNotEmpty) 'enrollmentId': enrollmentId,
      'dayOfWeek': dayOfWeek,
      'startTime': startTime,
      'reservedAt': reservedAt.toIso8601String(),
      'reservedDate': reservedDate.toIso8601String(),
      if (sessionKey.isNotEmpty) 'sessionKey': sessionKey,
    };
  }

  factory SessionReservation.fromJson(Map<String, dynamic> json) {
    return SessionReservation(
      id: json['id'] as String,
      userId: json['userId'] as String,
      courseId: json['courseId'] as String,
      placeId: json['placeId'] as String? ?? '',
      enrollmentId: json['enrollmentId'] as String? ?? '',
      dayOfWeek: json['dayOfWeek'] as int,
      startTime: json['startTime'] as String,
      reservedAt: DateTime.parse(json['reservedAt'] as String),
      reservedDate:
          json['reservedDate'] != null
              ? DateTime.parse(json['reservedDate'] as String)
              : DateTime.parse(json['reservedAt'] as String),
      sessionKey: json['sessionKey'] as String? ?? '',
    );
  }

  @override
  String toString() {
    return 'SessionReservation(id: $id, courseId: $courseId, dayOfWeek: $dayOfWeek, startTime: $startTime)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SessionReservation && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
