import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/reservation.dart';
import '../services/firestore_service.dart';

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
  String? _currentUserId;
  String? _currentPlaceId;

  List<Reservation> get reservations => List.unmodifiable(_reservations);
  bool get isLoading => _isLoading;
  String? get error => _error;

  String _reservationKey(Reservation r) {
    final d = r.reservedDate;
    final dateString =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return '${r.placeId}|${r.courseId}|${r.dayOfWeek}|${r.startTime}|$dateString';
  }

  bool isCreatingReservation(Reservation reservation) {
    return _createInFlightKeys.contains(_reservationKey(reservation));
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
              _reservations = reservations;
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
          _reservations = reservations;
          notifyListeners();
          return reservations;
        });
  }

  /// 예약 생성
  ///
  /// Stream 구독이 자동으로 상태를 업데이트하므로 로컬 상태 업데이트는 하지 않습니다.
  Future<Reservation> createReservation(Reservation reservation) async {
    final key = _reservationKey(reservation);
    if (_createInFlightKeys.contains(key)) {
      throw Exception('예약 처리 중입니다. 잠시만 기다려주세요.');
    }
    _createInFlightKeys.add(key);
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final created = await _firestoreService.createReservation(reservation);
      // 즉시 UI 반영(중복 예약 방지/즉시 내역 반영)용으로 로컬에 낙관적 업데이트
      // 이후 스트림 스냅샷이 들어오면 자연스럽게 동기화됨
      // Stream 업데이트와 중복을 방지하기 위해 이미 존재하는지 확인
      final alreadyExists = _reservations.any((r) => _reservationKey(r) == key);
      if (!alreadyExists) {
        _reservations = [..._reservations, created];
        notifyListeners();
      }
      // Stream 구독이 자동으로 최종 상태를 업데이트하므로 여기서는 notifyListeners() 호출 생략 가능
      // 하지만 즉시 UI 반영을 위해 notifyListeners() 호출 (Stream 업데이트와 중복되지만 안전함)
      return created;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _createInFlightKeys.remove(key);
      _isLoading = false;
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
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _firestoreService.deleteReservation(
        reservationId: reservationId,
        placeId: placeId,
      );
      // Stream 구독이 자동으로 _reservations를 업데이트하므로 로컬 업데이트 제거
      // _reservations는 Stream 구독의 listen 콜백에서 자동으로 업데이트됨
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
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
    super.dispose();
  }
}
