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
    // 같은 userId/placeId로 이미 구독 중이면 재구독하지 않음 (이미 데이터 있음)
    if (_subscription != null &&
        _currentUserId == userId &&
        _currentPlaceId == placeId) {
      debugPrint(
        '[EnrollmentProvider] loadUserEnrollments 스킵 (이미 구독 중) '
        'userId=$userId placeId=$placeId 현재 _enrollments=${_enrollments.length}',
      );
      return;
    }

    debugPrint('[EnrollmentProvider] loadUserEnrollments 시작 userId=$userId placeId=$placeId');
    await _subscription?.cancel();
    _subscription = null;
    _currentUserId = userId;
    _currentPlaceId = placeId;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final stream = _enrollmentService.watchUserEnrollments(
        userId,
        placeId: placeId,
      );
      final firstDone = Completer<void>();
      var emitCount = 0;
      _subscription = stream.listen(
        (items) {
          emitCount++;
          _enrollments = items;
          _isLoading = false;
          _error = null;
          debugPrint(
            '[EnrollmentProvider] emit #$emitCount userId=$userId placeId=$placeId '
            'enrollments=${items.length} (remaining: ${items.map((e) => e.remainingReservations).join(",")})',
          );
          // 첫 emit에서 바로 완료 (등록 없을 때 빈 리스트 1회만 오면 타임아웃 방지)
          if (!firstDone.isCompleted) {
            firstDone.complete();
            debugPrint('[EnrollmentProvider] firstDone.complete() emitCount=$emitCount');
          }
          notifyListeners();
        },
        onError: (e) {
          _enrollments = [];
          _isLoading = false;
          _error = e.toString();
          debugPrint('[EnrollmentProvider] stream onError: $e');
          if (!firstDone.isCompleted) firstDone.complete();
          notifyListeners();
        },
      );
      await firstDone.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          if (!firstDone.isCompleted) firstDone.complete();
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

  /// enrollment 취소 (화면을 나가도 진행 상태 유지)
  Future<void> cancelEnrollment({
    required String placeId,
    required String userId,
    required String courseId,
    required String enrollmentId,
    bool cascade = false,
    bool sendNotification = true,
  }) async {
    _cancelInFlightKeys.add(enrollmentId);
    notifyListeners();

    try {
      await _enrollmentService.cancelEnrollment(
        placeId: placeId,
        userId: userId,
        courseId: courseId,
        cascade: cascade,
        sendNotification: sendNotification,
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
