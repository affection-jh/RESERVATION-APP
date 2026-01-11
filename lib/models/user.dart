import 'course_enrollment.dart';
import 'reservation.dart';

/// 일반 유저 모델
class User {
  final String userId;
  final String name;
  final String phoneNumber; // 필수
  final String? email; // 선택
  final List<String> placeIds; // 속한 플레이스들 (학원)
  final List<String> adminForPlaces; // 관리자로 관리하는 플레이스들 (새 필드)
  final List<CourseEnrollment> enrollments; // 등록한 코스들
  final List<Reservation> reservations; // 예약 기록
  final bool notificationsEnabled; // 알림 설정
  final DateTime createdAt;
  final DateTime? updatedAt;

  User({
    required this.userId,
    required this.name,
    required this.phoneNumber,
    this.email,
    this.placeIds = const [],
    this.adminForPlaces = const [], // 기본값: 빈 배열 (일반 유저)
    this.enrollments = const [],
    this.reservations = const [],
    this.notificationsEnabled = true, // 기본값 true
    required this.createdAt,
    this.updatedAt,
  });

  // 관리자 여부 확인
  bool get isAdmin => adminForPlaces.isNotEmpty;

  // 특정 플레이스를 관리하는지 확인
  bool isAdminForPlace(String placeId) {
    return adminForPlaces.contains(placeId);
  }

  // 특정 플레이스에 속해있는지 확인
  bool belongsToPlace(String placeId) {
    return placeIds.contains(placeId);
  }

  // 특정 코스에 등록되어 있는지 확인
  CourseEnrollment? getEnrollment(String courseId) {
    try {
      return enrollments.firstWhere((e) => e.courseId == courseId);
    } catch (e) {
      return null;
    }
  }

  // 특정 코스에 등록되어 있고 유효한지 확인
  bool isEnrolledInCourse(String courseId) {
    final enrollment = getEnrollment(courseId);
    return enrollment != null && enrollment.isValid;
  }

  // 특정 코스의 남은 예약 가능 횟수
  int getRemainingReservations(String courseId) {
    final enrollment = getEnrollment(courseId);
    if (enrollment == null) return 0;
    return enrollment.remainingReservations;
  }

  // 특정 코스의 예약 가능 여부
  bool canReserveCourse(String courseId) {
    final enrollment = getEnrollment(courseId);
    return enrollment != null && enrollment.canReserve;
  }

  // 특정 플레이스의 등록된 코스들
  List<CourseEnrollment> getEnrollmentsByPlace(String placeId) {
    return enrollments.where((e) => e.placeId == placeId).toList();
  }

  // 유효한 등록들만 가져오기
  List<CourseEnrollment> get validEnrollments {
    return enrollments.where((e) => e.isValid).toList();
  }

  // 만료된 등록들만 가져오기
  List<CourseEnrollment> get expiredEnrollments {
    return enrollments.where((e) => e.isExpired).toList();
  }

  // 연장 요청 대기 중인 등록들
  List<CourseEnrollment> get pendingExtensionRequests {
    return enrollments.where((e) => e.hasPendingExtensionRequest).toList();
  }

  // 특정 코스의 예약 기록
  List<Reservation> getReservationsByCourse(String courseId) {
    return reservations.where((r) => r.courseId == courseId).toList();
  }

  // 플레이스 추가
  User addPlace(String placeId) {
    if (placeIds.contains(placeId)) {
      return this;
    }
    return copyWith(placeIds: [...placeIds, placeId]);
  }

  // 플레이스 제거
  User removePlace(String placeId) {
    return copyWith(placeIds: placeIds.where((id) => id != placeId).toList());
  }

  // 코스 등록
  User addEnrollment(CourseEnrollment enrollment) {
    // 이미 등록된 코스인지 확인
    if (enrollments.any((e) => e.courseId == enrollment.courseId)) {
      throw Exception('이미 등록된 코스입니다.');
    }
    return copyWith(enrollments: [...enrollments, enrollment]);
  }

  // 코스 등록 업데이트
  User updateEnrollment(CourseEnrollment enrollment) {
    final index = enrollments.indexWhere((e) => e.id == enrollment.id);
    if (index == -1) {
      throw Exception('등록 정보를 찾을 수 없습니다.');
    }
    final newEnrollments = List<CourseEnrollment>.from(enrollments);
    newEnrollments[index] = enrollment;
    return copyWith(enrollments: newEnrollments);
  }

  // 예약 추가
  User addReservation(Reservation reservation) {
    return copyWith(reservations: [...reservations, reservation]);
  }

  // 예약 제거
  User removeReservation(String reservationId) {
    return copyWith(
      reservations: reservations.where((r) => r.id != reservationId).toList(),
    );
  }

  // 정보 업데이트
  User updateProfile({
    String? name,
    String? phoneNumber,
    String? email,
    bool? notificationsEnabled,
  }) {
    return copyWith(
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      email: email ?? this.email,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      updatedAt: DateTime.now(),
    );
  }

  // 복사본 생성
  User copyWith({
    String? userId,
    String? name,
    String? phoneNumber,
    String? email,
    List<String>? placeIds,
    List<String>? adminForPlaces,
    List<CourseEnrollment>? enrollments,
    List<Reservation>? reservations,
    bool? notificationsEnabled,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return User(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      email: email ?? this.email,
      placeIds: placeIds ?? this.placeIds,
      adminForPlaces: adminForPlaces ?? this.adminForPlaces,
      enrollments: enrollments ?? this.enrollments,
      reservations: reservations ?? this.reservations,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  // JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'name': name,
      'phoneNumber': phoneNumber,
      'email': email,
      'placeIds': placeIds,
      'adminForPlaces': adminForPlaces, // 새 필드 추가
      'enrollments': enrollments.map((e) => e.toJson()).toList(),
      'reservations': reservations.map((r) => r.toJson()).toList(),
      'notificationsEnabled': notificationsEnabled,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  // JSON에서 생성
  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      userId: json['userId'] as String,
      name: json['name'] as String,
      phoneNumber: json['phoneNumber'] as String,
      email: json['email'] as String?,
      placeIds: (json['placeIds'] as List?)?.cast<String>() ?? [],
      adminForPlaces:
          (json['adminForPlaces'] as List?)?.cast<String>() ?? [], // 새 필드 추가
      enrollments:
          (json['enrollments'] as List?)
              ?.map((e) => CourseEnrollment.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      reservations:
          (json['reservations'] as List?)
              ?.map((r) => Reservation.fromJson(r as Map<String, dynamic>))
              .toList() ??
          [],
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }

  @override
  String toString() {
    return 'User(userId: $userId, name: $name, places: ${placeIds.length}, enrollments: ${enrollments.length}, reservations: ${reservations.length})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is User && other.userId == userId;
  }

  @override
  int get hashCode => userId.hashCode;
}
