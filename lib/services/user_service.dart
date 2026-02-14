import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user.dart';
import '../models/admin_user.dart';
import '../models/course_enrollment.dart';
import '../models/reservation.dart';
import '../models/place.dart';
import '../utils/reservation_utils.dart';
import '../utils/timezone_utils.dart';
import 'firestore_service.dart';

/// 유저 관리 서비스
class UserService {
  // 싱글톤 패턴
  static final UserService _instance = UserService._internal();
  factory UserService() => _instance;
  UserService._internal();

  final FirestoreService _firestoreService = FirestoreService();
  FirebaseFirestore get _firestore => _firestoreService.firestore;

  // 현재 로그인한 유저
  User? _currentUser;

  // 유저 변경을 알리는 Stream Controller
  final _userUpdateController = StreamController<User>.broadcast();
  final _enrollmentUpdateController =
      StreamController<CourseEnrollment>.broadcast();

  // Helper 메서드
  Timestamp _dateTimeToTimestamp(DateTime dateTime) {
    return Timestamp.fromDate(dateTime);
  }

  DateTime _timestampToDateTime(dynamic timestamp) {
    if (timestamp == null) return TimezoneUtils.getSeoulDateTime();
    if (timestamp is Timestamp) return timestamp.toDate();
    if (timestamp is String) return DateTime.parse(timestamp);
    throw Exception('Invalid timestamp format');
  }

  String _normalizePhoneNumber(String phoneNumber) {
    // 숫자만 추출
    String normalized = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');

    // +82로 시작하는 경우 0으로 변환
    if (normalized.startsWith('82')) {
      normalized = '0${normalized.substring(2)}';
    }

    // 0으로 시작하지 않으면 0 추가
    if (!normalized.startsWith('0')) {
      normalized = '0$normalized';
    }

    return normalized;
  }

  // ==================== 현재 유저 관리 ====================

  /// 현재 유저 가져오기
  User? get currentUser => _currentUser;

  /// 유저 로그인
  Future<void> login(String userId) async {
    // 실제로는 서버에서 유저 정보를 가져와야 함
    // 여기서는 임시로 처리
    _currentUser = await getUser(userId);
    _notifyUserUpdate(_currentUser!);
  }

  /// 유저 로그아웃
  void logout() {
    _currentUser = null;
  }

  /// 유저 변경 구독
  Stream<User> watchUser() {
    return _userUpdateController.stream;
  }

  // ==================== 유저 CRUD ====================

  /// 유저 생성
  Future<User> createUser({
    required String userId,
    required String name,
    required String phoneNumber,
  }) async {
    final user = User(
      userId: userId,
      name: name,
      phoneNumber: phoneNumber,
      createdAt: TimezoneUtils.getSeoulDateTime(),
    );

    final docRef = _firestore.collection('users').doc(user.userId);
    await docRef.set({
      ...user.toJson(),
      'createdAt': _dateTimeToTimestamp(user.createdAt),
      'updatedAt':
          user.updatedAt != null ? _dateTimeToTimestamp(user.updatedAt!) : null,
    });

    if (_currentUser?.userId == userId) {
      _currentUser = user;
      _notifyUserUpdate(user);
    }

    return user;
  }

  /// 유저 생성 (User 객체 직접 사용)
  Future<User> createUserFromModel(User user) async {
    final docRef = _firestore.collection('users').doc(user.userId);
    await docRef.set({
      ...user.toJson(),
      'createdAt': _dateTimeToTimestamp(user.createdAt),
      'updatedAt':
          user.updatedAt != null ? _dateTimeToTimestamp(user.updatedAt!) : null,
    });
    return user;
  }

  /// 유저 삭제
  Future<void> deleteUser(String userId) async {
    await _firestore.collection('users').doc(userId).delete();
    if (_currentUser?.userId == userId) {
      _currentUser = null;
    }
  }

  /// 플레이스별 사용자 목록 조회
  /// @deprecated users.placeIds는 더 이상 사용하지 않음. courseMembers 기반으로 조회하세요.
  @Deprecated('users.placeIds는 더 이상 사용하지 않음. courseMembers 기반으로 조회하세요.')
  Stream<List<User>> watchUsersByPlace(String placeId) {
    // users.placeIds는 더 이상 사용하지 않으므로 빈 리스트 반환
    return Stream.value([]);
  }

