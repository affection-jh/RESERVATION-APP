import 'package:flutter/foundation.dart';
import '../models/course.dart';
import '../services/firestore_service.dart';

/// 코스 관리 Provider
///
/// 코스 목록 및 CRUD 작업 관리
class CourseProvider with ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();

  List<Course> _courses = [];
  bool _isLoading = false;
  String? _error;
  String? _placeId;

  List<Course> get courses => List.unmodifiable(_courses);
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 코스 목록 로드
  Future<void> loadCourses(String placeId) async {
    _placeId = placeId;
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _courses = await _firestoreService.getCoursesByPlace(placeId);
      _error = null;
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
    notifyListeners();
  }

  String _generateCourseId() {
    return 'course_${DateTime.now().millisecondsSinceEpoch}';
  }
}
