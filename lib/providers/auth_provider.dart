import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/fcm_service.dart';
import '../services/member_service.dart';
import '../models/user.dart';
import '../models/place_member.dart';

/// 인증 상태 Provider
/// User 단일 모델 + places/{placeId}/members 기반 PlaceMember로 관리자/멤버 구분
class AuthProvider with ChangeNotifier {
  final AuthService _authService = AuthService();
  final FcmService _fcmService = FcmService();
  final MemberService _memberService = MemberService();

  User? _currentUser;
  List<PlaceMember> _placeMemberships = [];
  StreamSubscription<List<PlaceMember>>? _placeMembershipsSubscription;
  List<String> _approvedPlaceIds = [];
  User? _linkedAdmin;
  List<String> _adminManagedPlaceIdsOverride = [];
  bool _isLoading = false;
  String? _error;
  bool _isAuthenticated = false;
  String? _initializedFcmUserId;

  User? get currentUser => _currentUser;
  List<PlaceMember> get placeMemberships => _placeMemberships;
  List<String> get placeIdsFromPlaceMemberships =>
      _placeMemberships.map((m) => m.placeId).whereType<String>().toList();
  List<String> get managedPlaceIdsFromMemberships =>
      _placeMemberships
          .where((m) => m.canManagePlace && m.placeId != null)
          .map((m) => m.placeId!)
          .toList();

  /// 해당 플레이스에 대한 현재 사용자 PlaceMember (역할·manageableCourseIds 확인용)
  PlaceMember? getPlaceMemberForPlace(String placeId) {
    if (placeId.isEmpty) return null;
    try {
      return _placeMemberships.firstWhere(
        (m) => m.placeId == placeId,
        orElse: () => throw StateError('no membership'),
      );
    } catch (_) {
      return null;
    }
  }

  /// 해당 플레이스에서 현재 사용자가 부매니저인지 (매니저가 아님)
  bool isSubManagerForPlace(String placeId) {
    final m = getPlaceMemberForPlace(placeId);
    return m != null && m.isSubManager;
  }

  /// 관리 플레이스 ID (placeMemberships 기반, linkedAdmin일 땐 override 사용)
  List<String> get adminManagedPlaceIds =>
      _linkedAdmin != null
          ? _adminManagedPlaceIdsOverride
          : managedPlaceIdsFromMemberships;
  List<String> get approvedPlaceIds => _approvedPlaceIds;
  User? get linkedAdmin => _linkedAdmin;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAuthenticated => _isAuthenticated;
  bool get isManagerMode =>
      managedPlaceIdsFromMemberships.isNotEmpty || _linkedAdmin != null;

  /// 관리자 화면용: 매니저 모드일 때만 non-null (currentUser와 동일, 호환용)
  User? get currentManagerUser => isManagerMode ? _currentUser : null;

  /// 호환용: currentUser와 동일 (AdminProvider 제거 후 AuthProvider 단일 사용)
  User? get currentAdmin => _currentUser;
  void setCurrentAdmin(User user) => setCurrentUser(user);
  void clearAdmin() {
    /* no-op */
  }
  void clearCurrentAdmin() => clearAdmin();

