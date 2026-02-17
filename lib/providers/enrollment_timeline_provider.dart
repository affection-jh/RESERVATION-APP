import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/course_enrollment.dart';
import '../models/enrollment_action.dart';
import '../models/enrollment_timeline_item.dart';
import '../models/session_reservation.dart';
import '../services/enrollment_timeline_service.dart';

/// 통합 타임라인(예약 + 관리자 조치) Provider
/// - 유저: watchTimeline (스트림 구독)
/// - 관리자: loadTimelineOnce / loadMoreActions / invalidate (온디멘드)
class EnrollmentTimelineProvider extends ChangeNotifier {
  final EnrollmentTimelineService _service = EnrollmentTimelineService();
  StreamSubscription<List<EnrollmentTimelineItem>>? _subscription;

  List<EnrollmentTimelineItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  List<SessionReservation> _cachedReservations = [];
  List<EnrollmentAction> _cachedActions = [];
  Object? _nextActionCursor;
  bool _hasMoreActionsFromServer = false;
  CourseEnrollment? _loadModeEnrollment;

  List<EnrollmentTimelineItem> get timelineItems => List.unmodifiable(_items);
  bool get isLoading => _loading;
  bool get isLoadingMore => _loadingMore;
  Object? get error => _error;
  Object? get nextActionCursor => _nextActionCursor;
  bool get hasMoreActions => _hasMoreActionsFromServer;

  /// [reservationsOnly]: true면 actionHistory 구독 생략 (일반 유저용)
  void watchTimeline(CourseEnrollment enrollment, {bool reservationsOnly = false}) {
    _subscription?.cancel();
    _loading = true;
    _error = null;
    _items = [];
    notifyListeners();

    _subscription = _service
        .watchTimeline(
          enrollmentId: enrollment.id,
          userId: enrollment.userId,
          placeId: enrollment.placeId,
          courseId: enrollment.courseId,
          reservationsOnly: reservationsOnly,
        )
        .listen(
          (items) {
            _items = items;
            _loading = false;
            _error = null;
            notifyListeners();
          },
          onError: (e, st) {
            debugPrint('[EnrollmentTimelineProvider] error: $e\n$st');
            _loading = false;
            _error = e;
            notifyListeners();
          },
        );
  }

  /// 온디멘드 1회 로드 (관리자용). 구독 없이 필요 시 호출.
  Future<void> loadTimelineOnce(CourseEnrollment enrollment) async {
    _subscription?.cancel();
    _subscription = null;
    _loading = true;
    _error = null;
    _items = [];
    _cachedReservations = [];
    _cachedActions = [];
    _nextActionCursor = null;
    _hasMoreActionsFromServer = false;
    _loadModeEnrollment = enrollment;
    notifyListeners();

    try {
      final result = await _service.loadTimelineOnce(
        enrollmentId: enrollment.id,
        userId: enrollment.userId,
        placeId: enrollment.placeId,
        courseId: enrollment.courseId,
        actionLimit: 200,
      );
      _items = result.items;
      _cachedReservations = result.reservations;
      _cachedActions = result.actions;
      _nextActionCursor = result.nextActionCursor;
      _hasMoreActionsFromServer = result.hasMoreActionsFromServer;
      _loading = false;
      _error = null;
      notifyListeners();
    } catch (e, st) {
      debugPrint('[EnrollmentTimelineProvider] loadTimelineOnce error: $e\n$st');
      _loading = false;
      _error = e;
      notifyListeners();
    }
  }

  /// 액션 더 불러오기 (관리자용, loadTimelineOnce 이후)
  Future<void> loadMoreActions() async {
    final enrollment = _loadModeEnrollment;
    if (enrollment == null || _nextActionCursor == null) return;
    if (_loadingMore) return;

    _loadingMore = true;
    notifyListeners();

    try {
      final result = await _service.loadMoreActions(
        existingReservations: _cachedReservations,
        existingActions: _cachedActions,
        enrollmentId: enrollment.id,
        courseId: enrollment.courseId,
        startAfterCursor: _nextActionCursor!,
        limit: 200,
      );
      _items = result.items;
      _cachedActions = result.actions;
      _nextActionCursor = result.nextActionCursor;
      _hasMoreActionsFromServer = result.hasMoreActionsFromServer;
      _loadingMore = false;
      notifyListeners();
    } catch (e, st) {
      debugPrint('[EnrollmentTimelineProvider] loadMoreActions error: $e\n$st');
      _loadingMore = false;
      notifyListeners();
    }
  }

  /// 캐시 무효화. 액션 반영 후 호출. 펼칠 때 loadTimelineOnce 재호출됨.
  void invalidate() {
    _items = [];
    _cachedReservations = [];
    _cachedActions = [];
    _nextActionCursor = null;
    _hasMoreActionsFromServer = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
