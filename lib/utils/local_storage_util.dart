import 'dart:convert';

import 'package:reservation/models/place.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 로컬 저장소 서비스
///
/// 전화번호 등 간단한 데이터 저장에 사용
///
/// SharedPreferences를 사용하여 영구 저장
class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  static const String _keyAdminPhone = 'admin_phone';
  static const String _keyAdminUserId = 'admin_user_id';
  static const String _keyLastEntryMode =
      'last_entry_mode'; // 마지막 접속 모드 (admin/member)
  static const String _keyLastAccessedPlaceId =
      'last_accessed_place_id'; // 관리자용
  static const String _keyUserLastAccessedPlaceId =
      'user_last_accessed_place_id'; // 일반 사용자용
  static const String _keyVerificationId = 'verification_id';
  static const String _keyVerificationPhone = 'verification_phone';
  static const String _keyLastSelectedCourseId = 'last_selected_course_id';
  static const String _keyRequireManualEntrySelection =
      'require_manual_entry_selection';

  // lastSelectedCourse scope
  static const String scopeAdmin = 'admin';
  static const String scopeAdminMemberCourseTab = 'admin_member_course_tab';
  static const String scopeAdminMemberInactiveTab =
      'admin_member_inactive_tab';
  static const String scopeMember = 'member';

  /// 비활성 탭 코스 칩 '전체' 저장용 센티널
  static const String inactiveTabAllSentinel = '__all__';

  static const String _keyAdminMemberLastTab = 'admin_member_last_tab';
  static const String _keyEnrollmentSendChangeNotification =
      'enrollment_send_change_notification';
  static const String _keyReservationAddSendNotification =
      'reservation_add_send_notification';

  String _lastSelectedCourseKey(String placeId, {String? scope}) {
    // legacy: last_selected_course_id_{placeId}
    if (scope == null || scope.isEmpty) {
      return '${_keyLastSelectedCourseId}_$placeId';
    }
    return '${_keyLastSelectedCourseId}_${scope}_$placeId';
  }

  String _adminMemberLastTabKey(String placeId) =>
      '${_keyAdminMemberLastTab}_$placeId';

  /// 관리자 전화번호 저장
  Future<void> saveAdminPhone(String phoneNumber) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAdminPhone, phoneNumber);
  }

  /// 관리자 전화번호 로드
  Future<String?> getAdminPhone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyAdminPhone);
  }

  /// 관리자 User ID 저장
  Future<void> saveAdminUserId(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAdminUserId, userId);
  }

  /// 관리자 User ID 로드
  Future<String?> getAdminUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyAdminUserId);
  }

  /// 최근 접속한 플레이스 ID 저장 (관리자용)
  Future<void> saveLastAccessedPlaceId(String placeId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastAccessedPlaceId, placeId);
  }

  /// 최근 접속한 플레이스 ID 로드 (관리자용)
  Future<String?> getLastAccessedPlaceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLastAccessedPlaceId);
  }

  /// 마지막 접속 모드 저장 (admin/member)
  Future<void> saveLastEntryMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastEntryMode, mode);
  }

  /// 마지막 접속 모드 로드 (admin/member)
  Future<String?> getLastEntryMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLastEntryMode);
  }

  /// 마지막 접속 모드 삭제
  Future<void> clearLastEntryMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyLastEntryMode);
  }

  /// 관리자 정보 모두 삭제 (로그아웃 시)
  Future<void> clearAdminData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAdminPhone);
    await prefs.remove(_keyAdminUserId);
    await prefs.remove(_keyLastAccessedPlaceId);
  }

  /// 인증 ID 저장 (전화번호 인증용)
  Future<void> saveVerificationId(
    String verificationId,
    String phoneNumber,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyVerificationId, verificationId);
    await prefs.setString(_keyVerificationPhone, phoneNumber);
  }

  /// 인증 ID 로드
  Future<String?> getVerificationId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyVerificationId);
  }

  /// 인증 전화번호 로드
  Future<String?> getVerificationPhone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyVerificationPhone);
  }

  /// 인증 정보 삭제
  Future<void> clearVerificationData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyVerificationId);
    await prefs.remove(_keyVerificationPhone);
  }

  /// 일반 사용자 최근 접속한 플레이스 ID 저장
  Future<void> saveUserLastAccessedPlaceId(String placeId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUserLastAccessedPlaceId, placeId);
  }

  /// 일반 사용자 최근 접속한 플레이스 ID 로드
  Future<String?> getUserLastAccessedPlaceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUserLastAccessedPlaceId);
  }

  /// 일반 사용자 정보 삭제 (로그아웃 시)
  Future<void> clearUserData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUserLastAccessedPlaceId);
  }

  /// 마지막 선택한 코스 ID 저장 (플레이스별)
  Future<void> saveLastSelectedCourseId(
    String placeId,
    String courseId, {
    String? scope,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _lastSelectedCourseKey(placeId, scope: scope),
      courseId,
    );
  }

  /// 마지막 선택한 코스 ID 로드 (플레이스별)
  /// [allowLegacyFallback]: false면 scoped 키만 사용 (비활성 탭 등)
  Future<String?> getLastSelectedCourseId(
    String placeId, {
    String? scope,
    bool allowLegacyFallback = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final scopedKey = _lastSelectedCourseKey(placeId, scope: scope);
    final scopedValue = prefs.getString(scopedKey);
    if (scopedValue != null && scopedValue.isNotEmpty) return scopedValue;

    if (!allowLegacyFallback) return null;

    // legacy fallback + migrate
    final legacyKey = _lastSelectedCourseKey(placeId, scope: null);
    final legacyValue = prefs.getString(legacyKey);
    if (legacyValue != null && legacyValue.isNotEmpty) {
      if (scope != null && scope.isNotEmpty) {
        await prefs.setString(scopedKey, legacyValue);
      }
      return legacyValue;
    }

    return null;
  }

  /// 멤버 화면 마지막 탭 저장 (0: 전체, 1: 코스별, 2: 비활성)
  Future<void> saveAdminMemberLastTab(String placeId, int tabIndex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_adminMemberLastTabKey(placeId), tabIndex);
  }

  /// 멤버 화면 마지막 탭 로드
  Future<int?> getAdminMemberLastTab(String placeId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_adminMemberLastTabKey(placeId));
  }

  /// 수강 상세: 변경 알림 보내기 마지막 선택값 저장
  Future<void> saveEnrollmentSendChangeNotification(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnrollmentSendChangeNotification, value);
  }

  /// 수강 상세: 변경 알림 보내기 마지막 선택값 로드 (없으면 null → 호출측 기본 true)
  Future<bool?> getEnrollmentSendChangeNotification() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyEnrollmentSendChangeNotification);
  }

  /// 예약 추가/이동/취소: 알림 보내기 마지막 선택값 저장
  Future<void> saveReservationAddSendNotification(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyReservationAddSendNotification, value);
  }

  /// 예약 추가/이동/취소: 알림 보내기 마지막 선택값 로드 (없으면 null → 호출측 기본 true)
  Future<bool?> getReservationAddSendNotification() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyReservationAddSendNotification);
  }

  /// [saveReservationAddSendNotification] 별칭
  Future<void> saveAdminReservationSendNotification(bool value) =>
      saveReservationAddSendNotification(value);

  /// [getReservationAddSendNotification] 별칭
  Future<bool?> getAdminReservationSendNotification() =>
      getReservationAddSendNotification();

  /// 플레이스별 마지막 선택 코스 ID 삭제
  Future<void> clearLastSelectedCourseId(
    String placeId, {
    String? scope,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastSelectedCourseKey(placeId, scope: scope));
  }

  /// 전화번호 인증 후 "명시적 진입 선택"이 필요한지 여부
  ///
  /// - true: 자동으로 관리자/멤버 홈으로 보내지 말고 Waiting에서 멈춘 뒤
  ///         사용자가 플레이스/역할을 명시적으로 선택하도록 한다.
  /// - false: 기존 자동 로그인/자동 진입 로직을 그대로 허용한다.
  Future<void> setRequireManualEntrySelection(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRequireManualEntrySelection, value);
  }

  Future<bool> getRequireManualEntrySelection() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyRequireManualEntrySelection) ?? false;
  }

  Future<void> clearRequireManualEntrySelection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyRequireManualEntrySelection);
  }

  /// 즐겨찾기한 코스 ID 목록 저장
  static const String _keyFavoriteCourses = 'favorite_courses';

  /// 코스 즐겨찾기 추가/제거
  Future<void> toggleFavoriteCourse(String courseId) async {
    final prefs = await SharedPreferences.getInstance();
    final favorites = await getFavoriteCourses();
    if (favorites.contains(courseId)) {
      favorites.remove(courseId);
    } else {
      favorites.add(courseId);
    }
    await prefs.setStringList(_keyFavoriteCourses, favorites);
  }

  /// 즐겨찾기한 코스 ID 목록 가져오기
  Future<List<String>> getFavoriteCourses() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_keyFavoriteCourses) ?? [];
  }

  /// 코스가 즐겨찾기인지 확인
  Future<bool> isFavoriteCourse(String courseId) async {
    final favorites = await getFavoriteCourses();
    return favorites.contains(courseId);
  }

  // ---------- 방문 기록 (로컬, 추천 대신 사용) ----------
  static const String _keyVisitHistory = 'visit_history_places';
  static const int _maxVisitHistory = 20;

  /// 방문 기록에 플레이스 추가 (최근 방문 순, 중복 시 맨 앞으로)
  Future<void> addPlaceToVisitHistory(Place place) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getVisitHistoryPlaces();
    final filtered = list.where((p) => p.id != place.id).toList();
    final json = place.toJson();
    json['courses'] = []; // 저장 용량 절감
    final updated = [Place.fromJson(json), ...filtered];
    final toSave = updated.take(_maxVisitHistory).toList();
    final encoded = jsonEncode(
      toSave.map((p) {
        final m = p.toJson();
        m['courses'] = [];
        return m;
      }).toList(),
    );
    await prefs.setString(_keyVisitHistory, encoded);
  }

  /// 방문 기록에서 플레이스 제거 (존재하지 않는 플레이스 정리용)
  Future<void> removePlaceFromVisitHistory(String placeId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getVisitHistoryPlaces();
    final filtered = list.where((p) => p.id != placeId).toList();
    if (filtered.length == list.length) return;
    final encoded = jsonEncode(
      filtered.map((p) {
        final m = p.toJson();
        m['courses'] = [];
        return m;
      }).toList(),
    );
    await prefs.setString(_keyVisitHistory, encoded);
  }

  /// 방문 기록 플레이스 목록 로드 (최근 방문 순)
  Future<List<Place>> getVisitHistoryPlaces() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyVisitHistory);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>?;
      if (list == null) return [];
      final places = <Place>[];
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        try {
          places.add(Place.fromJson(item));
        } catch (_) {
          // skip invalid entry
        }
      }
      return places;
    } catch (_) {
      return [];
    }
  }
}
