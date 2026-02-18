import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/member_view.dart';
import '../models/course_enrollment.dart';
import '../models/pending_member.dart';
import '../models/place_member.dart';
import '../services/member_service.dart';
import '../utils/local_storage_util.dart';

/// 멤버 상태 Provider (UI용 MemberView 기준, 단일 소스)
///
/// - 슬라이딩 윈도우: 화면에 보이는 구간 30명 단위만 실시간 구독 (500ms 디바운스)
/// - 스크롤 시 구독 구간 이동, 핸드쉐이크 최소화
class MemberProvider with ChangeNotifier {
  final MemberService _service = MemberService();

  static const int _segmentSize = MemberService.segmentSize;
  static const int _debounceMs = 500;

  String? _placeId;
  List<PlaceMember> _streamedPlaceMembers = [];
  DocumentSnapshot? _streamedSegmentLastDoc;
  List<PlaceMember> _cachedPlaceMembersBefore = [];
  List<PlaceMember> _loadedPlaceMembersAfter = [];
  DocumentSnapshot? _lastLoadedAfterDoc;
  List<PendingMember> _pendingMembers = [];
  final Map<int, DocumentSnapshot> _segmentBoundaryDocs = {};
  int _currentSegmentIndex = 0;
  Timer? _visibleRangeDebounce;
  bool _hasMoreMembers = true;
  bool _isLoadingMore = false;
  List<CourseEnrollment> _enrollments = [];
  String? _selectedCourseId;
  bool _showPending = true;
  bool _isLoading = true;
  String? _error;
  final Set<String> _deletingMemberIds = {};
  final Set<String> _processingMemberIds = {};
  /// 코스별 "부매니저 추가 중" userId 목록 (로컬에서 카드 먼저 보여주고 로딩)
  final Map<String, Set<String>> _pendingSubManagerAdds = {};

  StreamSubscription<(List<PlaceMember>, DocumentSnapshot?)>?
  _placeMembersSegmentSub;
  StreamSubscription<List<PendingMember>>? _pendingSub;
  StreamSubscription<List<CourseEnrollment>>? _enrollmentsSub;
  Set<String> _lastEnrollmentUserIds = {};

  /// 부매니저 모드: 전체 멤버 스트림 미구독, 코스별 30명 롤링 윈도우
  bool _isSubManagerForPlace = false;
  List<String> _courseOnlyUserIds = [];
  int _courseOnlySegmentIndex = 0;
  List<PlaceMember> _courseOnlyCachedBefore = [];
  List<PlaceMember> _courseOnlyStreamed = [];
  List<PlaceMember> _courseOnlyLoadedAfter = [];
  StreamSubscription<List<PlaceMember>>? _courseOnlyMembersSub;

  // 멤버관리 화면 UI 상태 (Provider 일괄 관리)
  String _searchQuery = '';
  int _selectedTab = 0; // 0: 전체, 1: 코스별
  int _sortBy = 0; // 전체: 0=기본, 1=남은기간순, 2=남은횟수순
  int _courseSortBy = 0; // 코스별: 0=횟수순, 1=기간순
  bool _courseSortAscending = true; // 코스별 정렬 방향: true=오름차순, false=내림차순
  final Set<String> _selectedCourseIds = {};
  bool _isCourseSelectorExpanded = true;
  Map<String, String>? _courseIdToNameForSearch;

  String? get placeId => _placeId;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMoreMembers {
    if (_isSubManagerForPlace) {
      final total =
          _courseOnlyCachedBefore.length +
          _courseOnlyStreamed.length +
          _courseOnlyLoadedAfter.length;
      return total < _courseOnlyUserIds.length;
    }
    return _hasMoreMembers;
  }
  String? get error => _error;
  String? get selectedCourseId => _selectedCourseId;
  bool get showPending => _showPending;
  Set<String> get deletingMemberIds => Set.unmodifiable(_deletingMemberIds);
  Set<String> get processingMemberIds => Set.unmodifiable(_processingMemberIds);

  String get searchQuery => _searchQuery;
  int get selectedTab => _selectedTab;
  int get sortBy => _sortBy;
  int get courseSortBy => _courseSortBy;
  bool get courseSortAscending => _courseSortAscending;
  Set<String> get selectedCourseIds => Set.unmodifiable(_selectedCourseIds);
  bool get isCourseSelectorExpanded => _isCourseSelectorExpanded;

  List<MemberView> _placeMembersToViews(
    List<PlaceMember> members,
    Map<String, List<String>> byUser,
  ) {
    return members.map((m) {
      final adminName = (m.adminDisplayName ?? '').trim();
      return MemberView(
        userId: m.userId,
        adminDisplayName: adminName.isEmpty ? '이름 없음' : adminName,
        phoneNumber: m.phoneNumber ?? '',
        role: m.role,
        manageableCourseIds: m.manageableCourseIds,
        enrolledCourseIds: byUser[m.userId] ?? [],
        isPending: false,
      );
    }).toList();
  }

