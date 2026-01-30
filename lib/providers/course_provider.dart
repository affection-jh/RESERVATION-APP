import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/course.dart';
import '../models/course_override.dart';
import '../services/firestore_service.dart';
import '../policies/course_policy.dart';

/// 코스 관리 Provider
///
/// 코스 목록 및 CRUD 작업 관리
class CourseProvider with ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();

  List<Course> _courses = [];
  bool _isLoading = false;
  String? _error;
  String? _placeId;

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

  List<Course> get courses => List.unmodifiable(_courses);
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 특정 주의 비정기 일정 가져오기
  List<CourseOverride> getOverridesForWeek(String weekStartDate) {
    return _overridesByWeek[weekStartDate] ?? [];
  }

  /// 코스 정책 가져오기 (캐시에서)
  CoursePolicy? getCoursePolicy(String courseId) {
    return _coursePolicies[courseId];
  }

  /// 코스 정책 로드 (캐시에 없을 때만)
  Future<void> loadCoursePolicy(String courseId, String placeId) async {
    // 이미 캐시에 있으면 스킵
    if (_coursePolicies.containsKey(courseId)) {
      return;
    }

    try {
      final policy = await _firestoreService.getCoursePolicy(
        courseId: courseId,
        placeId: placeId,
      );
      _coursePolicies[courseId] = policy;
      notifyListeners();
    } catch (_) {
      // 정책 로드 실패 시 기본값 사용
      _coursePolicies[courseId] = CoursePolicy.defaultFor(
        courseId: courseId,
        placeId: placeId,
      );
      notifyListeners();
    }
  }

  /// 코스 정책 강제 재로드 (정책 변경 시)
  Future<void> reloadCoursePolicy(String courseId, String placeId) async {
    try {
      final policy = await _firestoreService.getCoursePolicy(
        courseId: courseId,
        placeId: placeId,
      );
      _coursePolicies[courseId] = policy;
      notifyListeners();
    } catch (_) {
      // 정책 로드 실패 시 기본값 사용
      _coursePolicies[courseId] = CoursePolicy.defaultFor(
        courseId: courseId,
        placeId: placeId,
      );
      notifyListeners();
    }
  }

  /// 모든 코스 정책 로드 (앱 시작 시)
  Future<void> loadAllCoursePolicies(String placeId) async {
    if (_courses.isEmpty) return;

    for (final course in _courses) {
      if (!_coursePolicies.containsKey(course.id)) {
        try {
          final policy = await _firestoreService.getCoursePolicy(
            courseId: course.id,
            placeId: placeId,
          );
          _coursePolicies[course.id] = policy;
        } catch (_) {
          _coursePolicies[course.id] = CoursePolicy.defaultFor(
            courseId: course.id,
            placeId: placeId,
          );
        }
      }
    }
    notifyListeners();
  }

  /// 비정기 일정 구독 시작
  void subscribeToOverrides(String placeId, List<String> weekStartDates) {
    final wanted = weekStartDates.take(3).toSet();
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
            notifyListeners();
            },
            onError: (_) {
              // 스트림 실패 시에도 크래시/무한 로딩 방지: 해당 주 데이터만 비움
              _overridesByWeek[weekStartDate] = const <CourseOverride>[];
              notifyListeners();
            },
          );
    }
  }

  /// 코스 목록 로드
  Future<void> loadCourses(String placeId) async {
    _placeId = placeId;
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _courses = await _firestoreService.getCoursesByPlace(placeId);
      _error = null;

      // 코스 목록 로드 후 모든 코스 정책도 로드
      await loadAllCoursePolicies(placeId);
    } catch (e) {
      _error = e.toString();
      _courses = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 코스 실시간 구독
  Stream<List<Course>> watchCourses(String placeId) {
    _placeId = placeId;
    return _firestoreService.watchCoursesByPlace(placeId).map((courses) {
      _courses = courses;
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
      final course = Course(
        id: _generateCourseId(),
        name: name,
        description: '', // 기본값: 빈 문자열
        color: color,
        sessions: [],
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
  Future<void> deleteCourse(String courseId) async {
    _isLoading = true;
    notifyListeners();

    try {
      await _firestoreService.deleteCourse(_placeId!, courseId);
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
    _courses = [];
    _isLoading = false;
    _error = null;
    _placeId = null;
    _coursePolicies.clear();
    _cancelAllOverrideSubscriptions();
    _overridesByWeek.clear();
    _overridesPlaceId = null;
    notifyListeners();
  }

  void _cancelAllOverrideSubscriptions() {
    for (final sub in _overrideSubscriptionsByWeek.values) {
      sub.cancel();
    }
    _overrideSubscriptionsByWeek.clear();
  }

  @override
  void dispose() {
    _cancelAllOverrideSubscriptions();
    super.dispose();
  }

  String _generateCourseId() {
    return 'course_${DateTime.now().millisecondsSinceEpoch}';
  }
}
