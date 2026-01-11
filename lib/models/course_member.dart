/// 코스-멤버 관계 모델
///
/// 코스별 멤버 조회 최적화를 위한 컬렉션
/// enrollments와 중복이지만 읽기 성능 향상을 위한 전략적 중복
class CourseMember {
  final String id;
  final String userId;
  final String courseId;
  final String placeId;
  final String enrollmentId; // enrollments 컬렉션 참조
  final DateTime enrolledAt;
  final bool isActive; // 유효한 등록인지
  final DateTime createdAt;
  final DateTime? updatedAt;

  CourseMember({
    required this.id,
    required this.userId,
    required this.courseId,
    required this.placeId,
    required this.enrollmentId,
    required this.enrolledAt,
    required this.isActive,
    required this.createdAt,
    this.updatedAt,
  });

  /// 복사본 생성
  CourseMember copyWith({
    String? id,
    String? userId,
    String? courseId,
    String? placeId,
    String? enrollmentId,
    DateTime? enrolledAt,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CourseMember(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      courseId: courseId ?? this.courseId,
      placeId: placeId ?? this.placeId,
      enrollmentId: enrollmentId ?? this.enrollmentId,
      enrolledAt: enrolledAt ?? this.enrolledAt,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'courseId': courseId,
      'placeId': placeId,
      'enrollmentId': enrollmentId,
      'enrolledAt': enrolledAt.toIso8601String(),
      'isActive': isActive,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  /// JSON에서 생성
  factory CourseMember.fromJson(Map<String, dynamic> json) {
    return CourseMember(
      id: json['id'] as String,
      userId: json['userId'] as String,
      courseId: json['courseId'] as String,
      placeId: json['placeId'] as String,
      enrollmentId: json['enrollmentId'] as String,
      enrolledAt: DateTime.parse(json['enrolledAt'] as String),
      isActive: json['isActive'] as bool,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }

  @override
  String toString() {
    return 'CourseMember(userId: $userId, courseId: $courseId, isActive: $isActive)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CourseMember &&
        other.userId == userId &&
        other.courseId == courseId;
  }

  @override
  int get hashCode => userId.hashCode ^ courseId.hashCode;
}