  /// 유저 가져오기
  Future<User> getUser(String userId) async {
    final doc = await _firestore.collection('users').doc(userId).get();
    if (!doc.exists) {
      throw Exception('사용자를 찾을 수 없습니다.');
    }

    final data = doc.data()!;
    data['userId'] = doc.id;
    data['createdAt'] =
        _timestampToDateTime(data['createdAt']).toIso8601String();
    if (data['updatedAt'] != null) {
      data['updatedAt'] =
          _timestampToDateTime(data['updatedAt']).toIso8601String();
    }

    final user = User.fromJson(data);
    if (_currentUser?.userId == userId) {
      _currentUser = user;
      _notifyUserUpdate(user);
    }
    return user;
  }

  /// 여러 유저를 한 번에 조회 (배치 조회)
  ///
  /// [userIds] 조회할 userId 리스트 (최대 10개)
  /// Returns: User 리스트 (존재하지 않는 userId는 제외)
  Future<List<User>> getUsersByIds(List<String> userIds) async {
    if (userIds.isEmpty) return [];

    // Firestore whereIn은 최대 10개까지만 가능
    const maxBatchSize = 10;
    final allUsers = <User>[];

    for (int i = 0; i < userIds.length; i += maxBatchSize) {
      final batch = userIds.skip(i).take(maxBatchSize).toList();
      try {
        final snapshot =
            await _firestore
                .collection('users')
                .where(FieldPath.documentId, whereIn: batch)
                .get();

        for (final doc in snapshot.docs) {
          final data = doc.data();
          data['userId'] = doc.id;
          data['createdAt'] =
              _timestampToDateTime(data['createdAt']).toIso8601String();
          if (data['updatedAt'] != null) {
            data['updatedAt'] =
                _timestampToDateTime(data['updatedAt']).toIso8601String();
          }
          allUsers.add(User.fromJson(data));
        }
      } catch (e) {
        // 배치 조회 실패 시 개별 조회로 폴백
        for (final userId in batch) {
          try {
            final user = await getUser(userId);
            allUsers.add(user);
          } catch (_) {
            // 개별 조회도 실패하면 스킵
          }
        }
      }
    }

    return allUsers;
  }

  /// 유저 업데이트
  ///
  /// 현재 로그인한 사용자의 정보만 업데이트 가능
  /// (관리자가 다른 사용자를 업데이트하는 경우는 updateUserDirect 사용)
  Future<User> updateUser(User user) async {
    // 현재 로그인한 사용자만 업데이트 가능
    if (_currentUser == null || _currentUser!.userId != user.userId) {
      throw Exception('본인의 정보만 수정할 수 있습니다.');
    }

    final docRef = _firestore.collection('users').doc(user.userId);
    await docRef.update({
      ...user.toJson(),
      // users.placeIds는 더 이상 사용하지 않으므로 기존 필드가 남아있다면 제거
      'placeIds': FieldValue.delete(),
      'updatedAt': _dateTimeToTimestamp(DateTime.now()),
    });

    if (_currentUser?.userId == user.userId) {
      _currentUser = user;
      _notifyUserUpdate(user);
    }
    return user;
  }

  /// 유저 직접 업데이트 (관리자용)
  ///
  /// 관리자가 다른 사용자의 정보를 업데이트할 때 사용
  /// 권한 체크 없이 직접 Firestore 업데이트
  Future<User> updateUserDirect(User user) async {
    final docRef = _firestore.collection('users').doc(user.userId);
    await docRef.update({
      ...user.toJson(),
      // users.placeIds는 더 이상 사용하지 않으므로 기존 필드가 남아있다면 제거
      'placeIds': FieldValue.delete(),
      'updatedAt': _dateTimeToTimestamp(DateTime.now()),
    });

    // 현재 로그인한 사용자와 동일한 경우에만 _currentUser 업데이트
    if (_currentUser?.userId == user.userId) {
      _currentUser = user;
      _notifyUserUpdate(user);
    }
    return user;
  }

