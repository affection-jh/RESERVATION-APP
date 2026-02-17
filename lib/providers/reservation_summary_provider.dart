import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../models/session_reservation_summary.dart';
import '../models/course_override.dart';
import '../services/firestore_service.dart';

/// [세션별 예약 집계] 전용 Provider — 캘린더/스케줄용 "N/M명" 표시
///
/// 【DB 구조】
/// - reservationSummary (글로벌): (sessionId, date)별 reservedCount 집계 → N/M용
/// - reservations (글로벌): 개별 예약 문서 → 예약자 목록(누가) 필요 시 watchSessionReservations로 on-demand
/// - courseOverrides (글로벌): add / cancel / capacity
///
/// 【데이터 흐름】
/// 1. place + course + course_override → updateOverridesForWeek → overridesByDate + 정원 맵
/// 2. 캘린더에서 코스+오버라이드로 주차 슬롯 계산 → updateSessionSlots(weekStartDate, slots)
/// 3. setContext 시 reservationSummary 실시간 구독 → (sessionId, date)별 N 집계 후 슬롯과 병합해 N/M 표시
///
/// 【구독】 setContext 시 reservationSummary만 구독. 예약자 목록은 watchSessionReservations로 on-demand.
/// 【구독 해제】 clear() / dispose() 시 _reservationsSub cancel.
class ReservationSummaryProvider with ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();

  static const Duration _loadingTimeoutDuration = Duration(seconds: 10);

  String? _placeId;
  String? _courseId;
  DateTime? _startDate;
  DateTime? _endDate;
  String? _weekStartDate;

  final Map<String, SessionReservationSummary> _sessionReservationsByKey = {};

  /// 코스+오버라이드로 계산한 주차 슬롯 (reservedCount=0). updateSessionSlots로 채움.
  final Map<String, SessionReservationSummary> _sessionSlotsByKey = {};

  /// reservations 스트림에서 집계한 (sessionId_date) → 예약 인원 수
  final Map<String, int> _reservedCountByKey = {};

  /// sessionId_date → 정원 (courseOverride type=capacity / type=add 에서만 파생)
  final Map<String, int> _capacityOverridesByKey = {};
  final Map<String, List<CourseOverride>> _overridesByDate = {};

  StreamSubscription<Map<String, int>>? _reservationsSub;
  Timer? _loadingTimeout;
  Timer? _notifyDebounceTimer;
  Map<String, int>? _pendingReservedCounts;
  /// 배치 추가/삭제/이동 시 연속 emit 대비 디바운스
  static const _notifyDebounceDuration = Duration(milliseconds: 350);

  bool _isLoading = true;
  bool _reservationsLoaded = false;
  bool _sessionSlotsLoaded = false;
  String? _error;

  String? get placeId => _placeId;
  String? get courseId => _courseId;
  DateTime? get startDate => _startDate;
  DateTime? get endDate => _endDate;
  String? get weekStartDate => _weekStartDate;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// (sessionId_date) → SessionReservationSummary
  Map<String, SessionReservationSummary> get sessionReservationsByKey =>
      Map.unmodifiable(_sessionReservationsByKey);

  /// (sessionId_date) → capacity override
  Map<String, int> get capacityOverridesByKey =>
      Map.unmodifiable(_capacityOverridesByKey);

  /// date(YYYY-MM-DD) → CourseOverride 리스트 (add/cancel)
  Map<String, List<CourseOverride>> get overridesByDate =>
      Map.unmodifiable(_overridesByDate);

  /// placeId, courseId, 날짜 범위 설정 시 구독 시작.
  /// Admin/User 모두 reservationSummary만 구독 (N/M용). 예약자 목록(누가)은 watchSessionReservations로 on-demand.
  void setContext({
    required String? placeId,
    required String? courseId,
    required DateTime? startDate,
    required DateTime? endDate,
    required String? weekStartDate,
  }) {
    // 동일 컨텍스트(완전 동일)면 아무것도 하지 않음
    if (_placeId == placeId &&
        _courseId == courseId &&
        _startDate == startDate &&
        _endDate == endDate &&
        _weekStartDate == weekStartDate) {
      return;
    }

    final sameCourseScope = _placeId == placeId && _courseId == courseId;
    final hasExistingRange = _startDate != null && _endDate != null;
    final hasNextRange = startDate != null && endDate != null;

    // ✅ 중앙 Provider가 스트림 구독을 책임진다는 전제:
    // - 같은 placeId/courseId에서는 "좁은 범위 요청"으로 기존 구독/캐시를 깨지 않음 (subset이면 무시)
    // - 더 넓은 범위 요청일 때만 union 범위로 재구독 (확장만 허용)
    if (sameCourseScope && hasExistingRange && hasNextRange) {
      final existingStart = _startDate!;
      final existingEnd = _endDate!;
      final nextStart = startDate;
      final nextEnd = endDate;

      final isSubset =
          (nextStart.isAtSameMomentAs(existingStart) ||
              nextStart.isAfter(existingStart)) &&
          (nextEnd.isAtSameMomentAs(existingEnd) || nextEnd.isBefore(existingEnd));
      if (isSubset) {
        // weekStartDate는 슬롯 계산용 힌트이므로 비어있으면 유지, 있으면 보조적으로만 업데이트
        _weekStartDate ??= weekStartDate;
        return;
      }
    }

    // 확장(또는 place/course 변경)인 경우에만 내부 컨텍스트 갱신
    DateTime? nextStartDate = startDate;
    DateTime? nextEndDate = endDate;
    if (sameCourseScope && hasExistingRange && hasNextRange) {
      // union 범위로 확장
      final existingStart = _startDate!;
      final existingEnd = _endDate!;
      final nextStart = startDate;
      final nextEnd = endDate;
      nextStartDate =
          nextStart.isBefore(existingStart) ? nextStart : existingStart;
      nextEndDate = nextEnd.isAfter(existingEnd) ? nextEnd : existingEnd;
    }

    _placeId = placeId;
    _courseId = courseId;
    _startDate = nextStartDate;
    _endDate = nextEndDate;
    _weekStartDate = weekStartDate ?? _weekStartDate;

    _loadingTimeout?.cancel();
    _loadingTimeout = null;
    _notifyDebounceTimer?.cancel();
    _pendingReservedCounts = null;
    _reservationsSub?.cancel();

    if (placeId == null ||
        placeId.isEmpty ||
        courseId == null ||
        courseId.isEmpty ||
        _startDate == null ||
        _endDate == null ||
        weekStartDate == null ||
        weekStartDate.isEmpty) {
      debugPrint(
        '[ReservationSummaryProvider] setContext 스킵 (필수 인자 없음) placeId=$placeId courseId=$courseId',
      );
      _sessionReservationsByKey.clear();
      _sessionSlotsByKey.clear();
      _reservedCountByKey.clear();
      _capacityOverridesByKey.clear();
      _overridesByDate.clear();
      _reservationsLoaded = false;
      _sessionSlotsLoaded = false;
      _isLoading = false;
      _error = null;
      notifyListeners();
      return;
    }

    final courseOrPlaceChanged = !sameCourseScope;
    if (courseOrPlaceChanged) {
      // place/course가 바뀌면 전체 리셋이 맞음
      _sessionReservationsByKey.clear();
      _sessionSlotsByKey.clear();
      _reservedCountByKey.clear();
      _capacityOverridesByKey.clear();
      _overridesByDate.clear();
      _reservationsLoaded = false;
      _sessionSlotsLoaded = false;
      _error = null;
      _isLoading = true;
      notifyListeners();
    } else {
      // 같은 place/course에서 "확장"일 때는 기존 캐시를 유지하고 스트림만 union 범위로 갱신
      _error = null;
    }

    debugPrint(
      '[ReservationSummaryProvider] setContext 구독 시작 placeId=$placeId courseId=$courseId '
      'start=$_startDate end=$_endDate weekStart=$weekStartDate',
    );

    // 무한 로딩 방지: 일정 시간 내 스트림이 emit하지 않으면 로딩 해제
    _loadingTimeout = Timer(_loadingTimeoutDuration, () {
      if (_reservationsLoaded && _sessionSlotsLoaded) return;
      debugPrint(
        '[ReservationSummaryProvider] 로딩 타임아웃(${_loadingTimeoutDuration.inSeconds}초) → 로딩 해제',
      );
      _reservationsLoaded = true;
      _sessionSlotsLoaded = true;
      _recomputeLoading();
      notifyListeners();
    });

    // 1) courseOverrides는 updateOverridesForWeek로 전달. 슬롯은 updateSessionSlots로 전달.
    // 2) N/M 집계 구독 (Admin/User 모두 reservationSummary만 사용)
    final stream = _firestoreService
        .watchReservationSummaryByCourseAndDateRange(
          placeId: placeId,
          courseId: courseId,
          startDate: _startDate!,
          endDate: _endDate!,
        )
        .map((summaries) => _summariesToCounts(summaries));

    _reservationsSub = stream.listen(
      (counts) {
        _loadingTimeout?.cancel();
        _loadingTimeout = null;
        _pendingReservedCounts = Map.from(counts);
        _error = null;
        _notifyDebounceTimer?.cancel();
        _notifyDebounceTimer = Timer(_notifyDebounceDuration, () {
          if (_pendingReservedCounts == null) return;
          _reservedCountByKey.clear();
          _reservedCountByKey.addAll(_pendingReservedCounts!);
          _pendingReservedCounts = null;
          _reservationsLoaded = true; // 병합 완료 후에만 true (디바운스 동안 isLoading 유지)
          debugPrint(
            '[ReservationSummaryProvider] reservationSummary emit → ${_reservedCountByKey.length} 세션키',
          );
          _mergeSlotsWithReservedCounts();
          _recomputeLoading();
          notifyListeners();
        });
      },
      onError: (e) {
        _loadingTimeout?.cancel();
        _loadingTimeout = null;
        debugPrint('[ReservationSummaryProvider] stream error: $e');
        _reservedCountByKey.clear();
        _mergeSlotsWithReservedCounts();
        _reservationsLoaded = true;
        _error = e.toString();
        _recomputeLoading();
        Future.microtask(() {
          if (_placeId != null) notifyListeners();
        });
      },
    );
  }

  /// reservationSummary → (sessionId_date) → count
  Map<String, int> _summariesToCounts(
    List<SessionReservationSummary> summaries,
  ) {
    final counts = <String, int>{};
    for (final s in summaries) {
      final key = '${s.sessionId}_${s.date}';
      counts[key] = s.reservedCount;
    }
    return counts;
  }

  void _mergeSlotsWithReservedCounts() {
    _sessionReservationsByKey.clear();
    for (final e in _sessionSlotsByKey.entries) {
      final key = e.key;
      final slot = e.value;
      final count = _reservedCountByKey[key] ?? 0;
      final capacity = _capacityOverridesByKey[key] ?? slot.capacity;
      _sessionReservationsByKey[key] = slot.copyWith(
        reservedCount: count,
        capacity: capacity,
      );
    }
  }

  void _recomputeLoading() {
    _isLoading = !(_reservationsLoaded && _sessionSlotsLoaded);
  }

  /// CourseProvider.getOverridesForWeek(weekStartDate) 결과를 전달. courseOverride 단일 소스에서 overridesByDate + 정원 맵 파생.
  /// 여러 주차 병합 지원 (캘린더 전체 범위 한 번에 로드 시).
  void updateOverridesForWeek(
    String weekStartDate,
    List<CourseOverride> overrides,
  ) {
    if (weekStartDate.isEmpty) return;
    _weekStartDate ??= weekStartDate;
    final nextByDate = <String, List<CourseOverride>>{};
    for (final o in overrides) {
      nextByDate.putIfAbsent(o.date, () => <CourseOverride>[]).add(o);
    }
    // 정원: type==capacity 또는 type==add(비정기 세션) 인 문서의 capacity로 파생 (별도 구독 없음)
    final nextCapacityByKey = <String, int>{};
    for (final o in overrides) {
      if (o.capacity == null) continue;
      if (o.type == CourseOverrideType.capacity ||
          o.type == CourseOverrideType.add) {
        nextCapacityByKey['${o.sessionId}_${o.date}'] = o.capacity!;
      }
    }
    final same =
        nextByDate.entries.every((e) {
          final existing = _overridesByDate[e.key] ?? [];
          if (existing.length != e.value.length) return false;
          return e.value.every((o) => existing.any((x) => x.id == o.id));
        }) &&
        nextCapacityByKey.entries.every(
          (e) => _capacityOverridesByKey[e.key] == e.value,
        );
    if (same) return;
    _overridesByDate.addAll(nextByDate);
    _capacityOverridesByKey.addAll(nextCapacityByKey);
    _mergeSlotsWithReservedCounts();
    _recomputeLoading();
    notifyListeners();
  }

  /// 캘린더에서 코스+오버라이드로 계산한 주차 슬롯 전달. reservedCount=0, capacity는 슬롯/오버라이드 기준.
  /// 여러 주차 병합 지원 (캘린더 전체 범위 한 번에 로드 시).
  void updateSessionSlots(
    String weekStartDate,
    List<SessionReservationSummary> slots,
  ) {
    if (weekStartDate.isEmpty) return;
    _weekStartDate ??= weekStartDate;
    for (final s in slots) {
      final key = '${s.sessionId}_${s.date}';
      _sessionSlotsByKey[key] = s;
    }
    _mergeSlotsWithReservedCounts();
    _sessionSlotsLoaded = true;
    _recomputeLoading();
    notifyListeners();
  }

  /// N/M 표시용 예약 인원 문자열. UI는 이 값만 사용하면 됨.
  String getReservedCountDisplayString(String sessionId, String date) {
    final key = '${sessionId}_$date';
    if (_isLoading) return ' ';
    return '${_reservedCountByKey[key] ?? 0}';
  }

  /// 특정 세션/날짜의 SessionReservationSummary
  SessionReservationSummary? getSessionReservationSummary(
    String sessionId,
    String date,
  ) {
    return _sessionReservationsByKey['${sessionId}_$date'];
  }

  /// 특정 세션/날짜의 capacity (오버라이드 우선)
  int? getCapacityOverride(String sessionId, String date) {
    return _capacityOverridesByKey['${sessionId}_$date'];
  }

  /// 특정 날짜의 총 정원 (capacity override 우선, 없으면 sr.capacity, 없으면 fallback)
  int getTotalCapacity(String sessionId, String date, {required int fallback}) {
    final override = _capacityOverridesByKey['${sessionId}_$date'];
    if (override != null) return override;
    final sr = _sessionReservationsByKey['${sessionId}_$date'];
    return sr?.capacity ?? fallback;
  }

  /// capacity override 설정 후 로컬 반영 (실제 저장은 FirestoreService)
  void updateCapacityLocally(String sessionId, String date, int newCapacity) {
    final key = '${sessionId}_$date';
    _capacityOverridesByKey[key] = newCapacity;
    final sr = _sessionReservationsByKey[key];
    if (sr != null) {
      _sessionReservationsByKey[key] = sr.copyWith(capacity: newCapacity);
    }
    notifyListeners();
  }

  /// 데이터 초기화 (구독 해제). CalendarScreen.dispose(), 플레이스 전환 등에서 호출.
  void clear() {
    debugPrint('[ReservationSummaryProvider] clear() 구독 해제');
    _loadingTimeout?.cancel();
    _loadingTimeout = null;
    _notifyDebounceTimer?.cancel();
    _notifyDebounceTimer = null;
    _pendingReservedCounts = null;
    _placeId = null;
    _courseId = null;
    _startDate = null;
    _endDate = null;
    _weekStartDate = null;
    _reservationsSub?.cancel();
    _reservationsSub = null;
    _sessionReservationsByKey.clear();
    _sessionSlotsByKey.clear();
    _reservedCountByKey.clear();
    _capacityOverridesByKey.clear();
    _overridesByDate.clear();
    _reservationsLoaded = false;
    _sessionSlotsLoaded = false;
    _isLoading = false;
    _error = null;
    // dispose 중에는 위젯 트리가 잠겨 있어 notifyListeners() 시 setState 오류 발생 → 다음 프레임으로 연기
    WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
  }

  @override
  void dispose() {
    _loadingTimeout?.cancel();
    _notifyDebounceTimer?.cancel();
    _reservationsSub?.cancel();
    super.dispose();
  }
}