  List<MemberView> _pendingToViews() {
    final list = _pendingMembers;
    return list.map((p) {
      final pendingName = (p.adminDisplayName ?? '').trim();
      return MemberView(
        userId: 'pending_${p.id}',
        adminDisplayName: pendingName.isEmpty ? '이름 없음' : pendingName,
        phoneNumber: p.phoneNumber,
        role: p.role,
        manageableCourseIds: p.effectiveCourseIds,
        enrolledCourseIds: const [],
        isPending: true,
      );
    }).toList();
  }

  bool get isSubManagerForPlace => _isSubManagerForPlace;

  /// 전체 멤버: 캐시(이전 세그먼트) + 스트림(현재 세그먼트) + 로드(이후) + pending.
  /// 부매니저 모드: 코스별 30명 롤링 윈도우(cached+streamed+loaded) + 해당 코스 pending.
  List<MemberView> get allMembers {
    if (_isSubManagerForPlace) {
      final byUser = <String, List<String>>{};
      for (final e in _enrollments) {
        byUser.putIfAbsent(e.userId, () => []).add(e.courseId);
      }
      final placeViews = _placeMembersToViews(
        [
          ..._courseOnlyCachedBefore,
          ..._courseOnlyStreamed,
          ..._courseOnlyLoadedAfter,
        ],
        byUser,
      );
      final courseIds = _selectedCourseIds.toList();
      final pendingForCourse = _pendingToViews().where(
        (v) => courseIds.isEmpty ||
            v.manageableCourseIds.any((id) => courseIds.contains(id)),
      ).toList();
      final combined = [...placeViews, ...pendingForCourse];
      return combined
          .map((v) => v.copyWith(enrolledCourseIds: byUser[v.userId] ?? []))
          .toList();
    }
    final byUser = <String, List<String>>{};
    for (final e in _enrollments) {
      byUser.putIfAbsent(e.userId, () => []).add(e.courseId);
    }
    final placeViews = _placeMembersToViews([
      ..._cachedPlaceMembersBefore,
      ..._streamedPlaceMembers,
      ..._loadedPlaceMembersAfter,
    ], byUser);
    final pendingViews = _pendingToViews();
    final combined = [...placeViews, ...pendingViews];
    return combined
        .map((v) => v.copyWith(enrolledCourseIds: byUser[v.userId] ?? []))
        .toList();
  }

  List<CourseEnrollment> get enrollments => List.unmodifiable(_enrollments);

  /// 코스별: selectedCourseId에 해당 enrollment가 있는 멤버만, enrollment 첨부. pending 제외.
  /// 전체: showPending false면 pending 제외.
  List<MemberView> get filteredMembers {
    final withEnrolled = allMembers;
    if (_selectedCourseId != null && _selectedCourseId!.trim().isNotEmpty) {
      final courseId = _selectedCourseId!.trim();
      final byUser = <String, CourseEnrollment>{};
      for (final e in _enrollments) {
        if (e.courseId == courseId) byUser[e.userId] = e;
      }
      final list = <MemberView>[];
      for (final v in withEnrolled) {
        if (v.isPending) continue;
        final enrollment = byUser[v.userId];
        if (enrollment == null) continue;
        list.add(v.copyWith(enrollment: enrollment));
      }
      return list;
    }
    if (!_showPending) {
      return withEnrolled.where((v) => !v.isPending).toList();
    }
    return withEnrolled;
  }

  MemberView? getMemberView(String userId) {
    try {
      return allMembers.firstWhere((v) => v.userId == userId);
    } catch (_) {
      return null;
    }
  }

  /// 특정 코스에 등록된 멤버만 (enrollment 첨부). pending 제외.
  List<MemberView> getMembersForCourse(String courseId) {
    final byUser = <String, CourseEnrollment>{};
    for (final e in _enrollments) {
      if (e.courseId == courseId) byUser[e.userId] = e;
    }
    final list = <MemberView>[];
    for (final v in allMembers) {
      if (v.isPending) continue;
      final enrollment = byUser[v.userId];
      if (enrollment == null) continue;
      list.add(v.copyWith(enrollment: enrollment));
    }
    return list;
  }

  /// 전체 탭용: 검색·정렬 적용된 멤버 목록
  List<MemberView> get listForAllTab {
    var list = _filteredBySearch(allMembers);
    list = _sortAllMembers(list);
    return list;
  }

