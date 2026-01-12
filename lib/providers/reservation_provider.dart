import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/reservation.dart';
import '../services/firestore_service.dart';
import '../utils/timezone_utils.dart';

enum ReservationOperationType { create, cancel, move }

class ReservationOperationEvent {
  final ReservationOperationType type;
  final bool success;
  final Reservation? reservation; // create 성공/실패, cancel 시 대상 예약(가능하면)
  final Object? error;
  final StackTrace? stackTrace;

  const ReservationOperationEvent({
    required this.type,
    required this.success,
    this.reservation,
    this.error,
    this.stackTrace,
  });
}

/// 예약 관리 Provider
///
/// 사용자 예약 및 관리 기능
class ReservationProvider with ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();

  List<Reservation> _reservations = [];
  bool _isLoading = false;
  String? _error;
  StreamSubscription<List<Reservation>>? _reservationSubscription;
  final Set<String> _createInFlightKeys = <String>{};
  final Set<String> _cancelInFlightKeys = <String>{};
  final Set<String> _moveInFlightKeys = <String>{};
  final StreamController<ReservationOperationEvent> _opController =
      StreamController<ReservationOperationEvent>.broadcast();
  String? _currentUserId;
  String? _currentPlaceId;

  List<Reservation> get reservations => List.unmodifiable(_reservations);
  bool get isLoading => _isLoading;
  String? get error => _error;
  Stream<ReservationOperationEvent> get operationEvents => _opController.stream;

  static int _parseTimeToMinutes(String? time) {
    if (time == null || time.isEmpty) return 0;
    final parts = time.split(':');
    if (parts.isEmpty) return 0;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = (parts.length > 1) ? (int.tryParse(parts[1]) ?? 0) : 0;
    return (h.clamp(0, 23) * 60) + (m.clamp(0, 59));
  }

  static DateTime _reservationStartDateTime(Reservation r) {
    final minutes = _parseTimeToMinutes(r.startTime);
    return DateTime(
      r.reservedDate.year,
      r.reservedDate.month,
      r.reservedDate.day,
      minutes ~/ 60,
      minutes % 60,
    );
  }

  /// "임박한 예약"이 먼저 오도록 정렬:
  /// - 미래/현재 예약: 시간 오름차순 (가장 임박한 순)
  /// - 과거 예약: 시간 내림차순 (가장 최근 과거가 위)
  static List<Reservation> _sortUpcomingFirst(List<Reservation> input) {
    final now = TimezoneUtils.getSeoulDateTime();
    final next = [...input];
    next.sort((a, b) {
      final aDt = _reservationStartDateTime(a);
      final bDt = _reservationStartDateTime(b);
      final aUpcoming = !aDt.isBefore(now);
      final bUpcoming = !bDt.isBefore(now);
      if (aUpcoming != bUpcoming) return aUpcoming ? -1 : 1;
      final cmp = aUpcoming ? aDt.compareTo(bDt) : bDt.compareTo(aDt);
      if (cmp != 0) return cmp;
      return a.id.compareTo(b.id);
    });
    return next;
  }

  String _reservationKey(Reservation r) {
    final d = r.reservedDate;
    final dateString =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return '${r.placeId}|${r.courseId}|${r.dayOfWeek}|${r.startTime}|$dateString';
  }

  String operationKeyFromParts({
    required String placeId,
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) {
    final d = DateTime(date.year, date.month, date.day);
    final dateString =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return '$placeId|$courseId|$dayOfWeek|$startTime|$dateString';
  }

  bool isOperationInFlightByKey(String key) {
    return _createInFlightKeys.contains(key) ||
        _cancelInFlightKeys.contains(key) ||
        _moveInFlightKeys.contains(key);
  }

  /// 작업 타입 확인 (예약중/취소중/변경중)
  ReservationOperationType? getOperationTypeByKey(String key) {
    if (_createInFlightKeys.contains(key)) {
      return ReservationOperationType.create;
    }
    if (_cancelInFlightKeys.contains(key)) {
      return ReservationOperationType.cancel;
    }
    if (_moveInFlightKeys.contains(key)) {
      return ReservationOperationType.move;
    }
    return null;
  }

  bool isCreatingReservation(Reservation reservation) {
    return _createInFlightKeys.contains(_reservationKey(reservation));
  }

  bool isCancellingReservation(Reservation reservation) {
    return _cancelInFlightKeys.contains(_reservationKey(reservation));
  }

  void _recomputeLoading() {
    _isLoading =
        _createInFlightKeys.isNotEmpty ||
        _cancelInFlightKeys.isNotEmpty ||
        _moveInFlightKeys.isNotEmpty;
  }

  /// 예약 이동(관리자) - 바텀시트를 닫아도 진행 상태가 유지되도록 Provider에서 in-flight 관리
  ///
  /// - oldKey + newKey 둘 다 in-flight에 넣어 UI(세션 블록)에서 처리 중 표시 가능
  Future<void> moveReservationWithinCourse({
    required Reservation reservation,
    required int newDayOfWeek,
    required String newStartTime,
    required DateTime newReservedDate,
  }) async {
    final oldKey = _reservationKey(reservation);
    final newKey = operationKeyFromParts(
      placeId: reservation.placeId,
      courseId: reservation.courseId,
      dayOfWeek: newDayOfWeek,
      startTime: newStartTime,
      date: newReservedDate,
    );

    if (isOperationInFlightByKey(oldKey) || isOperationInFlightByKey(newKey)) {
      throw Exception('예약 변경 처리 중입니다. 잠시만 기다려주세요.');
    }

    _moveInFlightKeys.add(oldKey);
    _moveInFlightKeys.add(newKey);
    _recomputeLoading();
    _error = null;
    notifyListeners();

    try {
      // 배치 함수 사용 (개별도 배치로 처리)
      final result = await _firestoreService.batchMoveReservations(
        reservationIds: [reservation.id],
        placeId: reservation.placeId,
        newDayOfWeek: newDayOfWeek,
        newStartTime: newStartTime,
        newReservedDate: newReservedDate,
      );

      final results = result['results'] as List<dynamic>? ?? [];
      final failedResults = results
          .where((r) => (r as Map)['success'] != true)
          .toList();
      if (failedResults.isNotEmpty) {
        final error =
            (failedResults.first as Map)['error'] as String? ??
            '예약 이동에 실패했습니다.';
        throw Exception(error);
      }

      // ✅ 낙관적 업데이트: 스트림이 늦게 오더라도 UI에 즉시 반영
      final updated = reservation.copyWith(
        dayOfWeek: newDayOfWeek,
        startTime: newStartTime,
        reservedDate: DateTime(
          newReservedDate.year,
          newReservedDate.month,
          newReservedDate.day,
        ),
      );
      final idx = _reservations.indexWhere((r) => r.id == reservation.id);
      if (idx >= 0) {
        final next = [..._reservations];
        next[idx] = updated;
        _reservations = _sortUpcomingFirst(next);
        notifyListeners();
      }

      if (!_opController.isClosed) {
        _opController.add(
          ReservationOperationEvent(
            type: ReservationOperationType.move,
            success: true,
            reservation: updated,
          ),
        );
      }
    } catch (e, stackTrace) {
      _error = e.toString();
      notifyListeners();
      if (!_opController.isClosed) {
        _opController.add(
          ReservationOperationEvent(
            type: ReservationOperationType.move,
            success: false,
            reservation: reservation,
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }
      rethrow;
    } finally {
      _moveInFlightKeys.remove(oldKey);
      _moveInFlightKeys.remove(newKey);
      _recomputeLoading();
      notifyListeners();
    }
  }

  /// 사용자 예약 목록 로드
  Future<void> loadUserReservations({
    required String userId,
    required String placeId,
  }) async {
    // 같은 userId/placeId로 이미 구독 중이면 재구독하지 않음
    if (_reservationSubscription != null &&
        _currentUserId == userId &&
        _currentPlaceId == placeId) {
      return;
    }

    // 기존 구독이 있으면 취소
    await _reservationSubscription?.cancel();
    _reservationSubscription = null;
    _currentUserId = userId;
    _currentPlaceId = placeId;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Stream을 사용하여 실시간 업데이트
      _reservationSubscription = _firestoreService
          .watchUserReservations(userId, placeId: placeId)
          .listen(
            (reservations) {
              _reservations = _sortUpcomingFirst(reservations);
              _error = null;
              _isLoading = false;
              notifyListeners();
            },
            onError: (error) {
              _error = error.toString();
              _reservations = [];
              _isLoading = false;
              notifyListeners();
            },
          );
    } catch (e) {
      _error = e.toString();
      _reservations = [];
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 사용자 예약 실시간 구독
  Stream<List<Reservation>> watchUserReservations({
    required String userId,
    required String placeId,
  }) {
    return _firestoreService
        .watchUserReservations(userId, placeId: placeId)
        .map((reservations) {
          _reservations = _sortUpcomingFirst(reservations);
          notifyListeners();
          return _reservations;
        });
  }

  /// 예약 생성
  ///
  /// Stream 구독이 자동으로 상태를 업데이트하므로 로컬 상태 업데이트는 하지 않습니다.
  Future<Reservation> createReservation(Reservation reservation) async {
    debugPrint('[ReservationProvider] createReservation 시작');
    debugPrint('[ReservationProvider] reservation.id: ${reservation.id}');
    debugPrint(
      '[ReservationProvider] reservation.userId: ${reservation.userId}',
    );
    debugPrint(
      '[ReservationProvider] reservation.courseId: ${reservation.courseId}',
    );
    debugPrint(
      '[ReservationProvider] reservation.placeId: ${reservation.placeId}',
    );
    debugPrint(
      '[ReservationProvider] reservation.dayOfWeek: ${reservation.dayOfWeek}',
    );
    debugPrint(
      '[ReservationProvider] reservation.startTime: ${reservation.startTime}',
    );
    debugPrint(
      '[ReservationProvider] reservation.reservedDate: ${reservation.reservedDate}',
    );
    debugPrint(
      '[ReservationProvider] reservation.reservedAt: ${reservation.reservedAt}',
    );

    final key = _reservationKey(reservation);
    debugPrint('[ReservationProvider] reservation key: $key');
    if (isOperationInFlightByKey(key)) {
      debugPrint('[ReservationProvider] 이미 처리 중인 예약입니다: $key');
      throw Exception('예약 처리 중입니다. 잠시만 기다려주세요.');
    }
    _createInFlightKeys.add(key);
    debugPrint(
      '[ReservationProvider] 처리 중인 예약 키 추가: $key (총 ${_createInFlightKeys.length}개)',
    );
    _recomputeLoading();
    _error = null;
    notifyListeners();

    try {
      debugPrint(
        '[ReservationProvider] FirestoreService.createReservation 호출 시작',
      );
      final created = await _firestoreService.createReservation(reservation);
      debugPrint('[ReservationProvider] FirestoreService.createReservation 성공');
      debugPrint('[ReservationProvider] 생성된 예약 ID: ${created.id}');

      // 즉시 UI 반영(중복 예약 방지/즉시 내역 반영)용으로 로컬에 낙관적 업데이트
      // 이후 스트림 스냅샷이 들어오면 자연스럽게 동기화됨
      // Stream 업데이트와 중복을 방지하기 위해 이미 존재하는지 확인
      final alreadyExists = _reservations.any((r) => _reservationKey(r) == key);
      debugPrint('[ReservationProvider] 이미 존재하는 예약인지: $alreadyExists');
      if (!alreadyExists) {
        _reservations = _sortUpcomingFirst([..._reservations, created]);
        debugPrint(
          '[ReservationProvider] 로컬 예약 목록에 추가 (총 ${_reservations.length}개)',
        );
        notifyListeners();
      }
      // Stream 구독이 자동으로 최종 상태를 업데이트하므로 여기서는 notifyListeners() 호출 생략 가능
      // 하지만 즉시 UI 반영을 위해 notifyListeners() 호출 (Stream 업데이트와 중복되지만 안전함)
      debugPrint('[ReservationProvider] 예약 생성 완료');
      if (!_opController.isClosed) {
        _opController.add(
          ReservationOperationEvent(
            type: ReservationOperationType.create,
            success: true,
            reservation: created,
          ),
        );
      }
      return created;
    } catch (e, stackTrace) {
      debugPrint('[ReservationProvider] 예약 생성 실패');
      debugPrint('[ReservationProvider] 에러 타입: ${e.runtimeType}');
      debugPrint('[ReservationProvider] 에러 메시지: $e');
      debugPrint('[ReservationProvider] 스택 트레이스: $stackTrace');
      _error = e.toString();
      notifyListeners();
      if (!_opController.isClosed) {
        _opController.add(
          ReservationOperationEvent(
            type: ReservationOperationType.create,
            success: false,
            reservation: reservation,
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }
      rethrow;
    } finally {
      _createInFlightKeys.remove(key);
      debugPrint(
        '[ReservationProvider] 처리 중인 예약 키 제거: $key (남은 ${_createInFlightKeys.length}개)',
      );
      _recomputeLoading();
      notifyListeners();
    }
  }

  /// 예약 취소 (권장: 예약 객체를 넘겨서 in-flight/캘린더 UI 표시까지 가능)
  Future<void> cancelReservation(Reservation reservation) async {
    debugPrint('[ReservationProvider] cancelReservation 시작');
    debugPrint('[ReservationProvider] reservationId: ${reservation.id}');
    debugPrint('[ReservationProvider] placeId: ${reservation.placeId}');

    final key = _reservationKey(reservation);
    if (isOperationInFlightByKey(key)) {
      debugPrint('[ReservationProvider] 이미 처리 중인 예약/취소입니다: $key');
      throw Exception('예약 취소 처리 중입니다. 잠시만 기다려주세요.');
    }

    _cancelInFlightKeys.add(key);
    _recomputeLoading();
    _error = null;
    notifyListeners();

    try {
      // 배치 함수 사용 (개별도 배치로 처리)
      final result = await _firestoreService.batchCancelReservations(
        reservationIds: [reservation.id],
        placeId: reservation.placeId,
      );

      final results = result['results'] as List<dynamic>? ?? [];
      final failedResults = results
          .where((r) => (r as Map)['success'] != true)
          .toList();
      if (failedResults.isNotEmpty) {
        final error =
            (failedResults.first as Map)['error'] as String? ??
            '예약 취소에 실패했습니다.';
        throw Exception(error);
      }

      debugPrint('[ReservationProvider] cancelReservation 성공');
      if (!_opController.isClosed) {
        _opController.add(
          ReservationOperationEvent(
            type: ReservationOperationType.cancel,
            success: true,
            reservation: reservation,
          ),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('[ReservationProvider] cancelReservation 실패');
      debugPrint('[ReservationProvider] 에러 타입: ${e.runtimeType}');
      debugPrint('[ReservationProvider] 에러: $e');
      _error = e.toString();
      notifyListeners();
      if (!_opController.isClosed) {
        _opController.add(
          ReservationOperationEvent(
            type: ReservationOperationType.cancel,
            success: false,
            reservation: reservation,
            error: e,
            stackTrace: stackTrace,
          ),
        );
      }
      rethrow;
    } finally {
      _cancelInFlightKeys.remove(key);
      _recomputeLoading();
      notifyListeners();
    }
  }

  /// 예약 삭제
  ///
  /// Stream 구독이 자동으로 상태를 업데이트하므로 로컬 상태 업데이트는 하지 않습니다.
  Future<void> deleteReservation({
    required String reservationId,
    required String placeId,
  }) async {
    debugPrint('[ReservationProvider] deleteReservation 시작');
    debugPrint('[ReservationProvider] reservationId: $reservationId');
    debugPrint('[ReservationProvider] placeId: $placeId');
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      debugPrint(
        '[ReservationProvider] FirestoreService.deleteReservation 호출 시작',
      );
      await _firestoreService.deleteReservation(
        reservationId: reservationId,
        placeId: placeId,
      );
      debugPrint('[ReservationProvider] FirestoreService.deleteReservation 성공');
      // Stream 구독이 자동으로 _reservations를 업데이트하므로 로컬 업데이트 제거
      // _reservations는 Stream 구독의 listen 콜백에서 자동으로 업데이트됨
    } catch (e) {
      debugPrint('[ReservationProvider] deleteReservation 실패');
      debugPrint('[ReservationProvider] 에러 타입: ${e.runtimeType}');
      debugPrint('[ReservationProvider] 에러: $e');
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
      debugPrint(
        '[ReservationProvider] deleteReservation 종료 (isLoading=false)',
      );
      notifyListeners();
    }
  }

  /// 예약 가져오기
  Reservation? getReservation(String reservationId) {
    try {
      return _reservations.firstWhere((r) => r.id == reservationId);
    } catch (e) {
      return null;
    }
  }

  /// 구독 취소 및 데이터 초기화
  Future<void> clear() async {
    await _reservationSubscription?.cancel();
    _reservationSubscription = null;
    _currentUserId = null;
    _currentPlaceId = null;
    _reservations = [];
    _isLoading = false;
    _error = null;
    notifyListeners();
  }

  /// 리소스 정리 (Provider dispose 시 호출)
  @override
  void dispose() {
    _reservationSubscription?.cancel();
    _opController.close();
    super.dispose();
  }
}
