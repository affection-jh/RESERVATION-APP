import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/fcm_service.dart';
import '../models/user.dart';
import '../models/admin_user.dart';

/// 인증 상태 Provider
///
/// 사용자 및 관리자 인증 상태 관리
class AuthProvider with ChangeNotifier {
  final AuthService _authService = AuthService();
  final FcmService _fcmService = FcmService();

  User? _currentUser;
  AdminUser? _currentAdmin;
  AdminUser? _linkedAdmin; // 일반 사용자인 경우 연결된 관리자 계정 (같은 전화번호)
  List<String> _approvedPlaceIds =
      []; // placeMemberships에서 가져온 승인된 플레이스 ID (스플래시에서 한 번만 로드)
  List<String> _adminManagedPlaceIds =
      []; // places.adminId로 가져온 "관리하는" 플레이스 ID (스플래시에서 한 번만 로드)
  bool _isLoading = false;
  String? _error;
  bool _isAuthenticated = false;
  String? _initializedFcmUserId; // FCM이 초기화된 userId 추적

  User? get currentUser => _currentUser;
  AdminUser? get currentAdmin => _currentAdmin;
  AdminUser? get linkedAdmin => _linkedAdmin; // 연결된 관리자 계정
  List<String> get approvedPlaceIds => _approvedPlaceIds; // 승인된 플레이스 ID 목록
  List<String> get adminManagedPlaceIds =>
      _adminManagedPlaceIds; // 관리하는 플레이스 ID 목록
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAuthenticated => _isAuthenticated;

