import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import '../models/course.dart';
import '../models/course_policy.dart';
import '../models/course_override.dart';
import '../utils/firestore_utils.dart';
import '../utils/timezone_utils.dart';
import 'reservation_service.dart';

/// 코스 + 비정기 일정 + 정원 오버라이드 + 주차 오픈 통합 서비스
class CourseService {
  static final CourseService _instance = CourseService._internal();
  factory CourseService() => _instance;
  CourseService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ReservationService _reservationService = ReservationService();

  // ==================== Courses ====================

  Future<List<Course>> getCoursesByPlace(String placeId) async {
    final placeRef = _firestore.collection('places').doc(placeId);
    final placeDoc = await placeRef.get();
    if (!placeDoc.exists) {
      throw Exception('플레이스를 찾을 수 없습니다.');
    }

    final snapshot = await placeRef.collection('courses').get();
    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Course.fromJson(data, placeId: placeId);
    }).toList();
  }

  Stream<List<Course>> watchCoursesByPlace(String placeId) {
    final placeRef = _firestore.collection('places').doc(placeId);
    return placeRef.collection('courses').snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return Course.fromJson(data, placeId: placeId);
      }).toList();
    });
  }

  Future<Course> createCourse(String placeId, Course course) async {
    final placeRef = _firestore.collection('places').doc(placeId);
    final placeDoc = await placeRef.get();
    if (!placeDoc.exists) {
      throw Exception('플레이스를 찾을 수 없습니다.');
    }

    final docRef = placeRef.collection('courses').doc(course.id);
    final payload = Map<String, dynamic>.from(course.toJson());
    final now = DateTime.now().toUtc().toIso8601String();
    if (!payload.containsKey('createdAt')) payload['createdAt'] = now;
    if (!payload.containsKey('updatedAt')) payload['updatedAt'] = now;
    await docRef.set(payload);
    return course;
  }

  Future<Course> updateCourse(String placeId, Course course) async {
    final docRef = _firestore
        .collection('places')
        .doc(placeId)
        .collection('courses')
        .doc(course.id);
    final doc = await docRef.get();
    if (!doc.exists) {
      throw Exception('코스를 찾을 수 없습니다.');
    }

    await docRef.update(course.toJson());
    await FirestoreUtils.waitForServerAck();
    return course;
  }

  Future<void> updateCourseSchedule({
    required String placeId,
    required String courseId,
    required List<CourseSession> sessions,
  }) async {
    final callable =
        FirebaseFunctions.instance.httpsCallable('updateCourseSchedule');
    await callable.call({
      'placeId': placeId,
      'courseId': courseId,
      'sessions': sessions
          .map((s) => {
                'dayOfWeek': s.dayOfWeek,
                'startTime': s.startTime,
                'endTime': s.endTime,
                'capacity': s.capacity,
              })
          .toList(),
    });
  }

  Future<void> deleteCourse(
    String placeId,
    String courseId, {
    bool cascade = false,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('deleteCourse');
    await callable.call({
      'placeId': placeId,
      'courseId': courseId,
      'cascade': cascade,
    });
  }

  Future<CoursePolicy> getCoursePolicy({
    required String courseId,
    required String placeId,
  }) async {
    final docRef = _firestore
        .collection('places')
        .doc(placeId)
        .collection('courses')
        .doc(courseId);
    final doc = await docRef.get();
    if (!doc.exists) return CoursePolicy.defaultValue;

    final data = doc.data();
    final policyRaw = data?['policy'];
    return CoursePolicy.fromJson(
      policyRaw is Map<String, dynamic> ? policyRaw : null,
    );
  }

  Future<void> upsertCoursePolicy({
    required String placeId,
    required String courseId,
    required CoursePolicy policy,
  }) async {
    final docRef = _firestore
        .collection('places')
        .doc(placeId)
        .collection('courses')
        .doc(courseId);
    final doc = await docRef.get();
    if (!doc.exists) {
      throw Exception('코스를 찾을 수 없습니다.');
    }
    await docRef.update({'policy': policy.toJson()});
    await FirestoreUtils.waitForServerAck();
  }

  Future<bool> hasAnyReservationsForCourse(String courseId) =>
      _reservationService.hasAnyReservationsForCourse(courseId);

  // ==================== Capacity Overrides ====================
  // 비정기 일정(add)과 정원(cap)을 한 문서로: add 문서가 있으면 그 문서에 capacity 저장,
  // 없으면 sessionId_date 문서에 type=capacity로 저장 (id에 _cap 미사용).

  static String? _addDocIdFromSessionId(String sessionId, String date) {
    final parts = sessionId.split('_');
    if (parts.length < 3) return null;
    final courseId = parts.sublist(0, parts.length - 2).join('_');
    final startTime = parts.last;
    return CourseOverride.overrideDocId(courseId, date, startTime);
  }

  Future<int?> getCapacityOverride(
    String placeId,
    String sessionId,
    String date,
  ) async {
    final addDocId = _addDocIdFromSessionId(sessionId, date);
    if (addDocId != null) {
      final addDoc = await _firestore.collection('courseOverrides').doc(addDocId).get();
      if (addDoc.exists) {
        final capRaw = addDoc.data()?['capacity'];
        if (capRaw != null) {
          return capRaw is int ? capRaw : (capRaw is num ? capRaw.toInt() : int.tryParse('$capRaw'));
        }
      }
    }
    final docId = '${sessionId}_$date';
    final doc = await _firestore.collection('courseOverrides').doc(docId).get();
    if (!doc.exists) {
      final legacyId = '${sessionId}_${date}_cap';
      final legacy = await _firestore.collection('courseOverrides').doc(legacyId).get();
      if (!legacy.exists) return null;
      final capRaw = legacy.data()?['capacity'];
      if (capRaw == null) return null;
      return capRaw is int ? capRaw : (capRaw is num ? capRaw.toInt() : int.tryParse('$capRaw'));
    }
    final data = doc.data();
    final capRaw = data?['capacity'];
    if (capRaw == null) return null;
    return capRaw is int ? capRaw : (capRaw is num ? capRaw.toInt() : int.tryParse('$capRaw'));
  }

  Future<void> setCapacityOverride({
    required String placeId,
    required String sessionId,
    required String date,
    required int capacity,
  }) async {
    final addDocId = _addDocIdFromSessionId(sessionId, date);
    if (addDocId != null) {
      final addDoc = await _firestore.collection('courseOverrides').doc(addDocId).get();
      if (addDoc.exists) {
        await _firestore.collection('courseOverrides').doc(addDocId).update({
          'capacity': capacity,
          'updatedAt': FirestoreUtils.dateTimeToTimestamp(DateTime.now()),
        });
        return;
      }
    }
    final override = CourseOverride.capacityOverride(
      placeId: placeId,
      sessionId: sessionId,
      date: date,
      capacity: capacity,
    );
    // weekStartDate 포함 시 streamCourseOverrides(weekStartDate)에 포함되어 캘린더 실시간 반영
    final weekStartDate = _weekStartDateFromDateString(date);
    final docRef = _firestore.collection('courseOverrides').doc(override.id);
    await docRef.set({
      ...override.toJson(),
      if (weekStartDate != null) 'weekStartDate': weekStartDate,
      'updatedAt': FirestoreUtils.dateTimeToTimestamp(DateTime.now()),
    }, SetOptions(merge: true));
  }

  /// "YYYY-MM-DD" → 해당 주 월요일 "YYYY-MM-DD" (streamCourseOverrides 쿼리용)
  static String? _weekStartDateFromDateString(String date) {
    final parts = date.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    final dt = DateTime(y, m, d);
    final daysFromMonday = dt.weekday - DateTime.monday;
    final monday = dt.subtract(Duration(days: daysFromMonday));
    return '${monday.year}-${monday.month.toString().padLeft(2, '0')}-${monday.day.toString().padLeft(2, '0')}';
  }

  Future<void> deleteCapacityOverride({
    required String placeId,
    required String sessionId,
    required String date,
  }) async {
    final docId = '${sessionId}_$date';
    await _firestore.collection('courseOverrides').doc(docId).delete();
    final legacyId = '${sessionId}_${date}_cap';
    await _firestore.collection('courseOverrides').doc(legacyId).delete();
  }

  /// 정원 오버라이드: type=capacity 문서 + type=add 문서의 capacity 모두 포함 (한 문서 통일)
  Stream<Map<String, int>> watchDateCapacityOverrides({
    required String placeId,
    required String courseId,
    required DateTime startDate,
    required DateTime endDate,
  }) {
    final startDateString = FirestoreUtils.formatDate(startDate);
    final endDateString = FirestoreUtils.formatDate(endDate);

    return _firestore
        .collection('courseOverrides')
        .where('placeId', isEqualTo: placeId)
        .where('courseId', isEqualTo: courseId)
        .where('date', isGreaterThanOrEqualTo: startDateString)
        .where('date', isLessThanOrEqualTo: endDateString)
        .orderBy('date')
        .snapshots()
        .map((snapshot) {
          final overrides = <String, int>{};
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final capRaw = data['capacity'];
            if (capRaw == null) continue;
            final int? capacity =
                capRaw is int
                    ? capRaw
                    : (capRaw is num
                        ? capRaw.toInt()
                        : int.tryParse('$capRaw'));
            if (capacity == null) continue;
            final sessionId = data['sessionId'] as String?;
            final date = data['date'] as String?;
            if (sessionId != null && date != null) {
              overrides['${sessionId}_$date'] = capacity;
            }
          }
          return overrides;
        });
  }

  // ==================== Course Overrides (비정기 일정) ====================

  Future<List<CourseOverride>> getCourseOverrides({
    required String placeId,
    String? courseId,
    required String weekStartDate,
  }) async {
    try {
      Query query = _firestore
          .collection('courseOverrides')
          .where('placeId', isEqualTo: placeId)
          .where('weekStartDate', isEqualTo: weekStartDate);

      if (courseId != null) {
        query = query.where('courseId', isEqualTo: courseId);
      }

      final snapshot = await query.get();
      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return CourseOverride.fromJson(data);
      }).toList();
    } catch (e) {
      debugPrint('[CourseService] getCourseOverrides error: $e');
      return [];
    }
  }

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
  }) async {
    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('upsertCourseOverride');
      final result = await callable.call({
        'placeId': placeId,
        'courseId': courseId,
        'date': date,
        'dayOfWeek': dayOfWeek,
        'startTime': startTime,
        'endTime': endTime,
        'capacity': capacity,
        'isCancelled': isCancelled,
        'weekStartDate': weekStartDate,
        'action': action,
        'overrideId': overrideId,
        'sendNotification': sendNotification,
      });

      return {
        'success': result.data['success'] == true,
        'overrideId': result.data['overrideId'],
      };
    } catch (e) {
      debugPrint('[CourseService] upsertCourseOverride error: $e');
      rethrow;
    }
  }

  Future<CourseOverride> createCourseOverride(CourseOverride override) async {
    final docRef = _firestore.collection('courseOverrides').doc(override.id);
    await docRef.set(override.toJson());
    return override;
  }

  Future<void> updateCourseOverride(CourseOverride override) async {
    final docRef = _firestore.collection('courseOverrides').doc(override.id);
    await docRef.update({
      ...override.toJson(),
      'updatedAt': FirestoreUtils.dateTimeToTimestamp(DateTime.now()),
    });
  }

  Future<void> deleteCourseOverride(String overrideId) async {
    await _firestore.collection('courseOverrides').doc(overrideId).delete();
  }

  Future<List<CourseOverride>> getCourseOverridesByDate({
    required String placeId,
    required String date,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('courseOverrides')
          .where('placeId', isEqualTo: placeId)
          .where('date', isEqualTo: date)
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return CourseOverride.fromJson(data);
      }).toList();
    } catch (e) {
      debugPrint('[CourseService] getCourseOverridesByDate error: $e');
      return [];
    }
  }

  Stream<List<CourseOverride>> streamCourseOverrides({
    required String placeId,
    String? courseId,
    required String weekStartDate,
  }) {
    Query query = _firestore
        .collection('courseOverrides')
        .where('placeId', isEqualTo: placeId)
        .where('weekStartDate', isEqualTo: weekStartDate);

    if (courseId != null) {
      query = query.where('courseId', isEqualTo: courseId);
    }

    return query.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return CourseOverride.fromJson(data);
      }).toList();
    });
  }

  // ==================== Booking Week Opens ====================

  Future<void> setBookingWeekOpened({
    required String placeId,
    required String courseId,
    required String weekStartDate,
  }) async {
    try {
      final docId = '${placeId}_${courseId}_$weekStartDate';
      await _firestore.collection('bookingWeekOpens').doc(docId).set({
        'placeId': placeId,
        'courseId': courseId,
        'weekStartDate': weekStartDate,
        'openedAt': FirestoreUtils.dateTimeToTimestamp(
          TimezoneUtils.getSeoulDateTime(),
        ),
      }, SetOptions(merge: true));
      await FirestoreUtils.waitForServerAck();
    } catch (e) {
      debugPrint('[CourseService] setBookingWeekOpened error: $e');
      rethrow;
    }
  }

  /// 미리 예약 열기를 취소(닫기) — 해당 주의 bookingWeekOpens 문서 삭제
  Future<void> clearBookingWeekOpened({
    required String placeId,
    required String courseId,
    required String weekStartDate,
  }) async {
    try {
      final docId = '${placeId}_${courseId}_$weekStartDate';
      await _firestore.collection('bookingWeekOpens').doc(docId).delete();
      await FirestoreUtils.waitForServerAck();
    } catch (e) {
      debugPrint('[CourseService] clearBookingWeekOpened error: $e');
      rethrow;
    }
  }

  Future<bool> isBookingWeekOpened({
    required String placeId,
    required String courseId,
    required String weekStartDate,
  }) async {
    try {
      final docId = '${placeId}_${courseId}_$weekStartDate';
      final doc =
          await _firestore.collection('bookingWeekOpens').doc(docId).get();
      return doc.exists;
    } catch (e) {
      debugPrint('[CourseService] isBookingWeekOpened error: $e');
      return false;
    }
  }

  Stream<Set<String>> streamBookingWeekOpens({
    required String placeId,
    required String courseId,
  }) {
    return _firestore
        .collection('bookingWeekOpens')
        .where('placeId', isEqualTo: placeId)
        .where('courseId', isEqualTo: courseId)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => doc.data()['weekStartDate'] as String? ?? '')
              .where((date) => date.isNotEmpty)
              .toSet();
        });
  }
}
