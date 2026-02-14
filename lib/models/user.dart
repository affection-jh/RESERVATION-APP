import 'course_enrollment.dart';
import 'reservation.dart';
import '../utils/timezone_utils.dart';

/// 일반 유저 모델
class User {
  final String userId;
  final String name;
  final String phoneNumber; // 필수
  @Deprecated('users.placeIds는 더 이상 사용하지 않습니다. placeMemberships 기반으로 조회하세요.')
  final List<String> placeIds; // (레거시) 속한 플레이스들
  final String? currentPlaceId; // 현재 선택된 플레이스 ID (서버 저장)
  final List<CourseEnrollment> enrollments; // 등록한 코스들
  final List<Reservation> reservations; // 예약 기록
  final bool notificationsEnabled; // 알림 설정
  final DateTime createdAt;
  final DateTime? updatedAt;

  User({
    required this.userId,
    required this.name,
    required this.phoneNumber,
    this.placeIds = const [],
    this.currentPlaceId,
    this.enrollments = const [],
    this.reservations = const [],
    this.notificationsEnabled = true, // 기본값 true
    required this.createdAt,
    this.updatedAt,
  });

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
    bool? notificationsEnabled,
  }) {
    return copyWith(
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      updatedAt: TimezoneUtils.getSeoulDateTime(),
    );
  }

  // 복사본 생성
  User copyWith({
    String? userId,
    String? name,
    String? phoneNumber,
    List<String>? placeIds,
    String? currentPlaceId,
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
      placeIds: placeIds ?? this.placeIds,
      currentPlaceId: currentPlaceId ?? this.currentPlaceId,
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
      // users.placeIds는 더 이상 Firestore에 저장하지 않음 (placeMemberships 기반)
      'currentPlaceId': currentPlaceId, // 현재 선택된 플레이스 ID
      // enrollments 필드 제거: enrollments 컬렉션에서 직접 조회
      'reservations': reservations.map((r) => r.toJson()).toList(),
      'notificationsEnabled': notificationsEnabled,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  // JSON에서 생성
  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      userId: json['userId'] as String? ?? '',
      name: json['name'] as String? ?? '이름 없음',
      phoneNumber: json['phoneNumber'] as String? ?? '',
      placeIds: (json['placeIds'] as List?)?.cast<String>() ?? [],
      currentPlaceId: json['currentPlaceId'] as String?, // 현재 선택된 플레이스 ID
      // enrollments 필드 무시: enrollments 컬렉션에서 직접 조회
      enrollments: const [],
      reservations:
          (json['reservations'] as List?)
              ?.map((r) => Reservation.fromJson(r as Map<String, dynamic>))
              .toList() ??
          [],
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      createdAt:
          json['createdAt'] != null
              ? (json['createdAt'] is String
                  ? DateTime.parse(json['createdAt'] as String)
                  : DateTime.now())
              : DateTime.now(),
      updatedAt:
          json['updatedAt'] != null
              ? (json['updatedAt'] is String
                  ? DateTime.parse(json['updatedAt'] as String)
                  : null)
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
