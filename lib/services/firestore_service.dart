import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/place.dart';
import '../models/session_reservation.dart';
import '../models/session_reservation_summary.dart';
import '../models/course.dart';
import '../models/course_policy.dart';
import '../models/notification.dart';
import '../models/course_override.dart';
import '../models/story.dart';
import 'place_firestore_service.dart';
import 'course_service.dart';
import 'reservation_service.dart';
import 'notification_firestore_service.dart';
import 'story_firestore_service.dart';

/// Firestore 파사드 서비스
///
/// 도메인별 전용 서비스(Place, Course, Reservation, Notification, Story,
/// CourseOverride, Enrollment)로 위임합니다. 기존 호출부 수정 없이 사용 가능.
class FirestoreService {
  static final FirestoreService _instance = FirestoreService._internal();
  factory FirestoreService() => _instance;
  FirestoreService._internal();

  final PlaceFirestoreService _placeService = PlaceFirestoreService();
  final CourseService _courseService = CourseService();
  final ReservationService _reservationService = ReservationService();
  final NotificationFirestoreService _notificationService =
      NotificationFirestoreService();
  final StoryFirestoreService _storyService = StoryFirestoreService();

  /// Firestore 인스턴스 접근 (auth_service, member_service 등에서 사용)
  FirebaseFirestore get firestore => _placeService.firestore;

  // ==================== Helper Methods ====================

  /// Timestamp를 DateTime으로 변환 (다른 서비스/호출부에서 사용)
  DateTime timestampToDateTime(dynamic timestamp) {
    if (timestamp == null) return DateTime.now();
    if (timestamp is Timestamp) return timestamp.toDate();
    if (timestamp is String) return DateTime.parse(timestamp);
    throw Exception('Invalid timestamp format');
  }

  /// DateTime을 Timestamp로 변환 (다른 서비스/호출부에서 사용)
  Timestamp dateTimeToTimestamp(DateTime dateTime) =>
      Timestamp.fromDate(dateTime);

  // ==================== Places ====================

  Future<Place> createPlace(Place place) => _placeService.createPlace(place);
  Future<Place?> getPlace(String placeId) => _placeService.getPlace(placeId);
  Future<List<String>> getManagedPlaceIdsByAdminId(String adminId) =>
      _placeService.getManagedPlaceIdsByAdminId(adminId);
  Stream<Place?> watchPlace(String placeId) =>
      _placeService.watchPlace(placeId);
  Future<Place> updatePlace(Place place) => _placeService.updatePlace(place);
  Future<void> deletePlace(String placeId) =>
      _placeService.deletePlace(placeId);
  Future<List<Place>> searchPlaces(String query) =>
      _placeService.searchPlaces(query);

  // ==================== Courses ====================

  Future<List<Course>> getCoursesByPlace(String placeId) =>
      _courseService.getCoursesByPlace(placeId);
  Stream<List<Course>> watchCoursesByPlace(String placeId) =>
      _courseService.watchCoursesByPlace(placeId);
  Future<Course> createCourse(String placeId, Course course) =>
      _courseService.createCourse(placeId, course);
  Future<Course> updateCourse(String placeId, Course course) =>
      _courseService.updateCourse(placeId, course);
  Future<void> updateCourseSchedule({
    required String placeId,
    required String courseId,
    required List<CourseSession> sessions,
  }) => _courseService.updateCourseSchedule(
    placeId: placeId,
    courseId: courseId,
    sessions: sessions,
  );
  Future<void> deleteCourse(
    String placeId,
    String courseId, {
    bool cascade = false,
  }) => _courseService.deleteCourse(placeId, courseId, cascade: cascade);

  // ==================== Course Policies ====================

  Future<CoursePolicy> getCoursePolicy({
    required String courseId,
    required String placeId,
  }) => _courseService.getCoursePolicy(courseId: courseId, placeId: placeId);
  Future<void> upsertCoursePolicy({
    required String placeId,
    required String courseId,
    required CoursePolicy policy,
  }) => _courseService.upsertCoursePolicy(
    placeId: placeId,
    courseId: courseId,
    policy: policy,
  );
  Future<bool> hasAnySessionReservationsForCourse(String courseId) =>
      _courseService.hasAnyReservationsForCourse(courseId);

  // ==================== Reservations ====================