  /// 로그인 (전화번호 + 인증코드). 신규 사용자는 name 필요.
  Future<User?> loginUser({
    required String phoneNumber,
    required String verificationCode,
    String? name,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _authService.verifyCodeAndSignIn(
        smsCode: verificationCode,
        phoneNumber: phoneNumber,
        name: name,
      );
      _currentUser = result.user;
      _isAuthenticated = true;
      _error = null;
      notifyListeners();
      await _initializeFcm(result.user.userId);
      await loadPlaceMembershipsForCurrentUser();
      startWatchingPlaceMemberships();
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

  /// 자동 로그인: Firebase Auth 세션 또는 저장된 사용자 기준
  Future<void> checkAutoLogin() async {
    _isLoading = true;
    notifyListeners();

    try {
      final userResult = await _authService.checkUserAutoLogin();
      if (userResult != null) {
        _currentUser = userResult.user;
        _isAuthenticated = true;
        _error = null;
        notifyListeners();
        await loadPlaceMembershipsForCurrentUser();
        startWatchingPlaceMemberships();
        return;
      }

      _currentUser = null;
      _isAuthenticated = false;
      _error = null;
    } catch (e) {
      _error = e.toString();
      _currentUser = null;
      _isAuthenticated = false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();
    try {
      final uid = _currentUser?.userId;
      if (uid != null) {
        try {
          await _fcmService.deleteToken(uid);
        } catch (e) {
          debugPrint('FCM 토큰 삭제 실패: $e');
        }
        await _authService.logout();
      }
      _currentUser = null;
      _linkedAdmin = null;
      _approvedPlaceIds = [];
      _adminManagedPlaceIdsOverride = [];
      stopWatchingPlaceMemberships();
      _isAuthenticated = false;
      _error = null;
      _initializedFcmUserId = null;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    } finally {
      _isLoading = false;
    }
  }

  void setCurrentUser(User user) {
    final isProfileUpdate = _currentUser?.userId == user.userId;
    _currentUser = user;
    _isAuthenticated = true;
    notifyListeners();

    if (!isProfileUpdate || _initializedFcmUserId != user.userId) {
      _initializeFcm(user.userId).catchError((e) {
        debugPrint('FCM 초기화 실패: $e');
      });
    }
  }

  void setApprovedPlaceIds(List<String> placeIds) {
    _approvedPlaceIds = placeIds;
    notifyListeners();
  }

  void setLinkedAdmin(User? admin) {
    _linkedAdmin = admin;
    if (admin == null) _adminManagedPlaceIdsOverride = [];
    notifyListeners();
  }

  void setAdminManagedPlaceIds(List<String> placeIds) {
    _adminManagedPlaceIdsOverride = placeIds;
    notifyListeners();
  }

  /// 플레이스 추가 직후 관리 목록에 반영 (PlaceSwitch 관리자 모드에 즉시 노출)
  void addAdminManagedPlace(String placeId) {
    if (placeId.isEmpty) return;
    if (_linkedAdmin != null) {
      if (!_adminManagedPlaceIdsOverride.contains(placeId)) {
        _adminManagedPlaceIdsOverride = [..._adminManagedPlaceIdsOverride, placeId];
        notifyListeners();
      }
    } else {
      // linkedAdmin 없을 때는 placeMemberships 기반 → 재조회로 갱신
      loadPlaceMembershipsForCurrentUser();
    }
  }

  Future<void> loadPlaceMembershipsForCurrentUser() async {
    final uid = _currentUser?.userId;
    if (uid == null || uid.isEmpty) {
      _placeMemberships = [];
      notifyListeners();
      return;
    }
    try {
      _placeMemberships = await _memberService.getPlaceMembershipsForUser(uid);
      notifyListeners();
      final demoted = await _maybeDemoteSubManagersWithNoCourses();
      if (demoted) {
        _placeMemberships = await _memberService.getPlaceMembershipsForUser(uid);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[AuthProvider] loadPlaceMembershipsForCurrentUser 실패: $e');
      _placeMemberships = [];
      notifyListeners();
    }
  }

  /// 부매니저인데 관리 코스가 0개면 서버에서 일반 멤버로 전락시킨 뒤 true 반환
  Future<bool> _maybeDemoteSubManagersWithNoCourses() async {
    bool any = false;
    for (final m in _placeMemberships) {
      if (m.placeId == null) continue;
      if (!m.isSubManager) continue;
      if (m.manageableCourseIds.isNotEmpty) continue;
      final ok = await _memberService.demoteSubManagerToMemberIfNoCourses(m.placeId!);
      if (ok) any = true;
    }
    return any;
  }

  void startWatchingPlaceMemberships() {
    final uid = _currentUser?.userId;
    _placeMembershipsSubscription?.cancel();
    if (uid == null || uid.isEmpty) {
      _placeMemberships = [];
      notifyListeners();
      return;
    }
    _placeMembershipsSubscription = _memberService
        .watchPlaceMembershipsForUser(uid)
        .listen((list) {
          _placeMemberships = list;
          notifyListeners();
          Future.microtask(() async {
            final demoted = await _maybeDemoteSubManagersWithNoCourses();
            if (demoted && uid == _currentUser?.userId) {
              loadPlaceMembershipsForCurrentUser();
            }
          });
        });
  }

  void stopWatchingPlaceMemberships() {
    _placeMembershipsSubscription?.cancel();
    _placeMembershipsSubscription = null;
    _placeMemberships = [];
    notifyListeners();
  }

  Future<void> _initializeFcm(String userId) async {
    if (_initializedFcmUserId == userId) {
      await _fcmService.initialize(userId);
      return;
    }
    try {
      await _fcmService.initialize(userId);
      await _fcmService.checkInitialMessage();
      _initializedFcmUserId = userId;
    } catch (e) {
      debugPrint('[AuthProvider] FCM 초기화 실패: $e');
    }
  }

  Future<void> ensureFcmTokenSaved() async {
    final userId = _currentUser?.userId;
    if (userId == null) return;
    await _fcmService.ensureTokenForUser(userId);
  }
}