  /// 코스별 탭용: 선택된 코스들의 멤버 (검색·정렬 적용).
  /// 부매니저 모드: 30명 롤링 윈도우로 로드한 allMembers 기준.
  List<MemberView> get listForCourseTab {
    if (_selectedCourseIds.isEmpty) return [];
    if (_isSubManagerForPlace) {
      var list = allMembers;
      if (_selectedCourseIds.length == 1) {
        final courseId = _selectedCourseIds.first;
        final byUser = <String, CourseEnrollment>{};
        for (final e in _enrollments) {
          if (e.courseId == courseId) byUser[e.userId] = e;
        }
        list = list.map((v) => v.copyWith(enrollment: byUser[v.userId])).toList();
      }
      list = _filteredBySearch(list);
      list = _sortCourseMembers(list);
      return list;
    }
    if (_selectedCourseIds.length == 1) {
      final courseId = _selectedCourseIds.first;
      var list = getMembersForCourse(courseId);
      final pending =
          allMembers
              .where(
                (v) => v.isPending && v.manageableCourseIds.contains(courseId),
              )
              .toList();
      list = [...list, ...pending];
      list = _filteredBySearch(list);
      list = _sortCourseMembers(list);
      return list;
    }
    final filtered =
        allMembers.where((v) {
          final hasCourse =
              v.isPending
                  ? v.manageableCourseIds.any(
                    (id) => _selectedCourseIds.contains(id),
                  )
                  : v.enrolledCourseIds.any(
                    (id) => _selectedCourseIds.contains(id),
                  );
          return hasCourse;
        }).toList();
    var list = _filteredBySearch(filtered);
    list.sort((a, b) => a.adminDisplayName.compareTo(b.adminDisplayName));
    return list;
  }

  /// 과목 키워드 검색용 코스명 맵 설정 (CourseProvider.courses 기준)
  void setCourseNamesForSearch(Map<String, String> map) {
    if (mapEquals(_courseIdToNameForSearch, map)) return;
    _courseIdToNameForSearch = map.isEmpty ? null : Map.unmodifiable(map);
    notifyListeners();
  }

  static bool _isCountKeyword(String s) => RegExp(r'^\d{1,4}회?$').hasMatch(s);

  /// 이름, 전화번호, 과목 키워드, '대기중'/'가입 대기중', N회(남은 횟수)로 검색. 공백 구분 시 모든 키워드 일치.
  List<MemberView> _filteredBySearch(List<MemberView> views) {
    final q = _searchQuery.trim();
    if (q.isEmpty) return views;
    const pendingLabel = '가입 대기중';
    final lower = q.toLowerCase();
    final digitsOnly = q.replaceAll(RegExp(r'[^\d]'), '');
    final keywords =
        lower.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    return views.where((v) {
      final name = (v.adminDisplayName).trim().toLowerCase();
      final phone = v.phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
      // N회 패턴은 전화번호 매칭 제외 (예: "5회"의 "5"가 010-5555-xxx 매칭 방지)
      final excludePhoneForFull = _selectedTab == 1 && _isCountKeyword(lower);
      final nameMatch = name.contains(lower);
      final phoneMatch =
          !excludePhoneForFull &&
          digitsOnly.isNotEmpty &&
          phone.contains(digitsOnly);
      // '대기중' / '가입 대기중' 키워드: '대', '대기', '가입', '가입 대기중' 등 매칭
      final pendingMatch =
          v.isPending &&
          ('대기중'.contains(lower) ||
              lower.contains('대기중') ||
              pendingLabel.contains(lower) ||
              lower.contains(pendingLabel));
      // 과목 키워드: 등록/관리 코스명에 포함되면 매칭
      bool courseMatch = false;
      if (_courseIdToNameForSearch != null &&
          _courseIdToNameForSearch!.isNotEmpty) {
        final memberCourseIds = {
          ...v.enrolledCourseIds,
          ...v.manageableCourseIds,
        };
        for (final cid in memberCourseIds) {
          final cname = _courseIdToNameForSearch![cid];
          if (cname != null && cname.toLowerCase().contains(lower)) {
            courseMatch = true;
            break;
          }
        }
      }
      // N회(남은 횟수) 매칭: 코스별 탭에서만 "3회", "2", "10회" 등
      final countMatch =
          _selectedTab == 1 &&
          _matchRemainingCount(lower, v.userId, _selectedCourseIds);
      final matchFull =
          nameMatch || phoneMatch || pendingMatch || courseMatch || countMatch;
      if (keywords.isEmpty) return matchFull;
      final matchKeywords = keywords.every((kw) {
        final isCountKw = _selectedTab == 1 && _isCountKeyword(kw);
        final kwDigits = kw.replaceAll(RegExp(r'[^\d]'), '');
        final kn = !isCountKw && name.contains(kw);
        final kp =
            !isCountKw && kwDigits.isNotEmpty && phone.contains(kwDigits);
        final kPending =
            v.isPending &&
            ('대기중'.contains(kw) ||
                kw.contains('대기중') ||
                pendingLabel.contains(kw) ||
                kw.contains(pendingLabel));
        bool kCourse = false;
        if (_courseIdToNameForSearch != null &&
            _courseIdToNameForSearch!.isNotEmpty) {
          final memberCourseIds = {
            ...v.enrolledCourseIds,
            ...v.manageableCourseIds,
          };
          for (final cid in memberCourseIds) {
            final cname = _courseIdToNameForSearch![cid];
            if (cname != null && cname.toLowerCase().contains(kw)) {
              kCourse = true;
              break;
            }
          }
        }
        final kCount =
            _selectedTab == 1 &&
            _matchRemainingCount(kw, v.userId, _selectedCourseIds);
        return kn || kp || kPending || kCourse || kCount;
      });
      return matchFull || matchKeywords;
    }).toList();
  }

