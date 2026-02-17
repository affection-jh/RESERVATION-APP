import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/course.dart';
import '../models/course_override.dart';
import '../services/firestore_service.dart';
import '../models/course_policy.dart';

/// 코스 관리 Provider
///
/// 코스 목록 및 CRUD 작업 관리
class CourseProvider with ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();

  List<Course> _courses = [];
  bool _isLoading = false;
  String? _error;
  String? _placeId;

  /// 코스 목록 실시간 구독 (DB 변경 시 UI 자동 반영)
  StreamSubscription<List<Course>>? _coursesSubscription;
  String? _subscribedPlaceId;

  // 코스 정책 캐시 (코스 ID -> 정책)
  final Map<String, CoursePolicy> _coursePolicies = {};

  // 비정기 일정 구독
  // NOTE: 기존 구현은 subscribeToOverrides() 호출 때마다 .listen()을 누적하고,
  // _overrideSubscription에 할당하지 않아 cancel이 실제 구독을 끊지 못했습니다.
  // 그 결과 notifyListeners()가 폭증하며 UI가 "파르르" 떨리고 데이터가 깜빡이는 문제가 생길 수 있습니다.
  final Map<String, StreamSubscription<List<CourseOverride>>>
  _overrideSubscriptionsByWeek = {};
  final Map<String, List<CourseOverride>> _overridesByWeek = {};
  String? _overridesPlaceId;
  static const Duration _overrideDebounceDuration = Duration(milliseconds: 150);
  final Map<String, Timer> _overrideDebounceTimers = {};

  /// (placeId|courseId) 별 주차 오픈 구독 — 화면 중복 구독 제거
  final Map<String, StreamSubscription<Set<String>>> _bookingWeekOpensSubs = {};
  final Map<String, Set<String>> _bookingWeekOpensByKey = {};

  List<Course> get courses => List.unmodifiable(_courses);
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 현재 로드된 courses가 속한 placeId (loadCourses/saveCourse 호출 시 설정됨)
  /// 화면/탭 전환 중 PlaceProvider와 잠깐 어긋날 수 있어, 코스 관련 조회는 이 값을 우선 사용 권장.
  String? get currentPlaceId => _placeId;

  /// 특정 주의 비정기 일정 가져오기
  List<CourseOverride> getOverridesForWeek(String weekStartDate) {
    return _overridesByWeek[weekStartDate] ?? [];
  }

  /// 저장 중인 override 키 (weekStartDate -> {"date|dayOfWeek|startTime", ...})
  final Map<String, Set<String>> _savingOverridesByWeek = {};

  /// 비정기 일정 저장 시작 시 호출 (compact_calendar에서 해당 세션 박스에 로딩 스피너 표시)
  void setSavingOverrides(String weekStartDate, Set<String> keys) {
    _savingOverridesByWeek[weekStartDate] = Set.from(keys);
    notifyListeners();
  }

  /// 비정기 일정 저장 완료 후 호출
  void clearSavingOverrides(String weekStartDate) {
    _savingOverridesByWeek.remove(weekStartDate);
    notifyListeners();
  }

  /// 해당 세션이 저장 중인지 확인
  bool isSavingOverride(
    String weekStartDate,
    String date,
    int dayOfWeek,
    String startTime,
  ) {
    final key = '$date|$dayOfWeek|$startTime';
    return _savingOverridesByWeek[weekStartDate]?.contains(key) ?? false;
  }

  /// 특정 주의 비정기 일정 강제 새로고침 (저장 후 즉시 반영용)
  Future<void> refreshOverridesForWeek(
    String placeId,
    String weekStartDate,
  ) async {
    try {
      final overrides =
          await _firestoreService.getCourseOverrides(
        placeId: placeId,
        weekStartDate: weekStartDate,
      );
      _overridesByWeek[weekStartDate] = overrides;
      notifyListeners();
    } catch (_) {
      // 실패 시 스트림 데이터 유지
    }
  }

  /// 비정기 세션 삭제 시 UI 즉시 반영 (스트림 수신 전)
  void removeOverrideOptimistically(String weekStartDate, String overrideId) {
    final list = _overridesByWeek[weekStartDate];
    if (list == null) return;
    _overridesByWeek[weekStartDate] =
        list.where((o) => o.id != overrideId).toList();
    notifyListeners();
  }

  /// 정기 세션 취소 시 cancel override UI 즉시 반영 (스트림 수신 전)
  void addOverrideOptimistically(String weekStartDate, CourseOverride override) {
    final list = List<CourseOverride>.from(
      _overridesByWeek[weekStartDate] ?? [],
    );
    list.removeWhere(
      (o) =>
          o.courseId == override.courseId &&
          o.date == override.date &&
          o.dayOfWeek == override.dayOfWeek &&
          o.startTime == override.startTime &&
          o.isCancelled == true,
    );
    list.add(override);
    _overridesByWeek[weekStartDate] = list;
    notifyListeners();
  }

  /// 주차 예약 오픈 구독 (한 placeId+courseId당 1회만 구독, 화면 공유)
  void subscribeToBookingWeekOpens(String placeId, String courseId) {
    final key = '$placeId|$courseId';
    if (_bookingWeekOpensSubs.containsKey(key)) return;
    _bookingWeekOpensSubs[key] = _firestoreService
        .streamBookingWeekOpens(placeId: placeId, courseId: courseId)
        .listen(
          (opened) {
            _bookingWeekOpensByKey[key] = opened;
            notifyListeners();
          },
          onError: (_) {
            _bookingWeekOpensByKey[key] = {};
            notifyListeners();
          },
        );
  }

  /// 주차 예약 오픈된 weekStartDate 집합 (subscribeToBookingWeekOpens 호출 후 사용)
  Set<String> getBookingWeekOpens(String placeId, String courseId) {
    return _bookingWeekOpensByKey['$placeId|$courseId'] ?? {};
  }

  void _cancelBookingWeekOpensSubscriptions() {
    for (final sub in _bookingWeekOpensSubs.values) {
      sub.cancel();
    }
    _bookingWeekOpensSubs.clear();
    _bookingWeekOpensByKey.clear();
  }

  /// 코스 정책 가져오기 (코스에 embed된 policy 우선, 없으면 캐시)
  CoursePolicy? getCoursePolicy(String courseId) {
    final course = getCourse(courseId);
    if (course != null) return course.policy;
    return _coursePolicies[courseId];
  }

  /// 코스 정책 로드 (캐시에 없고 코스 목록에도 없을 때만)
  Future<void> loadCoursePolicy(String courseId, String placeId) async {
    if (getCourse(courseId) != null) return;
    if (_coursePolicies.containsKey(courseId)) return;

    try {
      final policy = await _firestoreService.getCoursePolicy(
        courseId: courseId,
        placeId: placeId,
      );
      _coursePolicies[courseId] = policy;
      notifyListeners();
    } catch (_) {
      _coursePolicies[courseId] = CoursePolicy.defaultValue;
      notifyListeners();
    }
  }

  /// 코스 정책 강제 재로드 (정책 저장 후 등)
  /// _coursePolicies 캐시와 _courses 내 해당 코스의 policy를 함께 갱신해
  /// 코스 상세/캘린더 등이 최신 정책을 반영하도록 함.
  Future<void> reloadCoursePolicy(String courseId, String placeId) async {
    CoursePolicy policy;
    try {
      policy = await _firestoreService.getCoursePolicy(
        courseId: courseId,
        placeId: placeId,
      );
    } catch (_) {
      policy = CoursePolicy.defaultValue;
    }
    _coursePolicies[courseId] = policy;
    final index = _courses.indexWhere((c) => c.id == courseId);
    if (index != -1) {
      final old = _courses[index];
      _courses[index] = Course(
        id: old.id,
        placeId: old.placeId,
        name: old.name,
        description: old.description,
        color: old.color,
        imageUrl: old.imageUrl,
        defaultTotalReservations: old.defaultTotalReservations,
        defaultPeriodType: old.defaultPeriodType,
        defaultPeriodValue: old.defaultPeriodValue,
        sessions: old.sessions,
        policy: policy,
        createdAt: old.createdAt,
        updatedAt: old.updatedAt,
      );
    }
    notifyListeners();
  }

  /// 모든 코스 정책 캐시 동기화 (코스에 embed된 policy로 채움)
  void _syncCoursePoliciesFromCourses() {
    for (final course in _courses) {
      _coursePolicies[course.id] = course.policy;
    }
  }

  /// 비정기 일정 구독 시작 (최대 10주 구독)
  void subscribeToOverrides(String placeId, List<String> weekStartDates) {
    final wanted = weekStartDates.take(10).toSet();
    if (wanted.isEmpty) return;

    // placeId가 바뀌면 기존 구독/캐시를 전부 정리 (서로 다른 place 간 데이터 섞임 방지)
    if (_overridesPlaceId != null && _overridesPlaceId != placeId) {
      _cancelAllOverrideSubscriptions();
      _overridesByWeek.clear();
    }
    _overridesPlaceId = placeId;

    // NOTE:
    // 여러 화면/위젯이 같은 CourseProvider를 공유합니다.
    // 여기서 "wanted에 없는 주를 cancel" 해버리면 서로의 구독을 끊어 UI가 깜빡일 수 있습니다.
    // 따라서 요청된 주는 **추가로 구독만**하고, 기존 다른 주 구독은 유지합니다.
    // (placeId 변경/clear/dispose에서는 전체 정리)

    // 요청된 주는 "이미 구독 중이면 재구독하지 않음"
    for (final weekStartDate in wanted) {
      if (_overrideSubscriptionsByWeek.containsKey(weekStartDate)) continue;
      _overrideSubscriptionsByWeek[weekStartDate] = _firestoreService
          .streamCourseOverrides(placeId: placeId, weekStartDate: weekStartDate)
          .listen(
            (overrides) {
              _overridesByWeek[weekStartDate] = overrides;
              _overrideDebounceTimers[weekStartDate]?.cancel();
              _overrideDebounceTimers[weekStartDate] = Timer(
                _overrideDebounceDuration,
                () {
                  _overrideDebounceTimers.remove(weekStartDate);
                  notifyListeners();
                },
              );
            },
            onError: (_) {
              _overrideDebounceTimers[weekStartDate]?.cancel();
              _overrideDebounceTimers.remove(weekStartDate);
              _overridesByWeek[weekStartDate] = const <CourseOverride>[];
              notifyListeners();
            },
          );
    }
  }

  /// 코스 목록 로드 + 실시간 구독 (동일 placeId 구독 중이면 유지, forceRefresh 시 재구독)
  /// Firestore 변경 시 _courses가 갱신되어 UI가 자동 반영됨.
  Future<void> loadCourses(String placeId, {bool forceRefresh = false}) async {
    if (!forceRefresh && _subscribedPlaceId == placeId) {
      return;
    }

    await _coursesSubscription?.cancel();
    _coursesSubscription = null;
    _subscribedPlaceId = null;

    _placeId = placeId;
    _isLoading = true;
    _error = null;
    notifyListeners();

    _coursesSubscription = _firestoreService
        .watchCoursesByPlace(placeId)
        .listen(
          (courses) {
            _courses = courses;
            _subscribedPlaceId = placeId;
            _syncCoursePoliciesFromCourses();
            _isLoading = false;
            _error = null;
            notifyListeners();
          },
          onError: (e) {
            _error = e.toString();
            _courses = [];
            _subscribedPlaceId = placeId;
            _isLoading = false;
            notifyListeners();
          },
        );
  }

  /// 코스 실시간 구독 (스트림만 반환, 호출처에서 listen. loadCourses가 구독 담당)
  Stream<List<Course>> watchCourses(String placeId) {
    _placeId = placeId;
    return _firestoreService.watchCoursesByPlace(placeId).map((courses) {
      _courses = courses;
      _syncCoursePoliciesFromCourses();
      notifyListeners();
      return courses;
    });
  }

  /// 코스 생성 (기본 정보만)
  Future<Course> createCourse({
    required String placeId,
    required String name,
    required int color,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final now = DateTime.now();
      final course = Course(
        id: _generateCourseId(),
        placeId: placeId,
        name: name,
        description: '',
        color: color,
        defaultTotalReservations: 10,
        sessions: [],
        policy: CoursePolicy.defaultValue,
        createdAt: now,
        updatedAt: now,
      );

      await _firestoreService.createCourse(placeId, course);
      _courses = [..._courses, course];
      _error = null;

      notifyListeners();
      return course;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 코스 생성 또는 업데이트 (완성된 Course 객체 사용)
  Future<Course> saveCourse({
    required String placeId,
    required Course course,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final isUpdate = _courses.any((c) => c.id == course.id);

      if (isUpdate) {
        await _firestoreService.updateCourse(placeId, course);
        final index = _courses.indexWhere((c) => c.id == course.id);
        if (index != -1) {
          _courses[index] = course;
        }
      } else {
        await _firestoreService.createCourse(placeId, course);
        _courses = [..._courses, course];
      }

      _error = null;
      notifyListeners();
      return course;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners(); // 로딩 상태 변경 알림
    }
  }

  /// 코스 업데이트
  Future<void> updateCourse(Course course) async {
    _isLoading = true;
    notifyListeners();

    try {
      await _firestoreService.updateCourse(_placeId!, course);
      final index = _courses.indexWhere((c) => c.id == course.id);
      if (index != -1) {
        _courses[index] = course;
      }
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners(); // 로딩 상태 변경 알림
    }
  }

  /// 코스 삭제
  Future<void> deleteCourse(String courseId, {bool cascade = false}) async {
    _isLoading = true;
    notifyListeners();

    try {
      await _firestoreService.deleteCourse(
        _placeId!,
        courseId,
        cascade: cascade,
      );
      _courses = _courses.where((c) => c.id != courseId).toList();
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

  /// 코스 가져오기
  Course? getCourse(String courseId) {
    try {
      return _courses.firstWhere((c) => c.id == courseId);
    } catch (e) {
      return null;
    }
  }

  /// 데이터 초기화
  void clear() {
    _coursesSubscription?.cancel();
    _coursesSubscription = null;
    _subscribedPlaceId = null;
    _courses = [];
    _isLoading = false;
    _error = null;
    _placeId = null;
    _coursePolicies.clear();
    _cancelAllOverrideSubscriptions();
    _overridesByWeek.clear();
    _overridesPlaceId = null;
    _cancelBookingWeekOpensSubscriptions();
    notifyListeners();
  }

  void _cancelAllOverrideSubscriptions() {
    for (final timer in _overrideDebounceTimers.values) {
      timer.cancel();
    }
    _overrideDebounceTimers.clear();
    for (final sub in _overrideSubscriptionsByWeek.values) {
      sub.cancel();
    }
    _overrideSubscriptionsByWeek.clear();
  }

  @override
  void dispose() {
    _coursesSubscription?.cancel();
    _cancelAllOverrideSubscriptions();
    _cancelBookingWeekOpensSubscriptions();
    super.dispose();
  }

  String _generateCourseId() {
    return 'course_${DateTime.now().millisecondsSinceEpoch}';
  }
}
