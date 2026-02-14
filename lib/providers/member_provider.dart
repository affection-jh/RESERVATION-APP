import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cloud_functions/cloud_functions.dart';
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
  StreamSubscription<Map<String, String>>? _membershipDisplayNameSubscription;

  // userId -> 관리자 표시 이름 (placeMemberships.displayName)
  Map<String, String> _membershipDisplayNamesByUserId = {};

  // 코스별 멤버 캐시 (courseId -> List<User>)
  final Map<String, List<User>> _courseMembersCache = {};
  final Map<String, StreamSubscription> _courseMemberSubscriptions = {};
  // 코스별 Stream 캐시 (중복 구독 방지)
  final Map<String, Stream<List<User>>> _courseMemberStreamCache = {};

  // 삭제 중인 멤버 ID Set (userId 또는 pending_xxx 형식)
  final Set<String> _deletingMemberIds = {};

  List<User> get members => List.unmodifiable(_members);
  List<PendingMember> get pendingMembers => List.unmodifiable(_pendingMembers);
  Map<String, String> get membershipDisplayNamesByUserId =>
      Map.unmodifiable(_membershipDisplayNamesByUserId);
  bool get isLoading => _isLoading;
  String? get error => _error;
  Set<String> get deletingMemberIds => Set.unmodifiable(_deletingMemberIds);

  /// 멤버 삭제 시작
  void startDeletingMember(String memberId) {
    _deletingMemberIds.add(memberId);
    notifyListeners();
  }

  /// 멤버 삭제 완료
  void finishDeletingMember(String memberId) {
    _deletingMemberIds.remove(memberId);
    notifyListeners();
  }

  /// 멤버가 삭제 중인지 확인
  bool isDeletingMember(String memberId) {
    return _deletingMemberIds.contains(memberId);
  }

  /// 멤버 삭제 (플레이스에서 제거)
  ///
  /// - 서버(Cloud Function)에서 placeMembership 삭제 + 해당 place의 enrollments 전부 삭제 + (있으면) pendingMembers 정리
  /// - UI는 deletingMemberIds로 카드에 "삭제중" 오버레이를 표시할 수 있음
  Future<void> removeMemberFromPlace({
    required String placeId,
    required String userId,
    required String phoneNumber, // pendingMembers 정리용
    String? adminUserId, // (옵션) 관리자 userId
  }) async {
    startDeletingMember(userId);
    try {
      final normalizedPhone = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');

      final callable = FirebaseFunctions.instance.httpsCallable(
        'removeMemberFromPlace',
      );
      await callable.call({
        'placeId': placeId,
        'userId': userId,
        'phoneNumber': normalizedPhone,
        if (adminUserId != null) 'adminUserId': adminUserId,
      });
    } finally {
      finishDeletingMember(userId);
    }
  }

  /// 등록 직후 등: 첫 emit이 이전 상태(0명)일 수 있으므로, 첫 emit 후 이 시간만큼 대기해
  /// Firestore 반영된 두 번째 emit이 올 때까지 기다린 뒤 완료합니다.
  static const Duration _loadMembersStabilizeDelay = Duration(milliseconds: 550);

  /// 플레이스 멤버 목록 로드 (placeMemberships 기반 + pendingMembers)
  /// 수강 취소해도 플레이스 소속이면 멤버 목록에 유지됨.
  /// 반환된 Future는 양쪽 스트림에서 최소 1회 emit된 뒤, 잠시 대기 후 완료됩니다.
  Future<void> loadMembers(String placeId, {bool forceRefreshUsers = false}) async {
    if (kDebugMode) {
      debugPrint('[MemberProvider] loadMembers start placeId=$placeId');
    }
    // 기존 구독이 있으면 취소
    await _memberSubscription?.cancel();
    await _pendingMemberSubscription?.cancel();
    await _membershipDisplayNameSubscription?.cancel();
    _memberSubscription = null;
    _pendingMemberSubscription = null;
    _membershipDisplayNameSubscription = null;

    _isLoading = true;
    _error = null;
    notifyListeners();

    final completer = Completer<void>();
    var membersEmitted = false;
    var pendingEmitted = false;
    var membershipNamesEmitted = false;
    var delayScheduled = false;
    void maybeComplete() {
      if (membersEmitted &&
          pendingEmitted &&
          membershipNamesEmitted &&
          !completer.isCompleted &&
          !delayScheduled) {
        delayScheduled = true;
        // 첫 emit은 등록 직후엔 이전 상태(0명)일 수 있음. 잠시 대기해 두 번째 emit 반영 후 완료.
        Future.delayed(_loadMembersStabilizeDelay, () {
          if (!completer.isCompleted) completer.complete();
        });
      }
    }

    try {
      // placeMemberships 기반으로 멤버 조회 (수강 취소해도 플레이스 소속이면 목록에 유지)
      _memberSubscription = _memberService
          .watchPlaceMemberUserIds(placeId)
          .asyncMap((userIds) async {
            if (kDebugMode) {
              debugPrint(
                '[MemberProvider] placeMemberships updated placeId=$placeId userIds count=${userIds.length}',
              );
            }

            if (userIds.isEmpty) {
              return <User>[];
            }

            // ✅ 이름 등 최신 정보 보장을 위해 필요 시 강제 재조회
            final userIdsToFetch =
                forceRefreshUsers
                    ? userIds
                    : userIds.where((id) => !_userCache.containsKey(id)).toList();

            // 배치 조회
            if (userIdsToFetch.isNotEmpty) {
              try {
                final fetchedUsers = await _userService.getUsersByIds(
                  userIdsToFetch,
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

            // 캐시에서 User 정보 가져오기 (placeMemberships에 있는 userId만)
            final users =
                userIds.map((id) => _userCache[id]).whereType<User>().toList();

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
              membersEmitted = true;
              maybeComplete();
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
              membersEmitted = true;
              maybeComplete();
              if (kDebugMode) {
                debugPrint(
                  '[MemberProvider] placeMemberships error placeId=$placeId error=$_error',
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
              pendingEmitted = true;
              maybeComplete();
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
              pendingEmitted = true;
              maybeComplete();
              if (kDebugMode) {
                debugPrint(
                  '[MemberProvider] pendingMembers error placeId=$placeId error=$error',
                );
              }
            },
          );

      // placeMemberships.displayName Stream 구독 (관리자 지정 표시 이름)
      _membershipDisplayNameSubscription = _memberService
          .watchPlaceMembershipDisplayNamesByPlace(placeId)
          .listen(
            (displayNames) {
              _membershipDisplayNamesByUserId = displayNames;
              membershipNamesEmitted = true;
              maybeComplete();
              notifyListeners();
            },
            onError: (error) {
              _membershipDisplayNamesByUserId = {};
              membershipNamesEmitted = true;
              maybeComplete();
              if (kDebugMode) {
                debugPrint(
                  '[MemberProvider] membership displayName error placeId=$placeId error=$error',
                );
              }
            },
          );

      await completer.future;
    } catch (e) {
      _error = e.toString();
      _members = [];
      _pendingMembers = [];
      _membershipDisplayNamesByUserId = {};
      _isLoading = false;
      if (!completer.isCompleted) completer.complete();
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
        final userIds =
            courseMembers
                .map((cm) => cm.userId)
                .where((id) => id.isNotEmpty)
                .toSet()
                .toList();

        // 캐시에 없는 userId만 조회
        final missingUserIds =
            userIds.where((id) => !_userCache.containsKey(id)).toList();

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
        final users =
            userIds.map((id) => _userCache[id]).whereType<User>().toList();

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
    await _membershipDisplayNameSubscription?.cancel();
    _memberSubscription = null;
    _pendingMemberSubscription = null;
    _membershipDisplayNameSubscription = null;
    _members = [];
    _pendingMembers = [];
    _membershipDisplayNamesByUserId = {};
    _isLoading = false;
    _error = null;
    // 캐시도 초기화
    _userCache.clear();
    _courseMembersCache.clear();
    notifyListeners();
  }

  // userId -> User 캐시 (전역, 여러 코스에서 공유)
  final Map<String, User> _userCache = {};

  /// 코스별 멤버 조회 (enrollments + pendingMembers는 호출처에서 합침)
  ///
  /// [placeId]가 있으면 해당 플레이스의 enrollment만 조회합니다. 코스별 탭/코스 상세에서는 반드시 전달 권장.
  Stream<List<User>> watchCourseMembers(String courseId, {String? placeId}) {
    final cacheKey = placeId != null ? '${placeId}_$courseId' : courseId;
    if (_courseMemberStreamCache.containsKey(cacheKey)) {
      return _courseMemberStreamCache[cacheKey]!;
    }

    final enrollmentService = EnrollmentService();
    final stream = enrollmentService
        .watchCourseMembers(courseId: courseId, placeId: placeId)
        .asyncMap((courseMembers) async {
      if (courseMembers.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            '[MemberProvider] watchCourseMembers courseId=$courseId placeId=$placeId '
            'enrollmentDocs=0 -> users=0',
          );
        }
        _courseMembersCache[cacheKey] = [];
        return <User>[];
      }

      final userIds = courseMembers
          .map((cm) => cm.userId)
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      final missingUserIds =
          userIds.where((id) => !_userCache.containsKey(id)).toList();
      if (missingUserIds.isNotEmpty) {
        try {
          final fetchedUsers = await _userService.getUsersByIds(missingUserIds);
          for (final user in fetchedUsers) {
            _userCache[user.userId] = user;
          }
        } catch (e, stackTrace) {
          if (kDebugMode) {
            debugPrint('[MemberProvider] Batch user fetch error: $e');
            debugPrint('[MemberProvider] Stack trace: $stackTrace');
          }
        }
      }

      final users =
          userIds.map((id) => _userCache[id]).whereType<User>().toList();
      if (kDebugMode) {
        debugPrint(
          '[MemberProvider] watchCourseMembers courseId=$courseId placeId=$placeId '
          'enrollmentDocs=${courseMembers.length} userIds=${userIds.length} -> users=${users.length}',
        );
      }
      _courseMembersCache[cacheKey] = users;
      return users;
    }).asBroadcastStream();

    _courseMemberStreamCache[cacheKey] = stream;
    return stream;
  }

  /// 코스별 멤버 가져오기 (캐시된 값). watchCourseMembers와 동일한 cacheKey 사용.
  List<User> getCourseMembers(String courseId, {String? placeId}) {
    final cacheKey = placeId != null ? '${placeId}_$courseId' : courseId;
    return _courseMembersCache[cacheKey] ?? [];
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
    _courseMemberStreamCache.clear(); // Stream 캐시도 정리
    _userCache.clear(); // User 캐시도 정리
    super.dispose();
  }
}