  /// "3회", "2", "10회" 등 남은 횟수 키워드 매칭 (코스별: 선택 코스만)
  bool _matchRemainingCount(
    String keyword,
    String userId,
    Set<String> selectedCourseIds,
  ) {
    if (!RegExp(r'^\d{1,4}회?$').hasMatch(keyword)) return false;
    final count = int.tryParse(keyword.replaceAll(RegExp(r'[^\d]'), ''));
    if (count == null || count < 0) return false;
    var memberEnrollments =
        _enrollments.where((e) => e.userId == userId).toList();
    if (selectedCourseIds.isNotEmpty) {
      memberEnrollments =
          memberEnrollments
              .where((e) => selectedCourseIds.contains(e.courseId))
              .toList();
    }
    return memberEnrollments.any((e) => e.remainingReservations == count);
  }

  List<MemberView> _sortAllMembers(List<MemberView> list) {
    if (_sortBy == 0) return list;
    final byUser = <String, List<CourseEnrollment>>{};
    for (final e in _enrollments) {
      byUser.putIfAbsent(e.userId, () => []).add(e);
    }
    list.sort((a, b) {
      if (a.isPending && b.isPending) return 0;
      if (a.isPending) return 1;
      if (b.isPending) return -1;
      final aEnrollments = byUser[a.userId] ?? [];
      final bEnrollments = byUser[b.userId] ?? [];
      if (aEnrollments.isEmpty && bEnrollments.isEmpty) return 0;
      if (aEnrollments.isEmpty) return 1;
      if (bEnrollments.isEmpty) return -1;
      if (_sortBy == 1) {
        final aMin = aEnrollments
            .map((e) => e.validUntil)
            .reduce((a, b) => a.isBefore(b) ? a : b);
        final bMin = bEnrollments
            .map((e) => e.validUntil)
            .reduce((a, b) => a.isBefore(b) ? a : b);
        return aMin.compareTo(bMin);
      }
      // _sortBy == 2: 남은횟수순
      final aMin = aEnrollments
          .map((e) => e.remainingReservations)
          .reduce((a, b) => a < b ? a : b);
      final bMin = bEnrollments
          .map((e) => e.remainingReservations)
          .reduce((a, b) => a < b ? a : b);
      return aMin.compareTo(bMin);
    });
    return list;
  }

  /// 코스별 정렬 (오름차순/내림차순 반영)
  List<MemberView> _sortCourseMembers(List<MemberView> list) {
    list = List.from(list);
    final order = _courseSortAscending ? 1 : -1;
    list.sort((a, b) {
      if (a.isPending && b.isPending) return 0;
      if (a.isPending) return 1;
      if (b.isPending) return -1;
      if (_courseSortBy == 0) {
        final ar = a.enrollment?.remainingReservations ?? 0;
        final br = b.enrollment?.remainingReservations ?? 0;
        return ar.compareTo(br) * order;
      }
      final av = a.enrollment?.validUntil ?? DateTime(2099);
      final bv = b.enrollment?.validUntil ?? DateTime(2099);
      return av.compareTo(bv) * order;
    });
    return list;
  }

  void setSearchQuery(String value) {
    if (_searchQuery == value) return;
    _searchQuery = value;
    notifyListeners();
  }

  void setSelectedTab(int index) {
    if (_selectedTab == index) return;
    _selectedTab = index;
    notifyListeners();
  }

  void setSortBy(int value) {
    if (_sortBy == value) return;
    _sortBy = value;
    notifyListeners();
  }

  void setCourseSortBy(int value) {
    if (_courseSortBy == value) return;
    _courseSortBy = value;
    notifyListeners();
  }

  void setCourseSortAscending(bool ascending) {
    if (_courseSortAscending == ascending) return;
    _courseSortAscending = ascending;
    notifyListeners();
  }

  void toggleCourseSelection(String courseId) {
    if (_selectedCourseIds.contains(courseId)) {
      _selectedCourseIds.remove(courseId);
    } else {
      _selectedCourseIds.add(courseId);
    }
    notifyListeners();
  }