  /// 유저 프로필 업데이트
  Future<User> updateProfile({
    required String userId,
    String? name,
    String? phoneNumber,
  }) async {
    if (_currentUser == null || _currentUser!.userId != userId) {
      throw Exception('로그인된 유저가 아닙니다.');
    }

    final updatedUser = _currentUser!.updateProfile(
      name: name,
      phoneNumber: phoneNumber,
    );

    return await updateUser(updatedUser);
  }

  /// 현재 플레이스 ID 업데이트 (서버 저장)
  Future<void> updateCurrentPlaceId(String userId, String? placeId) async {
    final docRef = _firestore.collection('users').doc(userId);
    await docRef.update({
      'currentPlaceId': placeId,
      'updatedAt': _dateTimeToTimestamp(TimezoneUtils.getSeoulDateTime()),
    });

    // 현재 로그인한 사용자와 동일한 경우에만 _currentUser 업데이트
    if (_currentUser?.userId == userId) {
      _currentUser = _currentUser!.copyWith(currentPlaceId: placeId);
      _notifyUserUpdate(_currentUser!);
    }
  }

  // ==================== 플레이스 관리 ====================

  /// 플레이스 추가
  Future<User> addPlace(String userId, String placeId) async {
    final user = await getUser(userId);
    return await updateUser(user.addPlace(placeId));
  }

  /// 플레이스 제거
  Future<User> removePlace(String userId, String placeId) async {
    final user = await getUser(userId);
    return await updateUser(user.removePlace(placeId));
  }

  /// 유저의 플레이스 목록 가져오기
  Future<List<Place>> getUserPlaces(String userId) async {
    // 실제로는 PlaceService에서 플레이스 정보를 가져와야 함
    throw UnimplementedError('PlaceService 연동 필요');
  }

  // ==================== 코스 등록 관리 ====================

  /// 코스 등록
  Future<CourseEnrollment> enrollCourse({
    required String userId,
    required String courseId,
    required String placeId,
    required int totalReservations,
    required DateTime validFrom,
    required DateTime validUntil,
  }) async {
    final user = await getUser(userId);

    // 이미 등록된 코스인지 확인
    if (user.isEnrolledInCourse(courseId)) {
      throw Exception('이미 등록된 코스입니다.');
    }

    final now = TimezoneUtils.getSeoulDateTime();
    final enrollment = CourseEnrollment(
      id: now.millisecondsSinceEpoch.toString(),
      userId: userId,
      courseId: courseId,
      placeId: placeId,
      enrolledAt: now,
      validFrom: validFrom,
      validUntil: validUntil,
      totalReservations: totalReservations,
      remainingReservations: totalReservations,
    );

    final updatedUser = user.addEnrollment(enrollment);
    await updateUser(updatedUser);

    _notifyEnrollmentUpdate(enrollment);

    return enrollment;
  }

  /// 코스 등록 정보 가져오기
  Future<CourseEnrollment?> getEnrollment(
    String userId,
    String courseId,
  ) async {
    final user = await getUser(userId);
    return user.getEnrollment(courseId);
  }

  /// 유저의 등록된 코스 목록 가져오기
  Future<List<CourseEnrollment>> getUserEnrollments(String userId) async {
    final user = await getUser(userId);
    return user.enrollments;
  }

  /// 유효한 등록만 가져오기
  Future<List<CourseEnrollment>> getValidEnrollments(String userId) async {
    final user = await getUser(userId);
    return user.validEnrollments;
  }

  /// 특정 플레이스의 등록된 코스들 가져오기
  Future<List<CourseEnrollment>> getEnrollmentsByPlace(
    String userId,
    String placeId,
  ) async {
    final user = await getUser(userId);
    return user.getEnrollmentsByPlace(placeId);
  }

  // ==================== 예약 가능 횟수 관리 ====================

  /// 예약 사용 (남은 횟수 차감)
  Future<CourseEnrollment> useReservation(
    String userId,
    String courseId,
  ) async {
    final user = await getUser(userId);
    final enrollment = user.getEnrollment(courseId);

    if (enrollment == null) {
      throw Exception('등록된 코스가 아닙니다.');
    }

    if (!enrollment.canReserve) {
      throw Exception('예약 가능한 횟수가 없거나 유효 기간이 만료되었습니다.');
    }

    final updatedEnrollment = enrollment.useReservation();
    final updatedUser = user.updateEnrollment(updatedEnrollment);
    await updateUser(updatedUser);

    _notifyEnrollmentUpdate(updatedEnrollment);

    return updatedEnrollment;
  }

