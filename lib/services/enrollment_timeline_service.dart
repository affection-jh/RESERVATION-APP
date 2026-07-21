import 'dart:async';
import '../models/enrollment_action.dart';
import '../models/enrollment_timeline_item.dart';
import 'enrollment_service.dart';

/// 통합 타임라인 로드 결과 (온디멘드용, 페이지네이션 지원)
class EnrollmentTimelineLoadResult {
  final List<EnrollmentTimelineItem> items;
  final List<EnrollmentAction> actions;
  final Object? nextActionCursor;
  /// 마지막 액션 fetch가 limit(200)개를 반환했을 때만 true (서버에 더 있음)
  final bool hasMoreActionsFromServer;

  const EnrollmentTimelineLoadResult({
    required this.items,
    required this.actions,
    this.nextActionCursor,
    this.hasMoreActionsFromServer = false,
  });
}

/// actionHistory만 타임라인으로 제공 (예약 생성·취소 포함)
class EnrollmentTimelineService {
  final EnrollmentService _enrollmentService = EnrollmentService();

  Future<EnrollmentTimelineLoadResult> loadTimelineOnce({
    required String enrollmentId,
    int actionLimit = 200,
    Object? actionStartAfterCursor,
  }) async {
    final result = await _enrollmentService.getActionHistory(
      enrollmentId,
      limit: actionLimit,
      startAfterCursor: actionStartAfterCursor,
    );

    return EnrollmentTimelineLoadResult(
      items: _fromActions(result.actions),
      actions: result.actions,
      nextActionCursor: result.nextPageCursor,
      hasMoreActionsFromServer:
          result.actions.length >= actionLimit && result.nextPageCursor != null,
    );
  }

  Future<EnrollmentTimelineLoadResult> loadMoreActions({
    required List<EnrollmentAction> existingActions,
    required String enrollmentId,
    required Object startAfterCursor,
    int limit = 200,
  }) async {
    final result = await _enrollmentService.getActionHistory(
      enrollmentId,
      limit: limit,
      startAfterCursor: startAfterCursor,
    );
    final allActions = [...existingActions, ...result.actions];
    return EnrollmentTimelineLoadResult(
      items: _fromActions(allActions),
      actions: allActions,
      nextActionCursor: result.nextPageCursor,
      hasMoreActionsFromServer:
          result.actions.length >= limit && result.nextPageCursor != null,
    );
  }

  static List<EnrollmentTimelineItem> _fromActions(
    List<EnrollmentAction> actions,
  ) {
    final items = actions
        .map((a) => ActionTimelineItem(dateTime: a.performedAt, action: a))
        .toList();
    items.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    return items;
  }

  Stream<List<EnrollmentTimelineItem>> watchTimeline({
    required String enrollmentId,
  }) {
    return _enrollmentService
        .watchActionHistory(enrollmentId)
        .map(_fromActions);
  }
}