  /// 코스별 탭: 단일 코스만 선택하고 SharedPreferences에 저장
  void selectSingleCourseForCourseTab(String courseId, {bool save = true}) {
    if (_selectedCourseIds.length == 1 &&
        _selectedCourseIds.contains(courseId)) {
      return;
    }
    _selectedCourseIds.clear();
    _selectedCourseIds.add(courseId);
    if (_isSubManagerForPlace) _updateCourseOnlyMembers();
    notifyListeners();
    if (save && _placeId != null && _placeId!.isNotEmpty) {
      StorageService()
          .saveLastSelectedCourseId(
            _placeId!,
            courseId,
            scope: StorageService.scopeAdminMemberCourseTab,
          )
          .ignore();
    }
  }

  /// 코스별 탭 진입 시: 저장된 코스 복원, 없으면 첫 번째 코스 선택
  Future<void> restoreCourseSelectionForCourseTab(
    String placeId,
    List<String> validCourseIds,
  ) async {
    if (validCourseIds.isEmpty) return;
    final storage = StorageService();
    final savedId = await storage.getLastSelectedCourseId(
      placeId,
      scope: StorageService.scopeAdminMemberCourseTab,
    );
    final idToSelect =
        (savedId != null && validCourseIds.contains(savedId))
            ? savedId
            : validCourseIds.first;
    _selectedCourseIds.clear();
    _selectedCourseIds.add(idToSelect);
    notifyListeners();
  }

  void setCourseSelectorExpanded(bool value) {
    if (_isCourseSelectorExpanded == value) return;
    _isCourseSelectorExpanded = value;
    notifyListeners();
  }

  /// 부매니저 모드: 선택 코스(들)의 userId 목록 갱신 후 0번 세그먼트 구독 (30명 롤링 윈도우)
  void _updateCourseOnlyMembers() {
    final placeId = _placeId;
    if (placeId == null ||
        placeId.isEmpty ||
        _selectedCourseIds.isEmpty ||
        !_isSubManagerForPlace) {
      _courseOnlyUserIds = [];
      _courseOnlySegmentIndex = 0;
      _courseOnlyCachedBefore = [];
      _courseOnlyStreamed = [];
      _courseOnlyLoadedAfter = [];
      _courseOnlyMembersSub?.cancel();
      _courseOnlyMembersSub = null;
      notifyListeners();
      return;
    }
    final courseIds = _selectedCourseIds.toList();
    final userIds = <String>{};
    for (final e in _enrollments) {
      if (courseIds.contains(e.courseId)) userIds.add(e.userId);
    }
    _courseOnlyUserIds = userIds.toList()..sort();
    _courseOnlySegmentIndex = 0;
    _courseOnlyCachedBefore = [];
    _courseOnlyStreamed = [];
    _courseOnlyLoadedAfter = [];
    _courseOnlyMembersSub?.cancel();
    _courseOnlyMembersSub = null;
    _subscribeCourseOnlySegment();
    notifyListeners();
  }

  /// 부매니저: 현재 세그먼트(30명) 구독
  void _subscribeCourseOnlySegment() {
    final placeId = _placeId;
    if (placeId == null ||
        placeId.isEmpty ||
        _courseOnlyUserIds.isEmpty ||
        !_isSubManagerForPlace) return;
    final start = _courseOnlySegmentIndex * _segmentSize;
    if (start >= _courseOnlyUserIds.length) return;
    final segmentUserIds =
        _courseOnlyUserIds.skip(start).take(_segmentSize).toList();
    _courseOnlyMembersSub = _service
        .watchPlaceMembersByUserIds(placeId, segmentUserIds)
        .listen(
          (list) {
            _courseOnlyStreamed = list;
            notifyListeners();
          },
          onError: (e) {
            debugPrint('[MemberProvider] courseOnly stream error: $e');
          },
        );
  }

  /// 부매니저: 스크롤에 따라 현재 세그먼트 전환 (30명 롤링 윈도우)
  void _switchCourseOnlySegmentTo(int newSegmentIndex) {
    final placeId = _placeId;
    if (placeId == null || placeId.isEmpty || !_isSubManagerForPlace) return;
    if (newSegmentIndex < 0 ||
        newSegmentIndex * _segmentSize >= _courseOnlyUserIds.length) return;
    if (newSegmentIndex == _courseOnlySegmentIndex) return;

    _courseOnlyMembersSub?.cancel();
    _courseOnlyMembersSub = null;

    if (newSegmentIndex > _courseOnlySegmentIndex) {
      _courseOnlyCachedBefore = [
        ..._courseOnlyCachedBefore,
        ..._courseOnlyStreamed,
      ];
      _courseOnlyStreamed = [];
    } else {
      final dropCount = (_courseOnlySegmentIndex - newSegmentIndex) * _segmentSize;
      if (_courseOnlyCachedBefore.length >= dropCount) {
        _courseOnlyCachedBefore = _courseOnlyCachedBefore.sublist(
          0,
          _courseOnlyCachedBefore.length - dropCount,
        );
      } else {
        _courseOnlyCachedBefore = [];
      }
      _courseOnlyStreamed = [];
    }

    _courseOnlySegmentIndex = newSegmentIndex;
    _subscribeCourseOnlySegment();
    notifyListeners();
  }

