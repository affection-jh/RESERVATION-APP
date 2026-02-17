import 'package:cloud_firestore/cloud_firestore.dart';

/// 특정 날짜의 특정 세션에 대한 예외 처리 (취소/추가/정원)
enum CourseOverrideType { cancel, capacity, add }

/// 비정기 일정·날짜별 정원 통합 오버라이드 모델
///
/// courseOverrides 컬렉션 단일 소스:
/// - cancel: 정기 세션 해당 날짜만 취소
/// - add: 정기 일정에 없는 새 세션 추가
/// - capacity: 해당 날짜 세션의 정원 변경
class CourseOverride {
  final String id;
  final String courseId;
  final String placeId;
  final String date; // "YYYY-MM-DD"
  final String sessionId; // "courseId_dayOfWeek_startTime"
  final CourseOverrideType type;

  final int dayOfWeek; // 1=월요일, 7=일요일 (add/cancel용)
  final String? startTime; // add: 필수, cancel: 정기 세션 식별용
  final String? endTime;
  final int? capacity; // capacity 타입: 오버라이드 정원, add 타입: 추가 세션 정원
  final bool isCancelled; // type=cancel일 때 true
  final String? weekStartDate; // add/cancel 주차 그룹핑용
  final DateTime createdAt;
  final DateTime? updatedAt;

  CourseOverride({
    required this.id,
    required this.courseId,
    required this.placeId,
    required this.date,
    required this.sessionId,
    required this.type,
    this.dayOfWeek = 0,
    this.startTime,
    this.endTime,
    this.capacity,
    this.isCancelled = false,
    this.weekStartDate,
    required this.createdAt,
    this.updatedAt,
  });

  /// 새 세션 추가용
  factory CourseOverride.addSession({
    required String id,
    required String courseId,
    required String placeId,
    required String date,
    required int dayOfWeek,
    required String startTime,
    required String endTime,
    required int capacity,
    required String weekStartDate,
  }) {
    final sessionId = '${courseId}_${dayOfWeek}_$startTime';
    return CourseOverride(
      id: id,
      courseId: courseId,
      placeId: placeId,
      date: date,
      sessionId: sessionId,
      type: CourseOverrideType.add,
      dayOfWeek: dayOfWeek,
      startTime: startTime,
      endTime: endTime,
      capacity: capacity,
      weekStartDate: weekStartDate,
      createdAt: DateTime.now(),
    );
  }

  /// 정기 세션 취소용
  factory CourseOverride.cancelSession({
    required String id,
    required String courseId,
    required String placeId,
    required String date,
    required int dayOfWeek,
    required String startTime,
    required String weekStartDate,
  }) {
    final sessionId = '${courseId}_${dayOfWeek}_$startTime';
    return CourseOverride(
      id: id,
      courseId: courseId,
      placeId: placeId,
      date: date,
      sessionId: sessionId,
      type: CourseOverrideType.cancel,
      dayOfWeek: dayOfWeek,
      startTime: startTime,
      isCancelled: true,
      weekStartDate: weekStartDate,
      createdAt: DateTime.now(),
    );
  }

  /// 날짜별 정원 변경용 (문서 ID: sessionId_date, _cap 없음)
  factory CourseOverride.capacityOverride({
    required String placeId,
    required String sessionId,
    required String date,
    required int capacity,
    String? courseId,
  }) {
    final derivedCourseId = courseId ?? _courseIdFromSessionId(sessionId);
    final id = '${sessionId}_$date';
    return CourseOverride(
      id: id,
      courseId: derivedCourseId,
      placeId: placeId,
      date: date,
      sessionId: sessionId,
      type: CourseOverrideType.capacity,
      capacity: capacity,
      createdAt: DateTime.now(),
    );
  }

  static String _courseIdFromSessionId(String sessionId) {
    final parts = sessionId.split('_');
    return parts.length >= 3 ? parts.sublist(0, parts.length - 2).join('_') : '';
  }

  /// 비정기 일정 문서 ID (add용)
  static String overrideDocId(String courseId, String date, String startTime) =>
      '${courseId}_${date}_$startTime';

  /// 정기 취소 override 문서 ID (add와 별도 문서로 add·cancel 동시 유지)
  static String overrideDocIdForCancel(
    String courseId,
    String date,
    String startTime,
  ) =>
      '${courseId}_${date}_${startTime}_cancel';

