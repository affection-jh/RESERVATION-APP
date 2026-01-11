import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/user.dart';
import '../models/pending_member.dart';
import '../services/user_service.dart';
import '../services/member_service.dart';
import '../services/enrollment_service.dart';

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

  // 코스별 멤버 캐시 (courseId -> List<User>)
  final Map<String, List<User>> _courseMembersCache = {};
  final Map<String, StreamSubscription> _courseMemberSubscriptions = {};

  List<User> get members => List.unmodifiable(_members);
  List<PendingMember> get pendingMembers => List.unmodifiable(_pendingMembers);
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 플레이스 멤버 목록 로드 (courseMembers 기반 + pendingMembers)
  /// users.placeIds는 더 이상 사용하지 않으므로 courseMembers에서 조회
  Future<void> loadMembers(String placeId) async {
    if (kDebugMode) {
      debugPrint('[MemberProvider] loadMembers start placeId=$placeId');
    }
    // 기존 구독이 있으면 취소
    await _memberSubscription?.cancel();
    await _pendingMemberSubscription?.cancel();
    _memberSubscription = null;
    _pendingMemberSubscription = null;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final enrollmentService = EnrollmentService();

      // courseMembers 기반으로 멤버 조회 (users.placeIds 대신)
      _memberSubscription = enrollmentService
          .watchPlaceCourseMembers(placeId: placeId)
          .asyncMap((courseMembers) async {
            if (kDebugMode) {
              debugPrint(
                '[MemberProvider] courseMembers updated placeId=$placeId count=${courseMembers.length}',
              );
            }

            if (courseMembers.isEmpty) {
              return <User>[];
            }

            // userId 리스트 추출 (중복 제거)
            final userIds = courseMembers
                .map((cm) => cm.userId)
                .where((id) => id.isNotEmpty)
                .toSet()
                .toList();

            if (kDebugMode) {
              debugPrint(
                '[MemberProvider] courseMembers userIds=$userIds (count=${userIds.length})',
              );
            }

            // 캐시에 없는 userId만 조회
            final missingUserIds = userIds
                .where((id) => !_userCache.containsKey(id))
                .toList();

            // 배치 조회
            if (missingUserIds.isNotEmpty) {
              try {
                final fetchedUsers = await _userService.getUsersByIds(
                  missingUserIds,
                );
                // 캐시에 저장
                for (final user in fetchedUsers) {
                  _userCache[user.userId] = user;
                }
                if (kDebugMode) {
                  debugPrint(
                    '[MemberProvider] fetched users count=${fetchedUsers.length}',
                  );
                }
              } catch (e) {
                if (kDebugMode) {
                  debugPrint('[MemberProvider] Batch user fetch error: $e');
                }
              }
            }

            // 캐시에서 User 정보 가져오기
            final users = userIds
                .map((id) => _userCache[id])
                .whereType<User>()
                .toList();

            if (kDebugMode) {
              debugPrint('[MemberProvider] final users count=${users.length}');
            }

            return users;
          })
          .listen(
            (members) {
              _members = members;
              _error = null;
              _isLoading = false;
              if (kDebugMode) {
                debugPrint(
                  '[MemberProvider] members updated placeId=$placeId count=${members.length}',
                );
              }
              notifyListeners();
            },
            onError: (error) {
              _error = error.toString();
              _members = [];
              _isLoading = false;
              if (kDebugMode) {
                debugPrint(
                  '[MemberProvider] courseMembers error placeId=$placeId error=$_error',
                );
              }
              notifyListeners();
            },
          );

      // PendingMembers Stream 구독
      _pendingMemberSubscription = _memberService
          .watchPendingMembersByPlace(placeId)
          .listen(
            (pendingMembers) {
              _pendingMembers = pendingMembers;
              if (kDebugMode) {
                debugPrint(
                  '[MemberProvider] pendingMembers updated placeId=$placeId count=${pendingMembers.length}',
                );
              }
              notifyListeners();
            },
            onError: (error) {
              // pendingMembers 에러는 무시
              _pendingMembers = [];
              if (kDebugMode) {
                debugPrint(
                  '[MemberProvider] pendingMembers error placeId=$placeId error=$error',
                );
              }
            },
          );
    } catch (e) {
      _error = e.toString();
      _members = [];
      _pendingMembers = [];
      _isLoading = false;
      if (kDebugMode) {
        debugPrint(
          '[MemberProvider] loadMembers catch placeId=$placeId error=$_error',
        );
      }
      notifyListeners();
    }
  }

  /// 플레이스 멤버 실시간 구독 (courseMembers 기반)
  Stream<List<User>> watchMembers(String placeId) {
    final enrollmentService = EnrollmentService();

    return enrollmentService.watchPlaceCourseMembers(placeId: placeId).asyncMap(
      (courseMembers) async {
        if (courseMembers.isEmpty) {
          return <User>[];
        }

        // userId 리스트 추출 (중복 제거)
        final userIds = courseMembers
            .map((cm) => cm.userId)
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList();

        // 캐시에 없는 userId만 조회
        final missingUserIds = userIds
            .where((id) => !_userCache.containsKey(id))
            .toList();

        if (missingUserIds.isNotEmpty) {
          try {
            final fetchedUsers = await _userService.getUsersByIds(
              missingUserIds,
            );
            for (final user in fetchedUsers) {
              _userCache[user.userId] = user;
            }
          } catch (e) {
            // 에러 무시
          }
        }

        // 캐시에서 User 정보 가져오기
        final users = userIds
            .map((id) => _userCache[id])
            .whereType<User>()
            .toList();

        _members = users;
        notifyListeners();
        return users;
      },
    );
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
    // 캐시도 초기화
    _userCache.clear();
    _courseMembersCache.clear();
    notifyListeners();
  }

  // userId -> User 캐시 (전역, 여러 코스에서 공유)
  final Map<String, User> _userCache = {};

  /// 코스별 멤버 조회 (courseMembers 컬렉션 직접 조회)
  ///
  /// enrollments가 생성되기 전에도 courseMembers가 있으면 표시됨
  ///
  /// ✅ 최적화:
  /// - courseMembers는 Stream으로 실시간 업데이트
  /// - users는 캐시 활용 (이미 조회한 userId는 재조회 안 함)
  /// - 배치 조회로 네트워크 호출 최소화
  Stream<List<User>> watchCourseMembers(String courseId) {
    final enrollmentService = EnrollmentService();

    return enrollmentService.watchCourseMembers(courseId: courseId).asyncMap((
      courseMembers,
    ) async {
      if (kDebugMode) {
        debugPrint(
          '[MemberProvider] watchCourseMembers: courseId=$courseId, count=${courseMembers.length}',
        );
      }

      if (courseMembers.isEmpty) {
        _courseMembersCache[courseId] = [];
        return <User>[];
      }

      // userId 리스트 추출 (null 제외)
      final userIds = courseMembers
          .map((cm) => cm.userId)
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      if (kDebugMode) {
        debugPrint('[MemberProvider] watchCourseMembers: userIds=$userIds');
      }

      // 캐시에 없는 userId만 조회
      final missingUserIds = userIds
          .where((id) => !_userCache.containsKey(id))
          .toList();

      // 배치 조회 (최대 10개씩)
      if (missingUserIds.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
            '[MemberProvider] watchCourseMembers: missingUserIds=$missingUserIds',
          );
        }
        try {
          final fetchedUsers = await _userService.getUsersByIds(missingUserIds);
          if (kDebugMode) {
            debugPrint(
              '[MemberProvider] watchCourseMembers: fetchedUsers count=${fetchedUsers.length}',
            );
          }
          // 캐시에 저장
          for (final user in fetchedUsers) {
            _userCache[user.userId] = user;
            if (kDebugMode) {
              debugPrint(
                '[MemberProvider] watchCourseMembers: cached user=${user.userId}, name=${user.name}',
              );
            }
          }

          // users 컬렉션에 없는 userId 확인
          final fetchedUserIds = fetchedUsers.map((u) => u.userId).toSet();
          final missingInUsers = missingUserIds
              .where((id) => !fetchedUserIds.contains(id))
              .toList();
          if (missingInUsers.isNotEmpty && kDebugMode) {
            debugPrint(
              '[MemberProvider] ⚠️ watchCourseMembers: users 컬렉션에 없는 userId들: $missingInUsers',
            );
            debugPrint(
              '[MemberProvider] ⚠️ 이 userId들은 courseMembers에는 있지만 users 컬렉션에 없습니다.',
            );
          }
        } catch (e, stackTrace) {
          if (kDebugMode) {
            debugPrint('[MemberProvider] Batch user fetch error: $e');
            debugPrint('[MemberProvider] Stack trace: $stackTrace');
          }
        }
      }

      // 캐시에서 User 정보 가져오기 (users 컬렉션에 있는 것만)
      final users = userIds
          .map((id) => _userCache[id])
          .whereType<User>()
          .toList();

      // users 컬렉션에 없는 userId가 있는지 확인
      final foundUserIds = users.map((u) => u.userId).toSet();
      final notFoundUserIds = userIds
          .where((id) => !foundUserIds.contains(id))
          .toList();
      if (notFoundUserIds.isNotEmpty && kDebugMode) {
        debugPrint(
          '[MemberProvider] ⚠️ watchCourseMembers: 최종 결과에서 제외된 userId들: $notFoundUserIds',
        );
        debugPrint(
          '[MemberProvider] ⚠️ 이 userId들은 courseMembers에는 있지만 users 컬렉션에 없어서 표시되지 않습니다.',
        );
      }

      if (kDebugMode) {
        debugPrint(
          '[MemberProvider] watchCourseMembers: final users count=${users.length}',
        );
        for (final user in users) {
          debugPrint(
            '[MemberProvider] watchCourseMembers: user=${user.userId}, name=${user.name}',
          );
        }
      }

      _courseMembersCache[courseId] = users;
      return users;
    });
  }

  /// 코스별 멤버 가져오기 (캐시된 값)
  List<User> getCourseMembers(String courseId) {
    return _courseMembersCache[courseId] ?? [];
  }

  /// 리소스 정리 (Provider dispose 시 호출)
  @override
  void dispose() {
    _memberSubscription?.cancel();
    _pendingMemberSubscription?.cancel();
    for (final subscription in _courseMemberSubscriptions.values) {
      subscription.cancel();
    }
    _courseMemberSubscriptions.clear();
    _courseMembersCache.clear();
    _userCache.clear(); // User 캐시도 정리
    super.dispose();
  }
}
