import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/course_enrollment.dart';
import '../services/enrollment_service.dart';

/// 유저의 코스 등록/예약 가능(횟수/유효기간) 상태 Provider
class EnrollmentProvider with ChangeNotifier {
  final EnrollmentService _enrollmentService = EnrollmentService();

  List<CourseEnrollment> _enrollments = [];
  bool _isLoading = false;
  String? _error;
  StreamSubscription<List<CourseEnrollment>>? _subscription;
  String? _currentUserId;
  String? _currentPlaceId;

  List<CourseEnrollment> get enrollments => List.unmodifiable(_enrollments);
  bool get isLoading => _isLoading;
  String? get error => _error;

  Map<String, CourseEnrollment> get enrollmentsByCourseId {
    final map = <String, CourseEnrollment>{};
    for (final e in _enrollments) {
      map[e.courseId] = e;
    }
    return map;
  }

  Future<void> loadUserEnrollments({
    required String userId,
    String? placeId,
  }) async {
    // 같은 userId/placeId로 이미 구독 중이면 재구독하지 않음
    if (_subscription != null &&
        _currentUserId == userId &&
        _currentPlaceId == placeId) {
      return;
    }

    await _subscription?.cancel();
    _subscription = null;
    _currentUserId = userId;
    _currentPlaceId = placeId;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _subscription = _enrollmentService
          .watchUserEnrollments(
            userId,
            placeId: placeId, // 서버 사이드 필터링
          )
          .listen(
            (items) {
              // 서버에서 이미 필터링된 enrollments 사용
              _enrollments = items;
              _isLoading = false;
              _error = null;
              notifyListeners();
            },
            onError: (e) {
              _enrollments = [];
              _isLoading = false;
              _error = e.toString();
              notifyListeners();
            },
          );
    } catch (e) {
      _enrollments = [];
      _isLoading = false;
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> clear() async {
    await _subscription?.cancel();
    _subscription = null;
    _currentUserId = null;
    _currentPlaceId = null;
    _enrollments = [];
    _isLoading = false;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
