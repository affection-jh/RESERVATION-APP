import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/member_view.dart';
import '../models/course_enrollment.dart';
import '../models/pending_member.dart';
import '../models/place_member.dart';
import '../services/member_service.dart';
import '../utils/format_utils.dart';
import '../utils/local_storage_util.dart';

/// 멤버 상태 Provider (UI용 MemberView 기준, 단일 소스)
///
/// - 구독 없음: 100명 페이지네이션 + on-demand 로드
class MemberProvider with ChangeNotifier {
  final MemberService _service = MemberService();

  static final int _pageSize = MemberService.pageSize;

  String? _placeId;
  bool _isSubManagerForPlace = false;

  final List<PlaceMember> _placeMembers = [];
  DocumentSnapshot? _lastMemberPageDoc;
  DocumentSnapshot? _lastEnrollmentPageDoc;
  List<CourseEnrollment> _allPlaceEnrollments = [];

  List<PendingMember> _pendingMembers = [];
  final List<CourseEnrollment> _enrollments = [];

  final List<PlaceMember> _onDemandPlaceMembers = [];
  final List<CourseEnrollment> _onDemandEnrollments = [];
  final Set<String> _onDemandUserIdsInFlight = {};

  bool _hasMoreMembers = true;
  bool _isLoadingMore = false;
  bool _isLoading = true;
  String? _error;
  String? _selectedCourseId;
  bool _showPending = true;
  final Set<String> _deletingMemberIds = {};
  final Set<String> _processingMemberIds = {};