  bool get isAdd => type == CourseOverrideType.add;
  bool get isCancel => type == CourseOverrideType.cancel;
  bool get isCapacity => type == CourseOverrideType.capacity;

  CourseOverride copyWith({
    String? id,
    String? courseId,
    String? placeId,
    String? date,
    String? sessionId,
    CourseOverrideType? type,
    int? dayOfWeek,
    String? startTime,
    String? endTime,
    int? capacity,
    bool? isCancelled,
    String? weekStartDate,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CourseOverride(
      id: id ?? this.id,
      courseId: courseId ?? this.courseId,
      placeId: placeId ?? this.placeId,
      date: date ?? this.date,
      sessionId: sessionId ?? this.sessionId,
      type: type ?? this.type,
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      capacity: capacity ?? this.capacity,
      isCancelled: isCancelled ?? this.isCancelled,
      weekStartDate: weekStartDate ?? this.weekStartDate,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'courseId': courseId,
      'placeId': placeId,
      'date': date,
      'sessionId': sessionId,
      'type': type.name,
      if (dayOfWeek > 0) 'dayOfWeek': dayOfWeek,
      if (startTime != null) 'startTime': startTime,
      if (endTime != null) 'endTime': endTime,
      if (capacity != null) 'capacity': capacity,
      if (type == CourseOverrideType.cancel) 'isCancelled': isCancelled,
      if (weekStartDate != null) 'weekStartDate': weekStartDate,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
    };
  }

  factory CourseOverride.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String?;
    CourseOverrideType type;
    if (typeStr != null) {
      type = CourseOverrideType.values.firstWhere(
        (e) => e.name == typeStr,
        orElse: () => CourseOverrideType.add,
      );
    } else {
      type = json['isCancelled'] == true
          ? CourseOverrideType.cancel
          : CourseOverrideType.add;
    }

    final dayOfWeek = (json['dayOfWeek'] as num?)?.toInt() ?? 0;
    final startTime = json['startTime'] as String?;
    final courseId = json['courseId'] as String;
    var sessionId = (json['sessionId'] as String?) ??
        (dayOfWeek > 0 && startTime != null
            ? '${courseId}_${dayOfWeek}_$startTime'
            : '');
    if (sessionId.isEmpty && type == CourseOverrideType.capacity) {
      final id = json['id'] as String? ?? '';
      // 문서 ID: sessionId_date (통일) 또는 레거시 sessionId_date_cap
      if (id.endsWith('_cap')) {
        sessionId = id.replaceFirst(RegExp(r'_\d{4}-\d{2}-\d{2}_cap$'), '');
      } else {
        sessionId = id.replaceFirst(RegExp(r'_\d{4}-\d{2}-\d{2}$'), '');
      }
    }

    final createdAtRaw = json['createdAt'];
    final createdAt = createdAtRaw == null
        ? DateTime.now()
        : createdAtRaw is Timestamp
            ? createdAtRaw.toDate()
            : DateTime.tryParse(createdAtRaw.toString()) ?? DateTime.now();

    return CourseOverride(
      id: json['id'] as String,
      courseId: courseId,
      placeId: json['placeId'] as String,
      date: json['date'] as String,
      sessionId: sessionId,
      type: type,
      dayOfWeek: dayOfWeek,
      startTime: startTime,
      endTime: json['endTime'] as String?,
      capacity: (json['capacity'] as num?)?.toInt(),
      isCancelled: json['isCancelled'] as bool? ?? (type == CourseOverrideType.cancel),
      weekStartDate: json['weekStartDate'] as String?,
      createdAt: createdAt,
      updatedAt: json['updatedAt'] != null
          ? (json['updatedAt'] is Timestamp
              ? (json['updatedAt'] as Timestamp).toDate()
              : DateTime.parse(json['updatedAt'] as String))
          : null,
    );
  }

  @override
  String toString() {
    switch (type) {
      case CourseOverrideType.cancel:
        return 'CourseOverride(cancel: $date, sessionId: $sessionId)';
      case CourseOverrideType.capacity:
        return 'CourseOverride(capacity: $sessionId $date -> $capacity)';
      case CourseOverrideType.add:
        return 'CourseOverride(add: $date, $startTime-$endTime, capacity: $capacity)';
    }
  }
}
