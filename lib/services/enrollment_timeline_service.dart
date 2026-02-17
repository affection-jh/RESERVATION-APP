import 'dart:async';
import '../models/enrollment_action.dart';
import '../models/enrollment_timeline_item.dart';
import '../models/session_reservation.dart';
import 'enrollment_service.dart';
import 'reservation_service.dart';

/// 통합 타임라인 로드 결과 (온디멘드용, 페이지네이션 지원)
class EnrollmentTimelineLoadResult {
  final List<EnrollmentTimelineItem> items;
  final List<SessionReservation> reservations;
  final List<EnrollmentAction> actions;
  final Object? nextActionCursor;
  /// 마지막 액션 fetch가 limit(200)개를 반환했을 때만 true (서버에 더 있음)
  final bool hasMoreActionsFromServer;

  const EnrollmentTimelineLoadResult({
    required this.items,
    required this.reservations,
    required this.actions,
    this.nextActionCursor,
    this.hasMoreActionsFromServer = false,
  });
}

/// 예약(reservations)과 관리자 조치(actionHistory)를 합쳐 통합 타임라인 스트림/온디멘드 제공
class EnrollmentTimelineService {
  final ReservationService _reservationService = ReservationService();
  final EnrollmentService _enrollmentService = EnrollmentService();

  /// 온디멘드 1회 로드 (구독 없음). 액션 200개씩 페이지네이션.
  /// 액션 반영 후 invalidate 시 재호출.
  Future<EnrollmentTimelineLoadResult> loadTimelineOnce({
    required String enrollmentId,
    required String userId,
    required String placeId,
    required String courseId,
    int actionLimit = 200,
    Object? actionStartAfterCursor,
  }) async {
    final reservations = await _reservationService
        .watchUserReservations(userId, placeId: placeId)
        .first;
    final result = await _enrollmentService.getActionHistory(
      enrollmentId,
      limit: actionLimit,
      startAfterCursor: actionStartAfterCursor,
    );

    final items = <EnrollmentTimelineItem>[];

    for (final r in reservations) {
      if (r.courseId != courseId) continue;
      if (r.enrollmentId.isNotEmpty && r.enrollmentId != enrollmentId) {
        continue;
      }
      items.add(ReservationTimelineItem(
        dateTime: r.reservedAt,
        reservation: r,
      ));
    }

    for (final a in result.actions) {
      items.add(ActionTimelineItem(dateTime: a.performedAt, action: a));
    }

    items.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return EnrollmentTimelineLoadResult(
      items: items,
      reservations: reservations,
      actions: result.actions,
      nextActionCursor: result.nextPageCursor,
      hasMoreActionsFromServer:
          result.actions.length >= actionLimit && result.nextPageCursor != null,
    );
  }

  /// 액션 더 불러오기 (페이지네이션). [existingReservations]+[existingActions]와 병합하여 정렬.
  Future<EnrollmentTimelineLoadResult> loadMoreActions({
    required List<SessionReservation> existingReservations,
    required List<EnrollmentAction> existingActions,
    required String enrollmentId,
    required String courseId,
    required Object startAfterCursor,
    int limit = 200,
  }) async {
    final result = await _enrollmentService.getActionHistory(
      enrollmentId,
      limit: limit,
      startAfterCursor: startAfterCursor,
    );
    final allActions = [...existingActions, ...result.actions];
    final items = _merge(reservations: existingReservations, actions: allActions);
    return EnrollmentTimelineLoadResult(
      items: items,
      reservations: existingReservations,
      actions: allActions,
      nextActionCursor: result.nextPageCursor,
      hasMoreActionsFromServer:
          result.actions.length >= limit && result.nextPageCursor != null,
    );
  }

  static List<EnrollmentTimelineItem> _merge({
    required List<SessionReservation> reservations,
    required List<EnrollmentAction> actions,
  }) {
    final items = <EnrollmentTimelineItem>[];
    for (final r in reservations) {
      items.add(ReservationTimelineItem(dateTime: r.reservedAt, reservation: r));
    }
    for (final a in actions) {
      items.add(ActionTimelineItem(dateTime: a.performedAt, action: a));
    }
    items.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    return items;
  }

  /// [enrollmentId], [userId], [placeId], [courseId]로 예약·조치를 합쳐 최신순 스트림 반환
  /// [reservationsOnly]: true면 actionHistory 구독 생략 (일반 유저용, actionHistory 읽기 권한 없음)
  Stream<List<EnrollmentTimelineItem>> watchTimeline({
    required String enrollmentId,
    required String userId,
    required String placeId,
    required String courseId,
    bool reservationsOnly = false,
  }) {
    List<SessionReservation> latestReservations = [];
    List<EnrollmentAction> latestActions = [];
    final controller = StreamController<List<EnrollmentTimelineItem>>();

    void emitMerged() {
      final items = <EnrollmentTimelineItem>[];

      for (final r in latestReservations) {
        if (r.courseId != courseId) continue;
        if (r.enrollmentId.isNotEmpty && r.enrollmentId != enrollmentId) continue;
        items.add(ReservationTimelineItem(
          dateTime: r.reservedAt,
          reservation: r,
        ));
      }

      for (final a in latestActions) {
        items.add(ActionTimelineItem(dateTime: a.performedAt, action: a));
      }

      items.sort((a, b) => b.dateTime.compareTo(a.dateTime));
      controller.add(items);
    }

    void onStreamError(Object e, StackTrace st) {
      // permission-denied 등 Firestore 에러 시 미처리 예외 방지
      assert(() {
        // ignore: avoid_print
        print('[EnrollmentTimelineService] stream error: $e\n$st');
        return true;
      }());
      if (!controller.isClosed) {
        emitMerged(); // 부분 데이터(예: 예약만)라도 반영
        controller.addError(e, st);
      }
    }

    final resSub = _reservationService
        .watchUserReservations(userId, placeId: placeId)
        .listen(
          (list) {
            latestReservations = list;
            emitMerged();
          },
          onError: onStreamError,
        );

    StreamSubscription<List<EnrollmentAction>>? actSub;
    if (!reservationsOnly) {
      actSub = _enrollmentService
          .watchActionHistory(enrollmentId)
          .listen(
            (list) {
              latestActions = list;
              emitMerged();
            },
            onError: onStreamError,
          );
    } else {
      emitMerged(); // 초기 emit (reservations만)
    }

    controller.onCancel = () async {
      await resSub.cancel();
      await actSub?.cancel();
    };

    return controller.stream;
  }
}