  /// 현재 로드된 멤버 기준 enrollments 구독. streamed(현재 화면) 우선, 최대 30명.
  void _refreshEnrollmentsSubscription() {
    final placeId = _placeId;
    if (placeId == null || placeId.isEmpty) return;

    if (_isSubManagerForPlace) return;

    // 현재 세그먼트(streamed) 우선 → 상단 30명에 반드시 enrollment 포함
    final userIds = <String>[];
    for (final m in _streamedPlaceMembers) {
      if (m.userId.isNotEmpty && !userIds.contains(m.userId)) {
        userIds.add(m.userId);
      }
    }
    for (final m in _cachedPlaceMembersBefore) {
      if (userIds.length >= 30) break;
      if (m.userId.isNotEmpty && !userIds.contains(m.userId)) {
        userIds.add(m.userId);
      }
    }
    for (final m in _loadedPlaceMembersAfter) {
      if (userIds.length >= 30) break;
      if (m.userId.isNotEmpty && !userIds.contains(m.userId)) {
        userIds.add(m.userId);
      }
    }

    final userIdSet = userIds.toSet();
    if (setEquals(_lastEnrollmentUserIds, userIdSet)) return;
    _lastEnrollmentUserIds = userIdSet;

    _enrollmentsSub?.cancel();
    _enrollmentsSub = null;

    if (userIds.isEmpty) {
      _enrollments = [];
      notifyListeners();
      return;
    }

    _enrollmentsSub = _service
        .watchEnrollmentsForUserIds(placeId, userIds)
        .listen(
          (list) {
            _enrollments = list;
            notifyListeners();
          },
          onError: (e) {
            debugPrint('[MemberProvider] enrollments error: $e');
          },
        );
  }

  /// 화면에 보이는 첫 인덱스 알림. 500ms 디바운스 후 세그먼트 구독 전환.
  void setVisibleRange(int firstVisibleIndex) {
    if (_placeId == null || _placeId!.isEmpty) return;

    _visibleRangeDebounce?.cancel();
    _visibleRangeDebounce = Timer(Duration(milliseconds: _debounceMs), () {
      _visibleRangeDebounce = null;
      if (_isSubManagerForPlace) {
        final segmentIndex = (firstVisibleIndex / _segmentSize).floor();
        if (segmentIndex != _courseOnlySegmentIndex &&
            segmentIndex * _segmentSize < _courseOnlyUserIds.length) {
          _switchCourseOnlySegmentTo(segmentIndex);
        }
        return;
      }
      final segmentIndex = (firstVisibleIndex / _segmentSize).floor();
      if (segmentIndex != _currentSegmentIndex) {
        _switchSegmentTo(segmentIndex);
      }
    });
  }

  void _switchSegmentTo(int newSegmentIndex) {
    final placeId = _placeId;
    if (placeId == null || placeId.isEmpty) return;

    _placeMembersSegmentSub?.cancel();
    _placeMembersSegmentSub = null;

    if (newSegmentIndex < _currentSegmentIndex) {
      final needLen = (newSegmentIndex + 1) * _segmentSize;
      if (_cachedPlaceMembersBefore.length >= needLen) {
        _streamedPlaceMembers = _cachedPlaceMembersBefore.sublist(
          newSegmentIndex * _segmentSize,
          needLen,
        );
        _cachedPlaceMembersBefore = _cachedPlaceMembersBefore.sublist(
          0,
          newSegmentIndex * _segmentSize,
        );
        _streamedSegmentLastDoc = _segmentBoundaryDocs[newSegmentIndex];
      } else {
        _streamedPlaceMembers = [];
        _streamedSegmentLastDoc = null;
      }
    } else if (newSegmentIndex > _currentSegmentIndex) {
      _cachedPlaceMembersBefore = [
        ..._cachedPlaceMembersBefore,
        ..._streamedPlaceMembers,
      ];
      if (_streamedSegmentLastDoc != null) {
        _segmentBoundaryDocs[_currentSegmentIndex] = _streamedSegmentLastDoc!;
      }
      if (_loadedPlaceMembersAfter.length >= _segmentSize) {
        _streamedPlaceMembers = _loadedPlaceMembersAfter.sublist(
          0,
          _segmentSize,
        );
        _loadedPlaceMembersAfter = _loadedPlaceMembersAfter.sublist(
          _segmentSize,
        );
      } else {
        _streamedPlaceMembers = [];
      }
      _streamedSegmentLastDoc = null;
    }

    _currentSegmentIndex = newSegmentIndex;
    final startAfter =
        newSegmentIndex > 0 ? _segmentBoundaryDocs[newSegmentIndex - 1] : null;

    _placeMembersSegmentSub = _service
        .watchPlaceMembersSegment(placeId, startAfter: startAfter)
        .listen(
          (pair) {
            _streamedPlaceMembers = pair.$1;
            _streamedSegmentLastDoc = pair.$2;
            if (pair.$2 != null) {
              _segmentBoundaryDocs[_currentSegmentIndex] = pair.$2!;
            }
            _isLoading = false;
            _error = null;
            _refreshEnrollmentsSubscription();
            notifyListeners();
          },
          onError: (e) {
            _error = e.toString();
            _isLoading = false;
            notifyListeners();
          },
        );
    _refreshEnrollmentsSubscription();
    notifyListeners();
  }

