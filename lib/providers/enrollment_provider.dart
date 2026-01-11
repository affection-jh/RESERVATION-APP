import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/course_enrollment.dart';
import '../services/enrollment_service.dart';
import '../services/firestore_service.dart';

/// 유저의 코스 등록/예약 가능(횟수/유효기간) 상태 Provider
class EnrollmentProvider with ChangeNotifier {
  final EnrollmentService _enrollmentService = EnrollmentService();
  final FirestoreService _firestoreService = FirestoreService();

  List<CourseEnrollment> _enrollments = [];
  bool _isLoading = false;
  String? _error;
  StreamSubscription<List<CourseEnrollment>>? _subscription;
  String? _currentUserId;
  String? _currentPlaceId;

  // enrollment 취소/재등록 in-flight 상태 관리 (화면을 나가도 진행 상태 유지)
  final Set<String> _cancelInFlightKeys = <String>{};
  final Set<String> _reenrollInFlightKeys = <String>{};

  List<CourseEnrollment> get enrollments => List.unmodifiable(_enrollments);
  bool get isLoading => _isLoading;
  String? get error => _error;

  bool isCancellingEnrollment(String enrollmentId) {
    return _cancelInFlightKeys.contains(enrollmentId);
  }

  bool isReenrollingEnrollment(String enrollmentId) {
    return _reenrollInFlightKeys.contains(enrollmentId);
  }

  bool isOperationInFlight(String enrollmentId) {
    return _cancelInFlightKeys.contains(enrollmentId) ||
        _reenrollInFlightKeys.contains(enrollmentId);
  }

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
    debugPrint(
      '[EnrollmentProvider] loadUserEnrollments start userId=$userId placeId=$placeId',
    );
    // 같은 userId/placeId로 이미 구독 중이면 재구독하지 않음
    if (_subscription != null &&
        _currentUserId == userId &&
        _currentPlaceId == placeId) {
      debugPrint(
        '[EnrollmentProvider] loadUserEnrollments skip (already subscribed) userId=$userId placeId=$placeId',
      );
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
      debugPrint('[EnrollmentProvider] subscribe watchUserEnrollments start');
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
              debugPrint(
                '[EnrollmentProvider] enrollments updated count=${items.length}',
              );
              for (final e in items) {
                debugPrint(
                  '[EnrollmentProvider]  - courseId=${e.courseId} remaining=${e.remainingReservations} total=${e.totalReservations} validUntil=${e.validUntil}',
                );
              }
              notifyListeners();
            },
            onError: (e) {
              _enrollments = [];
              _isLoading = false;
              _error = e.toString();
              debugPrint(
                '[EnrollmentProvider] watchUserEnrollments error: $_error',
              );
              notifyListeners();
            },
          );
    } catch (e) {
      _enrollments = [];
      _isLoading = false;
      _error = e.toString();
      debugPrint('[EnrollmentProvider] loadUserEnrollments catch: $_error');
      notifyListeners();
    }
  }

  Future<void> clear() async {
    debugPrint(
      '[EnrollmentProvider] clear (cancel subscription + reset state)',
    );
    await _subscription?.cancel();
    _subscription = null;
    _currentUserId = null;
    _currentPlaceId = null;
    _enrollments = [];
    _isLoading = false;
    _error = null;
    notifyListeners();
  }

  /// enrollment 취소 (화면을 나가도 진행 상태 유지)
  Future<void> cancelEnrollment({
    required String placeId,
    required String userId,
    required String courseId,
    required String enrollmentId,
    bool cascade = false,
  }) async {
    _cancelInFlightKeys.add(enrollmentId);
    notifyListeners();

    try {
      await _firestoreService.cancelEnrollment(
        placeId: placeId,
        userId: userId,
        courseId: courseId,
        cascade: cascade,
      );
    } finally {
      _cancelInFlightKeys.remove(enrollmentId);
      notifyListeners();
    }
  }

  /// enrollment 재등록 (화면을 나가도 진행 상태 유지)
  Future<T?> reenrollEnrollment<T>({
    required String enrollmentId,
    required Future<T> Function() reenrollAction,
  }) async {
    _reenrollInFlightKeys.add(enrollmentId);
    notifyListeners();

    try {
      return await reenrollAction();
    } finally {
      _reenrollInFlightKeys.remove(enrollmentId);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
