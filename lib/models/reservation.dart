/// 예약 모델
class Reservation {
  final String id;
  final String userId;
  final String courseId;
  final String placeId; // 플레이스 ID (Firestore 쿼리 최적화용)
  final int dayOfWeek;
  final String startTime;
  final DateTime reservedAt; // 예약한 시간
  final DateTime reservedDate; // 예약한 날짜 (예약 대상 날짜)
  final String? note; // 메모

  Reservation({
    required this.id,
    required this.userId,
    required this.courseId,
    required this.placeId,
    required this.dayOfWeek,
    required this.startTime,
    required this.reservedAt,
    required this.reservedDate, // 예약 대상 날짜
    this.note,
  });

  // 복사본 생성
  Reservation copyWith({
    String? id,
    String? userId,
    String? courseId,
    String? placeId,
    int? dayOfWeek,
    String? startTime,
    DateTime? reservedAt,
    DateTime? reservedDate,
    String? note,
  }) {
    return Reservation(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      courseId: courseId ?? this.courseId,
      placeId: placeId ?? this.placeId,
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      startTime: startTime ?? this.startTime,
      reservedAt: reservedAt ?? this.reservedAt,
      reservedDate: reservedDate ?? this.reservedDate,
      note: note ?? this.note,
    );
  }

  // JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'courseId': courseId,
      'placeId': placeId,
      'dayOfWeek': dayOfWeek,
      'startTime': startTime,
      'reservedAt': reservedAt.toIso8601String(),
      'reservedDate': reservedDate.toIso8601String(),
      'note': note,
    };
  }

  // JSON에서 생성
  factory Reservation.fromJson(Map<String, dynamic> json) {
    return Reservation(
      id: json['id'] as String,
      userId: json['userId'] as String,
      courseId: json['courseId'] as String,
      placeId: json['placeId'] as String? ?? '', // 하위 호환성
      dayOfWeek: json['dayOfWeek'] as int,
      startTime: json['startTime'] as String,
      reservedAt: DateTime.parse(json['reservedAt'] as String),
      reservedDate: json['reservedDate'] != null
          ? DateTime.parse(json['reservedDate'] as String)
          : DateTime.parse(json['reservedAt'] as String), // 하위 호환성
      note: json['note'] as String?,
    );
  }

  @override
  String toString() {
    return 'Reservation(id: $id, courseId: $courseId, dayOfWeek: $dayOfWeek, startTime: $startTime)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Reservation && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
