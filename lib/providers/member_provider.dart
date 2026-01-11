import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/user.dart';
import '../models/pending_member.dart';
import '../services/user_service.dart';
import '../services/member_service.dart';

/// 멤버 관리 Provider
///
/// 플레이스 멤버 목록 및 관리 (pendingMembers 포함)
class MemberProvider with ChangeNotifier {
  final UserService _userService = UserService();
  final MemberService _memberService = MemberService();

  List<User> _members = [];
  List<PendingMember> _pendingMembers = [];
  bool _isLoading = false;
  String? _error;
  StreamSubscription<List<User>>? _memberSubscription;
  StreamSubscription<List<PendingMember>>? _pendingMemberSubscription;

  List<User> get members => List.unmodifiable(_members);
  List<PendingMember> get pendingMembers => List.unmodifiable(_pendingMembers);
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 플레이스 멤버 목록 로드 (users + pendingMembers)
  Future<void> loadMembers(String placeId) async {
    // 기존 구독이 있으면 취소
    await _memberSubscription?.cancel();
    await _pendingMemberSubscription?.cancel();
    _memberSubscription = null;
    _pendingMemberSubscription = null;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Users Stream 구독
      _memberSubscription = _userService
          .watchUsersByPlace(placeId)
          .listen(
            (members) {
              _members = members;
              _error = null;
              _isLoading = false;
              notifyListeners();
            },
            onError: (error) {
              _error = error.toString();
              _members = [];
              _isLoading = false;
              notifyListeners();
            },
          );

      // PendingMembers Stream 구독
      _pendingMemberSubscription = _memberService
          .watchPendingMembersByPlace(placeId)
          .listen(
            (pendingMembers) {
              _pendingMembers = pendingMembers;
              notifyListeners();
            },
            onError: (error) {
              // pendingMembers 에러는 무시 (users만 있어도 됨)
              _pendingMembers = [];
            },
          );
    } catch (e) {
      _error = e.toString();
      _members = [];
      _pendingMembers = [];
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 플레이스 멤버 실시간 구독
  Stream<List<User>> watchMembers(String placeId) {
    return _userService.watchUsersByPlace(placeId).map((members) {
      _members = members;
      notifyListeners();
      return members;
    });
  }

  /// 멤버 가져오기
  User? getMember(String userId) {
    try {
      return _members.firstWhere((m) => m.userId == userId);
    } catch (e) {
      return null;
    }
  }

  /// 구독 취소 및 데이터 초기화
  Future<void> clear() async {
    await _memberSubscription?.cancel();
    await _pendingMemberSubscription?.cancel();
    _memberSubscription = null;
    _pendingMemberSubscription = null;
    _members = [];
    _pendingMembers = [];
    _isLoading = false;
    _error = null;
    notifyListeners();
  }

  /// 리소스 정리 (Provider dispose 시 호출)
  @override
  void dispose() {
    _memberSubscription?.cancel();
    _pendingMemberSubscription?.cancel();
    super.dispose();
  }
}