  /// placeId 설정 시 멤버/등록 구독 시작.
  /// [isSubManagerForPlace] true면 전체 멤버 스트림 미구독, enrollments만 구독 후 코스별로만 로드.
  void setPlaceId(String? placeId, {bool isSubManagerForPlace = false}) {
    if (_placeId == placeId && _isSubManagerForPlace == isSubManagerForPlace) return;
    _placeId = placeId;
    _isSubManagerForPlace = isSubManagerForPlace;
    _placeMembersSegmentSub?.cancel();
    _placeMembersSegmentSub = null;
    _pendingSub?.cancel();
    _pendingSub = null;
    _enrollmentsSub?.cancel();
    _visibleRangeDebounce?.cancel();
    _visibleRangeDebounce = null;
    _streamedPlaceMembers = [];
    _streamedSegmentLastDoc = null;
    _cachedPlaceMembersBefore = [];
    _loadedPlaceMembersAfter = [];
    _lastLoadedAfterDoc = null;
    _pendingMembers = [];
    _lastEnrollmentUserIds = {};
    _segmentBoundaryDocs.clear();
    _currentSegmentIndex = 0;
    _hasMoreMembers = true;
    _courseOnlyUserIds = [];
    _courseOnlySegmentIndex = 0;
    _courseOnlyCachedBefore = [];
    _courseOnlyStreamed = [];
    _courseOnlyLoadedAfter = [];
    _courseOnlyMembersSub?.cancel();
    _courseOnlyMembersSub = null;
    _enrollments = [];
    _isLoading = true;
    _error = null;
    notifyListeners();

    if (placeId == null || placeId.isEmpty) {
      _isLoading = false;
      notifyListeners();
      return;
    }

    _pendingSub = _service
        .watchPendingMembersByPlace(placeId)
        .listen(
          (list) {
            _pendingMembers = list;
            notifyListeners();
            if (_isSubManagerForPlace) _updateCourseOnlyMembers();
          },
          onError: (e) {
            debugPrint('[MemberProvider] pending stream error: $e');
          },
        );

    if (isSubManagerForPlace) {
      _enrollmentsSub = _service
          .watchEnrollmentsByPlace(placeId)
          .listen(
            (list) {
              _enrollments = list;
              _isLoading = false;
              _error = null;
              _updateCourseOnlyMembers();
              notifyListeners();
            },
            onError: (e) {
              _error = e.toString();
              _isLoading = false;
              notifyListeners();
            },
          );
      return;
    }

    _placeMembersSegmentSub = _service
        .watchPlaceMembersSegment(placeId)
        .listen(
          (pair) {
            _streamedPlaceMembers = pair.$1;
            _streamedSegmentLastDoc = pair.$2;
            if (pair.$2 != null) {
              _segmentBoundaryDocs[0] = pair.$2!;
            }
            _isLoading = false;
            _error = null;
            _refreshEnrollmentsSubscription();
            notifyListeners();
          },
          onError: (e) {
            _error = e.toString();
            _isLoading = false;
            notifyListeners();
          },
        );
  }

  void setSelectedCourseId(String? courseId) {
    if (_selectedCourseId == courseId) return;
    _selectedCourseId = courseId;
    notifyListeners();
  }

  void setShowPending(bool value) {
    if (_showPending == value) return;
    _showPending = value;
    notifyListeners();
  }

  void startDeletingMember(String memberId) {
    _deletingMemberIds.add(memberId);
    notifyListeners();
  }

  void finishDeletingMember(String memberId) {
    _deletingMemberIds.remove(memberId);
    notifyListeners();
  }

  bool isDeletingMember(String memberId) =>
      _deletingMemberIds.contains(memberId);

  void startProcessingMember(String memberId) {
    _processingMemberIds.add(memberId);
    notifyListeners();
  }

  void finishProcessingMember(String memberId) {
    _processingMemberIds.remove(memberId);
    notifyListeners();
  }

  bool isProcessingMember(String memberId) =>
      _processingMemberIds.contains(memberId);

  /// 삭제/추가 등 카드에서 로딩 표시할지 여부 (> 자리에 스피너)
  bool isMemberCardLoading(String memberId) =>
      _deletingMemberIds.contains(memberId) ||
      _processingMemberIds.contains(memberId);

