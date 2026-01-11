import 'dart:async';
import '../models/admin_user.dart';
import '../models/user.dart';
import '../models/course_enrollment.dart';
import '../models/place.dart';
import 'user_service.dart';

/// 어드민 관리 서비스
class AdminService {
  // 싱글톤 패턴
  static final AdminService _instance = AdminService._internal();
  factory AdminService() => _instance;
  AdminService._internal();

  // 현재 로그인한 어드민
  AdminUser? _currentAdmin;

  // 어드민 변경을 알리는 Stream Controller
  final _adminUpdateController = StreamController<AdminUser>.broadcast();
  final _extensionRequestController =
      StreamController<CourseEnrollment>.broadcast();

  // ==================== 현재 어드민 관리 ====================

  /// 현재 어드민 가져오기
  AdminUser? get currentAdmin => _currentAdmin;

  /// 어드민 로그인
  Future<void> login(String userId) async {
    // 실제로는 서버에서 어드민 정보를 가져와야 함
    _currentAdmin = await getAdmin(userId);
    _notifyAdminUpdate(_currentAdmin!);
  }

  /// 어드민 로그인 (관리자 정보 직접 전달)
  Future<void> loginWithAdmin(AdminUser admin) async {
    _currentAdmin = admin;
    _notifyAdminUpdate(admin);
  }

  /// 어드민 로그아웃
  void logout() {
    _currentAdmin = null;
  }

  /// 어드민 변경 구독
  Stream<AdminUser> watchAdmin() {
    return _adminUpdateController.stream;
  }

  // ==================== 어드민 CRUD ====================

  /// 어드민 생성
  Future<AdminUser> createAdmin({
    required String userId,
    required String name,
    required String phoneNumber,
    String? email,
  }) async {
    final admin = AdminUser(
      userId: userId,
      name: name,
      phoneNumber: phoneNumber,
      email: email,
      createdAt: DateTime.now(),
    );

    // 실제로는 서버에 저장해야 함
    if (_currentAdmin?.userId == userId) {
      _currentAdmin = admin;
      _notifyAdminUpdate(admin);
    }

    return admin;
  }

  /// 어드민 가져오기
  Future<AdminUser> getAdmin(String userId) async {
    // 실제로는 서버에서 가져와야 함
    throw UnimplementedError('서버 연동 필요');
  }

  /// 어드민 업데이트
  Future<AdminUser> updateAdmin(AdminUser admin) async {
    // 실제로는 서버에 업데이트해야 함
    if (_currentAdmin?.userId == admin.userId) {
      _currentAdmin = admin;
      _notifyAdminUpdate(admin);
    }
    return admin;
  }

  /// 어드민 프로필 업데이트
  Future<AdminUser> updateProfile({
    required String userId,
    String? name,
    String? phoneNumber,
    String? email,
  }) async {
    if (_currentAdmin == null || _currentAdmin!.userId != userId) {
      throw Exception('로그인된 어드민이 아닙니다.');
    }

    final updatedAdmin = _currentAdmin!.updateProfile(
      name: name,
      phoneNumber: phoneNumber,
      email: email,
    );

    return await updateAdmin(updatedAdmin);
  }

  // ==================== 플레이스 관리 ====================

  /// 플레이스 추가
  Future<AdminUser> addPlace(String userId, String placeId) async {
    final admin = await getAdmin(userId);
    final updatedAdmin = admin.addPlace(placeId);
    return await updateAdmin(updatedAdmin);
  }

  /// 플레이스 제거
  Future<AdminUser> removePlace(String userId, String placeId) async {
    final admin = await getAdmin(userId);
    return await updateAdmin(admin.removePlace(placeId));
  }

  /// 어드민이 관리하는 플레이스 목록 가져오기
  Future<List<Place>> getAdminPlaces(String userId) async {
    final admin = await getAdmin(userId);
    // 실제로는 PlaceService에서 플레이스 정보를 가져와야 함
    throw UnimplementedError('PlaceService 연동 필요');
  }

  // ==================== 유저 관리 ====================

  /// 유저 목록 가져오기 (특정 플레이스의)
  Future<List<User>> getUsersByPlace(String placeId) async {
    // 실제로는 서버에서 가져와야 함
    throw UnimplementedError('서버 연동 필요');
  }

  /// 유저 가져오기
  Future<User> getUser(String userId) async {
    // 실제로는 서버에서 가져와야 함
    throw UnimplementedError('서버 연동 필요');
  }

  // ==================== 연장 요청 관리 ====================

  /// 연장 요청 목록 가져오기 (특정 플레이스의)
  Future<List<CourseEnrollment>> getExtensionRequestsByPlace(
    String placeId,
  ) async {
    // 실제로는 서버에서 가져와야 함
    // 여기서는 UserService를 통해 가져올 수 있음
    throw UnimplementedError('서버 연동 필요');
  }

  /// 모든 연장 요청 목록 가져오기
  Future<List<CourseEnrollment>> getAllExtensionRequests() async {
    // 실제로는 서버에서 가져와야 함
    throw UnimplementedError('서버 연동 필요');
  }

  /// 연장 요청 승인
  Future<CourseEnrollment> approveExtension({
    required String userId,
    required String courseId,
    required DateTime newValidUntil,
  }) async {
    // UserService를 통해 유저 정보 가져오기
    final userService = UserService();
    final user = await userService.getUser(userId);
    final enrollment = user.getEnrollment(courseId);

    if (enrollment == null) {
      throw Exception('등록 정보를 찾을 수 없습니다.');
    }

    if (enrollment.extensionRequest == null ||
        enrollment.extensionRequest!.status != ExtensionRequestStatus.pending) {
      throw Exception('승인할 연장 요청이 없습니다.');
    }

    final updatedEnrollment = enrollment.approveExtension(newValidUntil);
    final updatedUser = user.updateEnrollment(updatedEnrollment);
    await userService.updateUser(updatedUser);

    _notifyExtensionRequest(updatedEnrollment);

    return updatedEnrollment;
  }

  /// 연장 요청 거부
  Future<CourseEnrollment> rejectExtension({
    required String userId,
    required String courseId,
    String? reason,
  }) async {
    // UserService를 통해 유저 정보 가져오기
    final userService = UserService();
    final user = await userService.getUser(userId);
    final enrollment = user.getEnrollment(courseId);

    if (enrollment == null) {
      throw Exception('등록 정보를 찾을 수 없습니다.');
    }

    if (enrollment.extensionRequest == null ||
        enrollment.extensionRequest!.status != ExtensionRequestStatus.pending) {
      throw Exception('거부할 연장 요청이 없습니다.');
    }

    final updatedEnrollment = enrollment.rejectExtension(reason);
    final updatedUser = user.updateEnrollment(updatedEnrollment);
    await userService.updateUser(updatedUser);

    _notifyExtensionRequest(updatedEnrollment);

    return updatedEnrollment;
  }

  // ==================== 알림 ====================

  void _notifyAdminUpdate(AdminUser admin) {
    _adminUpdateController.add(admin);
  }

  void _notifyExtensionRequest(CourseEnrollment enrollment) {
    _extensionRequestController.add(enrollment);
  }

  /// 연장 요청 변경 구독
  Stream<CourseEnrollment> watchExtensionRequests() {
    return _extensionRequestController.stream;
  }

  // ==================== 리소스 정리 ====================

  void dispose() {
    _adminUpdateController.close();
    _extensionRequestController.close();
  }
}