  /// 예약 취소 (남은 횟수 복구)
  Future<CourseEnrollment> cancelReservationUsage(
    String userId,
    String courseId,
  ) async {
    final user = await getUser(userId);
    final enrollment = user.getEnrollment(courseId);

    if (enrollment == null) {
      throw Exception('등록된 코스가 아닙니다.');
    }

    final updatedEnrollment = enrollment.cancelReservation();
    final updatedUser = user.updateEnrollment(updatedEnrollment);
    await updateUser(updatedUser);

    _notifyEnrollmentUpdate(updatedEnrollment);

    return updatedEnrollment;
  }

  /// 남은 예약 가능 횟수 가져오기
  Future<int> getRemainingReservations(String userId, String courseId) async {
    final user = await getUser(userId);
    return user.getRemainingReservations(courseId);
  }

  // ==================== 유효 기간 관리 ====================

  /// 연장 요청
  Future<CourseEnrollment> requestExtension({
    required String userId,
    required String courseId,
    required String reason,
  }) async {
    final user = await getUser(userId);
    final enrollment = user.getEnrollment(courseId);

    if (enrollment == null) {
      throw Exception('등록된 코스가 아닙니다.');
    }

    final updatedEnrollment = enrollment.requestExtension(reason);
    final updatedUser = user.updateEnrollment(updatedEnrollment);
    await updateUser(updatedUser);

    _notifyEnrollmentUpdate(updatedEnrollment);

    return updatedEnrollment;
  }

  /// 연장 요청 취소
  Future<CourseEnrollment> cancelExtensionRequest({
    required String userId,
    required String courseId,
  }) async {
    final user = await getUser(userId);
    final enrollment = user.getEnrollment(courseId);

    if (enrollment == null) {
      throw Exception('등록된 코스가 아닙니다.');
    }

    final updatedEnrollment = enrollment.cancelExtensionRequest();
    final updatedUser = user.updateEnrollment(updatedEnrollment);
    await updateUser(updatedUser);

    _notifyEnrollmentUpdate(updatedEnrollment);

    return updatedEnrollment;
  }

  /// 연장 요청 대기 중인 등록들 가져오기
  Future<List<CourseEnrollment>> getPendingExtensionRequests(
    String userId,
  ) async {
    final user = await getUser(userId);
    return user.pendingExtensionRequests;
  }

  // ==================== 예약 기록 관리 ====================

  /// 예약 기록 추가
  Future<Reservation> addReservation(Reservation reservation) async {
    final user = await getUser(reservation.userId);

    // 코스 등록 확인
    if (!user.isEnrolledInCourse(reservation.courseId)) {
      throw Exception('등록된 코스가 아닙니다.');
    }

    // 예약 가능 여부 확인
    if (!user.canReserveCourse(reservation.courseId)) {
      throw Exception('예약 가능한 횟수가 없거나 유효 기간이 만료되었습니다.');
    }

    // 예약 사용 (남은 횟수 차감)
    await useReservation(reservation.userId, reservation.courseId);

    // 예약 기록 추가
    final updatedUser = user.addReservation(reservation);
    await updateUser(updatedUser);

    return reservation;
  }

  /// 예약 기록 제거
  Future<void> removeReservation(String userId, String reservationId) async {
    final user = await getUser(userId);
    final reservation = user.reservations.firstWhere(
      (r) => r.id == reservationId,
      orElse: () => throw Exception('예약 기록을 찾을 수 없습니다.'),
    );

    // 예약 취소 가능 여부 확인 (세션 시작 1시간 전까지)
    if (!ReservationUtils.isCancellationAvailable(reservation)) {
      throw Exception('세션 시작 1시간 전까지만 취소 가능합니다.');
    }

    // 예약 취소 (남은 횟수 복구)
    await cancelReservationUsage(userId, reservation.courseId);

    // 예약 기록 제거
    final updatedUser = user.removeReservation(reservationId);
    await updateUser(updatedUser);
  }