  /// 부매니저 추가 시작: 로컬 리스트에 카드 표시 + 로딩
  void startAddingSubManagerForCourse(String courseId, String userId) {
    _pendingSubManagerAdds.putIfAbsent(courseId, () => {}).add(userId);
    _processingMemberIds.add(userId);
    notifyListeners();
  }

  /// 부매니저 추가 완료 (성공/실패 관계없이 호출)
  void finishAddingSubManagerForCourse(String courseId, String userId) {
    _pendingSubManagerAdds[courseId]?.remove(userId);
    if (_pendingSubManagerAdds[courseId]?.isEmpty ?? false) {
      _pendingSubManagerAdds.remove(courseId);
    }
    _processingMemberIds.remove(userId);
    notifyListeners();
  }

  Set<String> getPendingSubManagerUserIds(String courseId) =>
      Set<String>.from(_pendingSubManagerAdds[courseId] ?? const {});

  /// 플레이스에서 멤버 제거 (Cloud Function 호출)
  Future<void> removeMemberFromPlace({
    required String placeId,
    required String userId,
    required String phoneNumber,
    String? adminUserId,
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

  /// 무한 스크롤: 현재 구간 이후 멤버 추가 로드. 부매니저 모드: 다음 30명 세그먼트 로드.
  Future<void> loadMoreMembers() async {
    final placeId = _placeId;
    if (_isSubManagerForPlace) {
      if (placeId == null || placeId.isEmpty || _courseOnlyUserIds.isEmpty) return;
      final alreadyLoaded = _courseOnlyCachedBefore.length +
          _courseOnlyStreamed.length +
          _courseOnlyLoadedAfter.length;
      if (alreadyLoaded >= _courseOnlyUserIds.length) return;
      if (_isLoadingMore) return;
      _isLoadingMore = true;
      notifyListeners();
      try {
        final start = alreadyLoaded;
        final segmentUserIds =
            _courseOnlyUserIds.skip(start).take(_segmentSize).toList();
        final list = await _service.getPlaceMembersByUserIds(placeId!, segmentUserIds);
        _courseOnlyLoadedAfter = [..._courseOnlyLoadedAfter, ...list];
      } finally {
        _isLoadingMore = false;
        notifyListeners();
      }
      return;
    }
    if (placeId == null ||
        placeId.isEmpty ||
        _isLoadingMore ||
        !_hasMoreMembers) {
      return;
    }

    _isLoadingMore = true;
    notifyListeners();

    try {
      final startAfter =
          _loadedPlaceMembersAfter.isEmpty
              ? _streamedSegmentLastDoc ??
                  _segmentBoundaryDocs[_currentSegmentIndex]
              : _lastLoadedAfterDoc;
      final (list, lastDoc) = await _service.getPlaceMembersPage(
        placeId,
        startAfter: startAfter,
      );
      _loadedPlaceMembersAfter = [..._loadedPlaceMembersAfter, ...list];
      _lastLoadedAfterDoc = lastDoc;
      _hasMoreMembers = list.length >= MemberService.pageSize;
      if (list.isEmpty) _hasMoreMembers = false;
      _refreshEnrollmentsSubscription();
    } catch (e) {
      debugPrint('[MemberProvider] loadMoreMembers error: $e');
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }

  void clear() {
    _placeMembersSegmentSub?.cancel();
    _pendingSub?.cancel();
    _enrollmentsSub?.cancel();
    _courseOnlyMembersSub?.cancel();
    _visibleRangeDebounce?.cancel();
    _placeId = null;
    _isSubManagerForPlace = false;
    _courseOnlyUserIds = [];
    _courseOnlySegmentIndex = 0;
    _courseOnlyCachedBefore = [];
    _courseOnlyStreamed = [];
    _courseOnlyLoadedAfter = [];
    _courseOnlyMembersSub = null;
    _streamedPlaceMembers = [];
    _streamedSegmentLastDoc = null;
    _cachedPlaceMembersBefore = [];
    _loadedPlaceMembersAfter = [];
    _lastLoadedAfterDoc = null;
    _currentSegmentIndex = 0;
    _lastEnrollmentUserIds = {};
    _segmentBoundaryDocs.clear();
    _hasMoreMembers = true;
    _enrollments = [];
    _isLoading = false;
    _error = null;
    _deletingMemberIds.clear();
    _searchQuery = '';
    _selectedTab = 0;
    _sortBy = 0;
    _courseSortBy = 0;
    _courseSortAscending = true;
    _selectedCourseIds.clear();
    _isCourseSelectorExpanded = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _placeMembersSegmentSub?.cancel();
    _pendingSub?.cancel();
    _enrollmentsSub?.cancel();
    _courseOnlyMembersSub?.cancel();
    _visibleRangeDebounce?.cancel();
    super.dispose();
  }
}