  /// 사용자 로그인
  Future<User?> loginUser({
    required String phoneNumber,
    required String verificationCode,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // TODO: Firebase Auth 구현 시 verifyCodeAndSignIn 사용
      // 현재는 authenticateWithPhone 사용 (하위 호환성)
      final result = await _authService.authenticateWithPhone(
        phoneNumber: phoneNumber,
        verificationCode: verificationCode,
      );
      _currentUser = result.user;
      _currentAdmin = null;
      _isAuthenticated = true;
      _error = null;
      notifyListeners();

      // FCM 초기화 (사용자 로그인 시)
      await _initializeFcm(result.user.userId);

      return result.user;
    } catch (e) {
      _error = e.toString();
      _currentUser = null;
      _isAuthenticated = false;
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 관리자 로그인
  Future<AdminUser?> loginAdmin({
    required String phoneNumber,
    required String verificationCode,
    required String pin,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // 관리자 로그인 시 AuthResult.user는 AdminUser를 기반으로 생성된 User
      // 실제 AdminUser는 별도로 조회 필요
      final admin = await _authService.findAdminByPhone(phoneNumber);
      if (admin == null) {
        throw Exception('관리자 정보를 찾을 수 없습니다.');
      }

      _currentAdmin = admin;
      _currentUser = null;
      _isAuthenticated = true;
      _error = null;
      notifyListeners();

      // FCM 초기화 (관리자 로그인 시)
      await _initializeFcm(admin.userId);

      return admin;
    } catch (e) {
      _error = e.toString();
      _currentAdmin = null;
      _isAuthenticated = false;
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 관리자 회원가입
  Future<AdminUser?> registerAdmin({
    required String phoneNumber,
    required String verificationCode,
    required String name,
    required String pin,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final admin = await _authService.registerAdmin(
        phoneNumber: phoneNumber,
        verificationCode: verificationCode,
        name: name,
        pin: pin,
      );
      _currentAdmin = admin;
      _currentUser = null;
      _isAuthenticated = true;
      _error = null;
      notifyListeners();

      // FCM 초기화 (관리자 회원가입 시)
      await _initializeFcm(admin.userId);

      return admin;
    } catch (e) {
      _error = e.toString();
      _currentAdmin = null;
      _isAuthenticated = false;
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 자동 로그인 확인
  Future<void> checkAutoLogin() async {
    _isLoading = true;
    notifyListeners();

    try {
      // 관리자 자동 로그인 확인
      final adminResult = await _authService.checkAdminAutoLogin();
      if (adminResult != null) {
        _currentAdmin = adminResult.admin;
        _currentUser = null;
        _isAuthenticated = true;
        _error = null;
        notifyListeners();

        // FCM 초기화는 setCurrentAdmin에서 처리하므로 여기서는 호출하지 않음
        // (app_startup_screen에서 setCurrentAdmin을 호출하므로 중복 방지)

        return;
      }

      // 사용자 자동 로그인은 Firebase Auth의 authStateChanges()를 통해 처리
      // 현재는 관리자만 지원

      // TODO: 사용자 자동 로그인 구현 필요
      // 사용자 자동 로그인은 Firebase Auth의 authStateChanges()를 통해 처리
      // 현재는 관리자만 지원

      // 자동 로그인 실패
      _currentUser = null;
      _currentAdmin = null;
      _isAuthenticated = false;
      _error = null;
    } catch (e) {
      _error = e.toString();
      _currentUser = null;
      _currentAdmin = null;
      _isAuthenticated = false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 로그아웃
  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();

    try {
      if (_currentAdmin != null) {
        // FCM 토큰 삭제
        try {
          await _fcmService.deleteToken(_currentAdmin!.userId);
        } catch (e) {
          debugPrint('FCM 토큰 삭제 실패: $e');
        }
        await _authService.logoutAdmin();
      } else if (_currentUser != null) {
        // FCM 토큰 삭제
        try {
          await _fcmService.deleteToken(_currentUser!.userId);
        } catch (e) {
          debugPrint('FCM 토큰 삭제 실패: $e');
        }
        // 사용자 로그아웃 처리 (Firebase Auth 세션 정리 및 데이터 삭제)
        await _authService.logout();
      }
      _currentUser = null;
      _currentAdmin = null;
      _linkedAdmin = null; // 로그아웃 시 연결된 관리자 계정도 초기화
      _isAuthenticated = false;
      _error = null;
      _initializedFcmUserId = null; // 로그아웃 시 초기화된 userId 초기화
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    } finally {
      _isLoading = false;
    }
  }

  /// 사용자 설정
  void setCurrentUser(User user) {
    _currentUser = user;
    _isAuthenticated = true;
    notifyListeners();

    // FCM 초기화 (자동 로그인 시)
    _initializeFcm(user.userId).catchError((e) {
      debugPrint('FCM 초기화 실패: $e');
    });
  }

  /// 연결된 관리자 계정 설정 (일반 사용자와 같은 전화번호의 관리자)
  void setLinkedAdmin(AdminUser? admin) {
    _linkedAdmin = admin;
    notifyListeners();
  }

  /// 승인된 플레이스 ID 목록 설정 (스플래시에서 한 번만 호출)
  void setApprovedPlaceIds(List<String> placeIds) {
    debugPrint(
      '[AuthProvider.setApprovedPlaceIds] 승인된 플레이스 ID 설정: $placeIds (개수: ${placeIds.length})',
    );
    _approvedPlaceIds = placeIds;
    notifyListeners();
  }

  /// 관리하는 플레이스 ID 목록 설정 (스플래시에서 한 번만 호출)
  void setAdminManagedPlaceIds(List<String> placeIds) {
    _adminManagedPlaceIds = placeIds;
    notifyListeners();
  }

  /// 관리자 설정
  void setCurrentAdmin(AdminUser admin) {
    _currentAdmin = admin;
    _isAuthenticated = true;
    notifyListeners();

    // FCM 초기화 (관리자 자동 로그인 시)
    _initializeFcm(admin.userId).catchError((e) {
      debugPrint('FCM 초기화 실패: $e');
    });
  }

  /// 관리자 모드 해제 (멤버 모드로 전환 시 사용)
  void clearCurrentAdmin() {
    if (_currentAdmin == null) return;
    _currentAdmin = null;
    notifyListeners();
  }

  /// FCM 초기화 (공통 메서드)
  /// 중복 호출 방지: 같은 userId면 스킵
  Future<void> _initializeFcm(String userId) async {
    debugPrint('[AuthProvider] _initializeFcm() userId=$userId _initializedFcmUserId=$_initializedFcmUserId');
    if (_initializedFcmUserId == userId) {
      debugPrint('[AuthProvider] FCM 이미 초기화됨 → 토큰 갱신만 시도');
      await _fcmService.initialize(userId);
      return;
    }

    try {
      await _fcmService.initialize(userId);
      await _fcmService.checkInitialMessage();
      _initializedFcmUserId = userId;
      debugPrint('[AuthProvider] FCM 초기화 완료 _initializedFcmUserId=$userId');
    } catch (e) {
      debugPrint('[AuthProvider] FCM 초기화 실패: $e');
    }
  }
}
