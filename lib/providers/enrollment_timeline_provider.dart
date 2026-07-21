import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/course_enrollment.dart';
import '../models/enrollment_action.dart';
import '../models/enrollment_timeline_item.dart';
import '../services/enrollment_timeline_service.dart';

/// actionHistory 기반 타임라인 Provider
class EnrollmentTimelineProvider extends ChangeNotifier {
  final EnrollmentTimelineService _service = EnrollmentTimelineService();
  StreamSubscription<List<EnrollmentTimelineItem>>? _subscription;

  List<EnrollmentTimelineItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

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

  void watchTimeline(CourseEnrollment enrollment) {
    _subscription?.cancel();
    _loading = true;
    _error = null;
    _items = [];
    notifyListeners();

    _subscription = _service
        .watchTimeline(enrollmentId: enrollment.id)
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

  Future<void> loadTimelineOnce(CourseEnrollment enrollment) async {
    _subscription?.cancel();
    _subscription = null;
    _loading = true;
    _error = null;
    _items = [];
    _cachedActions = [];
    _nextActionCursor = null;
    _hasMoreActionsFromServer = false;
    _loadModeEnrollment = enrollment;
    notifyListeners();

    try {
      final result = await _service.loadTimelineOnce(
        enrollmentId: enrollment.id,
        actionLimit: 200,
      );
      _items = result.items;
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

  Future<void> loadMoreActions() async {
    final enrollment = _loadModeEnrollment;
    if (enrollment == null || _nextActionCursor == null) return;
    if (_loadingMore) return;

    _loadingMore = true;
    notifyListeners();

    try {
      final result = await _service.loadMoreActions(
        existingActions: _cachedActions,
        enrollmentId: enrollment.id,
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

  void invalidate() {
    _items = [];
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