  /// 코스별 "부매니저 추가 중" userId 목록 (로컬에서 카드 먼저 보여주고 로딩)
  final Map<String, Set<String>> _pendingSubManagerAdds = {};

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
  bool get hasMoreMembers => _hasMoreMembers;

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
    return members
        .map(
          (m) => MemberView.fromPlaceMember(
            m,
            enrolledCourseIds: byUser[m.userId] ?? const [],
          ),
        )
        .toList();
  }

  List<MemberView> _pendingToViews() {
    final list = _pendingMembers;
    return list.map(MemberView.fromPendingMember).toList();
  }

  bool get isSubManagerForPlace => _isSubManagerForPlace;

  List<CourseEnrollment> get _mergedEnrollments {
    final byId = <String, CourseEnrollment>{};
    for (final e in _enrollments) {
      byId[e.id] = e;
    }
    for (final e in _onDemandEnrollments) {
      byId[e.id] = e;
    }
    return _dedupeEnrollmentsByUserCourseList(byId.values);
  }

  List<CourseEnrollment> _dedupeEnrollmentsByUserCourseList(
    Iterable<CourseEnrollment> source,
  ) {
    final placeId = _placeId;
    final list = source.toList();
    if (placeId == null || placeId.isEmpty || list.isEmpty) return list;

    final best = <String, CourseEnrollment>{};
    for (final e in list) {
      final key = '${e.userId}|${e.courseId}';
      final canonicalId = '${e.userId}_${placeId}_${e.courseId}';
      final prev = best[key];
      if (prev == null) {
        best[key] = e;
        continue;
      }
      if (e.id == canonicalId) {
        best[key] = e;
      } else if (prev.id != canonicalId) {
        best[key] = e;
      }
    }
    return best.values.toList();
  }

  CourseEnrollment? getEnrollmentById(String enrollmentId) {
    if (enrollmentId.isEmpty) return null;
    for (final e in _mergedEnrollments) {
      if (e.id == enrollmentId) return e;
    }
    return null;
  }

  CourseEnrollment? getEnrollmentForUserAndCourse(
    String userId,
    String courseId,
  ) {
    final placeId = _placeId;
    final canonicalId =
        placeId != null && placeId.isNotEmpty
            ? '${userId}_${placeId}_$courseId'
            : null;
    CourseEnrollment? fallback;
    for (final e in _mergedEnrollments) {
      if (e.userId != userId || e.courseId != courseId) continue;
      if (canonicalId != null && e.id == canonicalId) return e;
      fallback ??= e;
    }
    return fallback;
  }

  bool isMemberLoadInFlight(String userId) =>
      _onDemandUserIdsInFlight.contains(userId);

  bool _isMemberLoaded(String userId) {
    for (final m in [..._placeMembers, ..._onDemandPlaceMembers]) {
      if (m.userId == userId) return true;
    }
    return false;
  }

  void _appendPlaceMembers(List<PlaceMember> members) {
    final existing = _placeMembers.map((m) => m.userId).toSet();
    for (final m in members) {
      if (m.userId.isEmpty || existing.contains(m.userId)) continue;
      _placeMembers.add(m);
      existing.add(m.userId);
    }
  }

  void _mergeEnrollments(List<CourseEnrollment> list) {
    final existingIds = {
      ..._enrollments.map((e) => e.id),
      ..._onDemandEnrollments.map((e) => e.id),
    };
    for (final e in list) {
      if (existingIds.contains(e.id)) continue;
      _enrollments.add(e);
      existingIds.add(e.id);
    }
    _dedupeEnrollmentsByUserCourse(_enrollments);
  }

  /// legacy enrollment id가 공존할 때 canonical id(`${userId}_${placeId}_${courseId}`) 우선
  void _dedupeEnrollmentsByUserCourse(List<CourseEnrollment> target) {
    final deduped = _dedupeEnrollmentsByUserCourseList(target);
    target
      ..clear()
      ..addAll(deduped);
  }

  List<PlaceMember> get _allLoadedPlaceMembers => [
    ..._placeMembers,
    ..._onDemandPlaceMembers,
  ];

  List<PlaceMember> get _uniqueLoadedPlaceMembers {
    final seen = <String>{};
    final out = <PlaceMember>[];
    for (final m in _allLoadedPlaceMembers) {
      if (m.userId.isEmpty || seen.contains(m.userId)) continue;
      seen.add(m.userId);
      out.add(m);
    }
    return out;
  }

  List<MemberView> _uniqueMemberViewsByUserId(List<MemberView> views) {
    final seen = <String>{};
    final out = <MemberView>[];
    for (final v in views) {
      if (v.userId.isEmpty || seen.contains(v.userId)) continue;
      seen.add(v.userId);
      out.add(v);
    }
    return out;
  }

  List<MemberView> _pendingViewsExcludingRegisteredPhones(
    List<MemberView> placeViews,
  ) {
    if (!_showPending) return const [];
    final registeredPhones =
        placeViews
            .map((v) => FormatUtils.normalizePhoneForCompare(v.phoneNumber))
            .where((p) => p.isNotEmpty)
            .toSet();
    return _pendingToViews().where((p) {
      final phone = FormatUtils.normalizePhoneForCompare(p.phoneNumber);
      if (phone.isEmpty) return true;
      return !registeredPhones.contains(phone);
    }).toList();
  }

  bool get _isCourseTabLoad =>
      _isSubManagerForPlace ||
      (_selectedTab == 1 && _selectedCourseIds.isNotEmpty);

  Future<void> _loadFirstPage() async {
    final placeId = _placeId;
    if (placeId == null || placeId.isEmpty) return;

    _placeMembers.clear();
    _enrollments.clear();
    _lastMemberPageDoc = null;
    _lastEnrollmentPageDoc = null;
    _hasMoreMembers = true;

    if (_isCourseTabLoad) {
      await _loadCourseTabPage();
    } else {
      await _loadAllTabPage();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadAllTabPage() async {
    final placeId = _placeId!;
    final (members, lastDoc) = await _service.getPlaceMembersPage(
      placeId,
      startAfter: _lastMemberPageDoc,
    );
    _appendPlaceMembers(members);
    _lastMemberPageDoc = lastDoc;
    _hasMoreMembers = members.length >= _pageSize;
    if (members.isEmpty) _hasMoreMembers = false;

    final userIds = members.map((m) => m.userId).where((id) => id.isNotEmpty);
    final ens = await _service.getEnrollmentsForUserIds(
      placeId,
      userIds.toList(),
    );
    _mergeEnrollments(ens);
  }

  Future<void> _loadCourseTabPage() async {
    final placeId = _placeId!;
    final courseIds = _selectedCourseIds.toList();
    if (courseIds.isEmpty) {
      _hasMoreMembers = false;
      return;
    }

    if (_isSubManagerForPlace) {
      final userIds =
          _allPlaceEnrollments
              .where((e) => courseIds.contains(e.courseId))
              .map((e) => e.userId)
              .toSet()
              .toList()
            ..sort();
      final start = _placeMembers.length;
      final chunk = userIds.skip(start).take(_pageSize).toList();
      if (chunk.isEmpty) {
        _hasMoreMembers = false;
        return;
      }
      final members = await _service.getPlaceMembersByUserIds(placeId, chunk);
      _appendPlaceMembers(members);
      _mergeEnrollments(
        _allPlaceEnrollments
            .where(
              (e) => chunk.contains(e.userId) && courseIds.contains(e.courseId),
            )
            .toList(),
      );
      _hasMoreMembers = start + chunk.length < userIds.length;
      return;
    }

    if (courseIds.length == 1) {
      final courseId = courseIds.first;
      final (ens, lastDoc) = await _service.getEnrollmentsPage(
        placeId,
        courseId: courseId,
        startAfter: _lastEnrollmentPageDoc,
      );
      _lastEnrollmentPageDoc = lastDoc;
      _hasMoreMembers = ens.length >= _pageSize;
      if (ens.isEmpty) _hasMoreMembers = false;
      _mergeEnrollments(ens);
      final userIds = ens.map((e) => e.userId).toList();
      if (userIds.isNotEmpty) {
        final members = await _service.getPlaceMembersByUserIds(
          placeId,
          userIds,
        );
        _appendPlaceMembers(members);
      }
      return;
    }

    final (ens, lastDoc) = await _service.getEnrollmentsPage(
      placeId,
      startAfter: _lastEnrollmentPageDoc,
    );
    _lastEnrollmentPageDoc = lastDoc;
    _hasMoreMembers = ens.length >= _pageSize;
    if (ens.isEmpty) _hasMoreMembers = false;
    final filtered =
        ens.where((e) => courseIds.contains(e.courseId)).toList();
    _mergeEnrollments(filtered);
    final userIds = filtered.map((e) => e.userId).toList();
    if (userIds.isNotEmpty) {
      final members = await _service.getPlaceMembersByUserIds(
        placeId,
        userIds,
      );
      _appendPlaceMembers(members);
    }
  }

  void _mergeOnDemandEnrollments(List<CourseEnrollment> list) {
    final existingIds = _onDemandEnrollments.map((e) => e.id).toSet()
      ..addAll(_enrollments.map((e) => e.id));
    for (final e in list) {
      if (existingIds.contains(e.id)) continue;
      _onDemandEnrollments.add(e);
      existingIds.add(e.id);
    }
    _dedupeEnrollmentsByUserCourse(_onDemandEnrollments);
  }

  /// 페이지에 없는 userId 멤버·enrollment on-demand 로드 (세션 예약자 등)
  Future<void> ensureMembersForUserIds(List<String> userIds) async {
    final placeId = _placeId;
    if (placeId == null || placeId.isEmpty) return;

    final distinct = userIds.where((id) => id.isNotEmpty).toSet().toList();
    if (distinct.isEmpty) return;

    final membersToFetch =
        distinct
            .where(
              (id) =>
                  !_isMemberLoaded(id) &&
                  !_onDemandUserIdsInFlight.contains(id),
            )
            .toList();

    if (membersToFetch.isNotEmpty) {
      _onDemandUserIdsInFlight.addAll(membersToFetch);
      notifyListeners();
      try {
        final members = await _service.getPlaceMembersByUserIds(
          placeId,
          membersToFetch,
        );
        final existingMemberIds = _allLoadedPlaceMembers.map((m) => m.userId).toSet();
        for (final m in members) {
          if (!existingMemberIds.contains(m.userId)) {
            _onDemandPlaceMembers.add(m);
            existingMemberIds.add(m.userId);
          }
        }
      } catch (e) {
        debugPrint('[MemberProvider] ensureMembersForUserIds members error: $e');
      } finally {
        _onDemandUserIdsInFlight.removeAll(membersToFetch);
        notifyListeners();
      }
    }

    try {
      final enrollments = await _service.getEnrollmentsForUserIds(
        placeId,
        distinct,
      );
      _mergeOnDemandEnrollments(enrollments);
      notifyListeners();
    } catch (e) {
      debugPrint('[MemberProvider] ensureMembersForUserIds enrollments error: $e');
    }
  }

  /// enrollmentId 단건 on-demand (예약 문서 enrollmentId 기준)
  Future<CourseEnrollment?> ensureEnrollmentById(String enrollmentId) async {
    if (enrollmentId.isEmpty) return null;
    final cached = getEnrollmentById(enrollmentId);
    if (cached != null) return cached;
    try {
      final fetched = await _service.getEnrollmentById(enrollmentId);
      if (fetched != null) {
        _mergeOnDemandEnrollments([fetched]);
        notifyListeners();
      }
      return fetched;
    } catch (e) {
      debugPrint('[MemberProvider] ensureEnrollmentById error: $e');
      return null;
    }
  }

  /// 전체 멤버: loadMore 페이지(100명) + on-demand + pending (userId·전화번호 중복 없음)
  List<MemberView> get allMembers {
    final byUser = <String, List<String>>{};
    for (final e in _mergedEnrollments) {
      byUser.putIfAbsent(e.userId, () => []).add(e.courseId);
    }
    final placeViews = _placeMembersToViews(_uniqueLoadedPlaceMembers, byUser);
    final pendingViews = _pendingViewsExcludingRegisteredPhones(placeViews);
    final combined = _uniqueMemberViewsByUserId([
      ...placeViews,
      ...pendingViews,
    ]);
    return combined
        .map(
          (v) => v.copyWith(
            enrolledCourseIds:
                v.isPending ? v.enrolledCourseIds : (byUser[v.userId] ?? []),
          ),
        )
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
      for (final e in _mergedEnrollments) {
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
    for (final e in _mergedEnrollments) {
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

  /// 코스별 탭용: 선택된 코스들의 멤버 (검색·정렬 적용)
  List<MemberView> get listForCourseTab {
    if (_selectedCourseIds.isEmpty) return [];
    if (_isSubManagerForPlace) {
      var list = allMembers;
      if (_selectedCourseIds.length == 1) {
        final courseId = _selectedCourseIds.first;
        final byUser = <String, CourseEnrollment>{};
        for (final e in _mergedEnrollments) {
          if (e.courseId == courseId) byUser[e.userId] = e;
        }
        list =
            list.map((v) => v.copyWith(enrollment: byUser[v.userId])).toList();
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
                (v) => v.isPending && v.relatedCourseIds.contains(courseId),
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
                  ? v.relatedCourseIds.any(
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

  /// 이름, 전화번호, 과목 키워드, '가입 대기중', '매니저', '코스 매니저', N회(남은 횟수)로 검색. 공백 구분 시 모든 키워드 일치.
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
      // '대기중' / '가입 대기중' 키워드 (부분 일치: '대기', '가입' 등)
      final pendingMatch =
          v.isPending &&
          ('대기중'.contains(lower) ||
              lower.contains('대기중') ||
              pendingLabel.contains(lower) ||
              lower.contains(pendingLabel));
      // '매니저' 키워드 (부분 일치: '매니', '저' 등). '코스' 포함 시 코스 매니저로 한정
      final managerMatch =
          v.isManager &&
          ('매니저'.contains(lower) || lower.contains('매니저')) &&
          !lower.contains('코스');
      // '코스 매니저' 키워드 (부분 일치: '코스', '매니', '코스매니' 등)
      const subManagerLabel = '코스매니저';
      final subManagerMatch =
          v.isSubManager &&
          (subManagerLabel.contains(lower) || lower.contains(subManagerLabel));
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
          nameMatch ||
          phoneMatch ||
          pendingMatch ||
          managerMatch ||
          subManagerMatch ||
          courseMatch ||
          countMatch;
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
        final kManager =
            v.isManager &&
            ('매니저'.contains(kw) || kw.contains('매니저')) &&
            !kw.contains('코스');
        final kSubManager =
            v.isSubManager &&
            (subManagerLabel.contains(kw) || kw.contains(subManagerLabel));
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
        return kn ||
            kp ||
            kPending ||
            kManager ||
            kSubManager ||
            kCourse ||
            kCount;
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
        _mergedEnrollments.where((e) => e.userId == userId).toList();
    if (selectedCourseIds.isNotEmpty) {
      memberEnrollments =
          memberEnrollments
              .where((e) => selectedCourseIds.contains(e.courseId))
              .toList();
    }
    return memberEnrollments.any((e) => e.remainingReservations == count);
  }

  /// 역할 순서: 매니저(0) → 코스 매니저(1) → 일반 멤버(2) → 가입 대기중(3)
  static int _roleOrder(MemberView v) {
    if (v.isPending) return 3;
    if (v.isManager) return 0;
    if (v.isSubManager) return 1;
    return 2;
  }

  List<MemberView> _sortAllMembers(List<MemberView> list) {
    list = List.from(list);
    final byUser = <String, List<CourseEnrollment>>{};
    for (final e in _mergedEnrollments) {
      byUser.putIfAbsent(e.userId, () => []).add(e);
    }
    list.sort((a, b) {
      final roleA = _roleOrder(a);
      final roleB = _roleOrder(b);
      if (roleA != roleB) return roleA.compareTo(roleB);
      // 같은 역할 내: _sortBy == 0 이면 이름순, 아니면 기존 로직
      if (a.isPending && b.isPending) {
        return a.adminDisplayName.compareTo(b.adminDisplayName);
      }
      if (a.isPending) return 1;
      if (b.isPending) return -1;
      final aEnrollments = byUser[a.userId] ?? [];
      final bEnrollments = byUser[b.userId] ?? [];
      if (aEnrollments.isEmpty && bEnrollments.isEmpty) {
        return a.adminDisplayName.compareTo(b.adminDisplayName);
      }
      if (aEnrollments.isEmpty) return 1;
      if (bEnrollments.isEmpty) return -1;
      if (_sortBy == 0) {
        return a.adminDisplayName.compareTo(b.adminDisplayName);
      }
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
    if (_placeId != null && _placeId!.isNotEmpty) {
      unawaited(_loadFirstPage());
    }
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
    notifyListeners();
    if (_placeId != null &&
        _placeId!.isNotEmpty &&
        (_selectedTab == 1 || _isSubManagerForPlace)) {
      unawaited(_loadFirstPage());
    }
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
    if (_placeId != null && (_selectedTab == 1 || _isSubManagerForPlace)) {
      unawaited(_loadFirstPage());
    }
  }

  void setCourseSelectorExpanded(bool value) {
    if (_isCourseSelectorExpanded == value) return;
    _isCourseSelectorExpanded = value;
    notifyListeners();
  }

  /// placeId 설정 시 멤버 페이지네이션 로드 시작 (구독 없음)
  void setPlaceId(
    String? placeId, {
    bool isSubManagerForPlace = false,
    bool force = false,
  }) {
    if (!force &&
        _placeId == placeId &&
        _isSubManagerForPlace == isSubManagerForPlace) {
      return;
    }
    _placeId = placeId;
    _isSubManagerForPlace = isSubManagerForPlace;
    _placeMembers.clear();
    _lastMemberPageDoc = null;
    _lastEnrollmentPageDoc = null;
    _allPlaceEnrollments = [];
    _pendingMembers = [];
    _enrollments.clear();
    _onDemandPlaceMembers.clear();
    _onDemandEnrollments.clear();
    _onDemandUserIdsInFlight.clear();
    _hasMoreMembers = true;
    _isLoading = true;
    _error = null;
    notifyListeners();

    if (placeId == null || placeId.isEmpty) {
      _isLoading = false;
      notifyListeners();
      return;
    }

    unawaited(_bootstrapPlace(placeId, isSubManagerForPlace));
  }

  Future<void> _bootstrapPlace(
    String placeId,
    bool isSubManagerForPlace,
  ) async {
    try {
      _pendingMembers = await _service.getPendingMembersByPlace(placeId);
      if (_isSubManagerForPlace) {
        _allPlaceEnrollments = await _service.getAllEnrollmentsForPlace(
          placeId,
        );
        _mergeEnrollments(_allPlaceEnrollments);
      }
      await _loadFirstPage();
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      debugPrint('[MemberProvider] bootstrap error: $e');
      notifyListeners();
    }
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

  /// 무한 스크롤: 다음 페이지 로드
  Future<void> loadMoreMembers() async {
    if (_placeId == null ||
        _placeId!.isEmpty ||
        _isLoadingMore ||
        !_hasMoreMembers) {
      return;
    }

    _isLoadingMore = true;
    notifyListeners();

    try {
      if (_isCourseTabLoad) {
        await _loadCourseTabPage();
      } else {
        await _loadAllTabPage();
      }
    } catch (e) {
      debugPrint('[MemberProvider] loadMoreMembers error: $e');
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }

  void clear() {
    _placeId = null;
    _isSubManagerForPlace = false;
    _placeMembers.clear();
    _lastMemberPageDoc = null;
    _lastEnrollmentPageDoc = null;
    _allPlaceEnrollments = [];
    _onDemandPlaceMembers.clear();
    _onDemandEnrollments.clear();
    _onDemandUserIdsInFlight.clear();
    _pendingMembers = [];
    _enrollments.clear();
    _hasMoreMembers = true;
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
}
