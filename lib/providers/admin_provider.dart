import 'package:flutter/foundation.dart';
import '../models/admin_user.dart';
import '../services/user_service.dart';

/// 관리자 정보 Provider
///
/// 현재 로그인한 관리자 정보 관리
class AdminProvider with ChangeNotifier {
  final UserService _userService = UserService();

  AdminUser? _currentAdmin;
  bool _isLoading = false;
  String? _error;

  AdminUser? get currentAdmin => _currentAdmin;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 관리자 정보 로드
  Future<void> loadAdmin(String userId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final admin = await _userService.getAdmin(userId);
      _currentAdmin = admin;
      _error = null;
    } catch (e) {
      _error = e.toString();
      _currentAdmin = null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 관리자 정보 업데이트
  Future<void> updateAdmin(AdminUser admin) async {
    _isLoading = true;
    notifyListeners();

    try {
      await _userService.updateAdmin(admin);
      if (_currentAdmin?.userId == admin.userId) {
        _currentAdmin = admin;
      }
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 관리자 설정
  void setCurrentAdmin(AdminUser admin) {
    _currentAdmin = admin;
    notifyListeners();
  }

  /// 관리자 초기화
  void clearAdmin() {
    _currentAdmin = null;
    _error = null;
    notifyListeners();
  }
}