  /// 유저의 예약 기록 가져오기
  Future<List<Reservation>> getUserReservations(String userId) async {
    final user = await getUser(userId);
    return user.reservations;
  }

  /// 특정 코스의 예약 기록 가져오기
  Future<List<Reservation>> getReservationsByCourse(
    String userId,
    String courseId,
  ) async {
    final user = await getUser(userId);
    return user.getReservationsByCourse(courseId);
  }

  // ==================== 알림 ====================

  void _notifyUserUpdate(User user) {
    _userUpdateController.add(user);
  }

  void _notifyEnrollmentUpdate(CourseEnrollment enrollment) {
    _enrollmentUpdateController.add(enrollment);
  }

  /// 등록 정보 변경 구독
  Stream<CourseEnrollment> watchEnrollment(String courseId) {
    return _enrollmentUpdateController.stream.where(
      (e) => e.courseId == courseId,
    );
  }

  // ==================== 리소스 정리 ====================

  // ==================== Admin Users ====================

  /// 관리자 생성
  Future<AdminUser> createAdmin(AdminUser admin) async {
    final docRef = _firestore.collection('adminUsers').doc(admin.userId);
    await docRef.set({
      ...admin.toJson(),
      'createdAt': _dateTimeToTimestamp(admin.createdAt),
      'updatedAt':
          admin.updatedAt != null
              ? _dateTimeToTimestamp(admin.updatedAt!)
              : null,
    });
    return admin;
  }

  /// 관리자 조회 (userId로)
  Future<AdminUser?> getAdmin(String userId) async {
    final doc = await _firestore.collection('adminUsers').doc(userId).get();
    if (!doc.exists) return null;

    final data = doc.data()!;
    data['createdAt'] =
        _timestampToDateTime(data['createdAt']).toIso8601String();
    if (data['updatedAt'] != null) {
      data['updatedAt'] =
          _timestampToDateTime(data['updatedAt']).toIso8601String();
    }

    return AdminUser.fromJson(data);
  }

  /// 관리자 조회 (전화번호로)
  Future<AdminUser?> getAdminByPhone(String phoneNumber) async {
    // 전화번호 정규화
    final normalizedPhone = _normalizePhoneNumber(phoneNumber);

    final query = _firestore
        .collection('adminUsers')
        .where('phoneNumber', isEqualTo: normalizedPhone)
        .limit(1);

    final snapshot = await query.get();
    if (snapshot.docs.isEmpty) return null;

    final data = snapshot.docs.first.data();
    data['createdAt'] =
        _timestampToDateTime(data['createdAt']).toIso8601String();
    if (data['updatedAt'] != null) {
      data['updatedAt'] =
          _timestampToDateTime(data['updatedAt']).toIso8601String();
    }

    return AdminUser.fromJson(data);
  }

  /// 관리자 업데이트
  ///
  /// 현재 로그인한 관리자의 정보만 업데이트 가능
  ///
  /// ⚠️ 보안/권한: adminUsers.authPin/phoneNumber/userId/createdAt은
  /// 클라이언트에서 수정하지 않도록 한다(Cloud Function에서만).
  Future<AdminUser> updateAdmin(AdminUser admin) async {
    final docRef = _firestore.collection('adminUsers').doc(admin.userId);
    // ⚠️ 보안/권한: adminUsers.authPin/phoneNumber/userId/createdAt은
    // 클라이언트에서 수정하지 않도록 한다(Cloud Function에서만).
    final updateData = <String, dynamic>{
      'name': admin.name,
      'placeIds': admin.placeIds,
      'lastAccessedPlaceId': admin.lastAccessedPlaceId,
      'notificationsEnabled': admin.notificationsEnabled,
      'updatedAt':
          admin.updatedAt != null
              ? _dateTimeToTimestamp(admin.updatedAt!)
              : FieldValue.serverTimestamp(),
    };
    await docRef.update(updateData);
    return admin;
  }

  /// 관리자 삭제
  Future<void> deleteAdmin(String userId) async {
    await _firestore.collection('adminUsers').doc(userId).delete();
  }

  void dispose() {
    _userUpdateController.close();
    _enrollmentUpdateController.close();
  }
}