  Future<SessionReservation> createReservation(
    SessionReservation reservation, {
    bool force = false,
    bool createOneTimeEnrollment = false,
    String? adminDisplayNameForUser,
  }) =>
      _reservationService.createReservation(
        reservation,
        force: force,
        createOneTimeEnrollment: createOneTimeEnrollment,
        adminDisplayNameForUser: adminDisplayNameForUser,
      );
  Future<Map<String, dynamic>> batchCreateReservations({
    required String placeId,
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime reservedDate,
    required List<Map<String, dynamic>> entries,
    bool force = false,
  }) =>
      _reservationService.batchCreateReservations(
        placeId: placeId,
        courseId: courseId,
        dayOfWeek: dayOfWeek,
        startTime: startTime,
        reservedDate: reservedDate,
        entries: entries,
        force: force,
      );
  Future<void> deleteReservation({
    required String reservationId,
    required String placeId,
  }) => _reservationService.deleteReservation(
    reservationId: reservationId,
    placeId: placeId,
  );
  Future<void> moveReservationWithinCourse({
    required String reservationId,
    required String placeId,
    required int newDayOfWeek,
    required String newStartTime,
    required DateTime newReservedDate,
  }) => _reservationService.moveReservationWithinCourse(
    reservationId: reservationId,
    placeId: placeId,
    newDayOfWeek: newDayOfWeek,
    newStartTime: newStartTime,
    newReservedDate: newReservedDate,
  );
  Stream<List<SessionReservation>> watchUserReservations(
    String userId, {
    required String placeId,
  }) => _reservationService.watchUserReservations(userId, placeId: placeId);
  Stream<List<SessionReservation>> watchSessionReservations({
    required String placeId,
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) => _reservationService.watchSessionReservations(
    placeId: placeId,
    courseId: courseId,
    dayOfWeek: dayOfWeek,
    startTime: startTime,
    date: date,
  );
  Stream<List<SessionReservationSummary>> watchReservationSummaryByCourseAndDateRange({
    required String placeId,
    required String courseId,
    required DateTime startDate,
    required DateTime endDate,
  }) => _reservationService.watchReservationSummaryByCourseAndDateRange(
    placeId: placeId,
    courseId: courseId,
    startDate: startDate,
    endDate: endDate,
  );
  Stream<List<SessionReservation>> watchReservationsByCourseAndDateRange({
    required String placeId,
    required String courseId,
    required DateTime startDate,
    required DateTime endDate,
  }) => _reservationService.watchReservationsByCourseAndDateRange(
    placeId: placeId,
    courseId: courseId,
    startDate: startDate,
    endDate: endDate,
  );
  Future<SessionReservationSummary?> getSessionReservationSummary({
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) => _reservationService.getSessionReservationSummary(
    courseId: courseId,
    dayOfWeek: dayOfWeek,
    startTime: startTime,
    date: date,
  );
  Stream<SessionReservationSummary?> watchSessionReservationSummary({
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) => _reservationService.watchSessionReservationSummary(
    courseId: courseId,
    dayOfWeek: dayOfWeek,
    startTime: startTime,
    date: date,
  );
  Stream<List<SessionReservationSummary>> watchCourseSessionReservations({
    required String courseId,
    String? placeId,
    required DateTime startDate,
    required DateTime endDate,
  }) => _reservationService.watchCourseSessionReservations(
    courseId: courseId,
    placeId: placeId,
    startDate: startDate,
    endDate: endDate,
  );
  Stream<Set<String>> watchReservedSessionIdsForCourse(
    String placeId,
    String courseId, {
    DateTime? startDate,
  }) => _reservationService.watchReservedSessionIdsForCourse(
    placeId,
    courseId,
    startDate: startDate,
  );
  Future<DateTime?> findFirstReservedDateForSession(String sessionId) =>
      _reservationService.findFirstReservedDateForSession(sessionId);
  Future<Map<String, dynamic>> batchMoveReservations({
    required List<String> reservationIds,
    required String placeId,
    required int newDayOfWeek,
    required String newStartTime,
    required DateTime newReservedDate,
  }) => _reservationService.batchMoveReservations(
    reservationIds: reservationIds,
    placeId: placeId,
    newDayOfWeek: newDayOfWeek,
    newStartTime: newStartTime,
    newReservedDate: newReservedDate,
  );
  Future<Map<String, dynamic>> batchCancelReservations({
    required List<String> reservationIds,
    required String placeId,
    bool asAdminAction = false,
  }) => _reservationService.batchCancelReservations(
    reservationIds: reservationIds,
    placeId: placeId,
    asAdminAction: asAdminAction,
  );

  // ==================== Capacity Overrides ====================

  Future<int?> getCapacityOverride(
    String placeId,
    String sessionId,
    String date,
  ) => _courseService.getCapacityOverride(placeId, sessionId, date);
  Future<void> setCapacityOverride({
    required String placeId,
    required String sessionId,
    required String date,
    required int capacity,
  }) => _courseService.setCapacityOverride(
    placeId: placeId,
    sessionId: sessionId,
    date: date,
    capacity: capacity,
  );
  Future<void> deleteCapacityOverride({
    required String placeId,
    required String sessionId,
    required String date,
  }) => _courseService.deleteCapacityOverride(
    placeId: placeId,
    sessionId: sessionId,
    date: date,
  );
  Stream<Map<String, int>> watchDateCapacityOverrides({
    required String placeId,
    required String courseId,
    required DateTime startDate,
    required DateTime endDate,
  }) => _courseService.watchDateCapacityOverrides(
    placeId: placeId,
    courseId: courseId,
    startDate: startDate,
    endDate: endDate,
  );

  // ==================== Course Overrides (비정기 일정) ====================

  Future<List<CourseOverride>> getCourseOverrides({
    required String placeId,
    String? courseId,
    required String weekStartDate,
  }) => _courseService.getCourseOverrides(
    placeId: placeId,
    courseId: courseId,
    weekStartDate: weekStartDate,
  );
  Future<Map<String, dynamic>> upsertCourseOverride({
    required String placeId,
    required String courseId,
    required String date,
    required int dayOfWeek,
    required String weekStartDate,
    String? startTime,
    String? endTime,
    int? capacity,
    bool isCancelled = false,
    String action = 'create',
    String? overrideId,
    bool sendNotification = true,
  }) => _courseService.upsertCourseOverride(
    placeId: placeId,
    courseId: courseId,
    date: date,
    dayOfWeek: dayOfWeek,
    weekStartDate: weekStartDate,
    startTime: startTime,
    endTime: endTime,
    capacity: capacity,
    isCancelled: isCancelled,
    action: action,
    overrideId: overrideId,
    sendNotification: sendNotification,
  );
  Future<CourseOverride> createCourseOverride(CourseOverride override) =>
      _courseService.createCourseOverride(override);
  Future<void> updateCourseOverride(CourseOverride override) =>
      _courseService.updateCourseOverride(override);
  Future<void> deleteCourseOverride(String overrideId) =>
      _courseService.deleteCourseOverride(overrideId);
  Future<List<CourseOverride>> getCourseOverridesByDate({
    required String placeId,
    required String date,
  }) => _courseService.getCourseOverridesByDate(placeId: placeId, date: date);
  Stream<List<CourseOverride>> streamCourseOverrides({
    required String placeId,
    String? courseId,
    required String weekStartDate,
  }) => _courseService.streamCourseOverrides(
    placeId: placeId,
    courseId: courseId,
    weekStartDate: weekStartDate,
  );

  // ==================== Stories ====================

  Future<List<Story>> getStoriesByPlace(String placeId) =>
      _storyService.getStoriesByPlace(placeId);
  Future<Story> createStory(Story story) => _storyService.createStory(story);
  Future<Story> updateStory(Story story) => _storyService.updateStory(story);
  Future<void> deleteStory(String placeId, String storyId) =>
      _storyService.deleteStory(placeId, storyId);

  // ==================== Notifications ====================

  Future<({List<AppNotification> items, Object? nextPageCursor})>
  getUserNotificationsPage(
    String userId, {
    bool isAdmin = false,
    int limit = NotificationFirestoreService.defaultPageSize,
    Object? startAfterCursor,
  }) => _notificationService.getUserNotificationsPage(
    userId,
    isAdmin: isAdmin,
    limit: limit,
    startAfterCursor: startAfterCursor,
  );

  Future<int> getUnreadNotificationCount(
    String userId, {
    bool isAdmin = false,
    String? placeId,
  }) => _notificationService.getUnreadNotificationCount(
    userId,
    isAdmin: isAdmin,
    placeId: placeId,
  );
  Future<AppNotification?> getNotificationById(
    String notificationId,
    String userId,
  ) => _notificationService.getNotificationById(notificationId, userId);
  Future<void> markNotificationAsRead(String notificationId, String userId) =>
      _notificationService.markNotificationAsRead(notificationId, userId);
  Future<void> markAllNotificationsAsRead(
    List<String> notificationIds,
    String userId,
  ) => _notificationService.markAllNotificationsAsRead(notificationIds, userId);
  Future<void> deleteNotification(String notificationId, String userId) =>
      _notificationService.deleteNotification(notificationId, userId);
  Future<void> deleteNotifications(
    List<String> notificationIds,
    String userId,
  ) => _notificationService.deleteNotifications(notificationIds, userId);
  Future<AppNotification> createNotification(AppNotification notification) =>
      _notificationService.createNotification(notification);
}
