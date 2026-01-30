import 'package:cloud_firestore/cloud_firestore.dart';

/// 비정기 일정 오버라이드 모델
///
/// 특정 주에만 적용되는 비정기 일정을 관리합니다.
/// - 추가: 정기 일정에 없는 새로운 세션 추가
/// - 취소: 정기 일정을 해당 주에만 취소
class CourseOverride {
  final String id;
  final String courseId;
  final String placeId;
  final String date; // "YYYY-MM-DD" 형식
  final int dayOfWeek; // 1=월요일, 7=일요일
  final String? startTime; // null이면 정기 일정 취소, 있으면 새 세션 추가
  final String? endTime;
  final int? capacity;
  final bool isCancelled; // 정기 일정 취소 여부
  final String weekStartDate; // 해당 주의 시작 날짜 (월요일) "YYYY-MM-DD"
  final DateTime createdAt;
  final DateTime? updatedAt;

  CourseOverride({
    required this.id,
    required this.courseId,
    required this.placeId,
    required this.date,
    required this.dayOfWeek,
    this.startTime,
    this.endTime,
    this.capacity,
    this.isCancelled = false,
    required this.weekStartDate,
    required this.createdAt,
    this.updatedAt,
  });

  /// 새 세션 추가용 생성자
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
    return CourseOverride(
      id: id,
      courseId: courseId,
      placeId: placeId,
      date: date,
      dayOfWeek: dayOfWeek,
      startTime: startTime,
      endTime: endTime,
      capacity: capacity,
      isCancelled: false,
      weekStartDate: weekStartDate,
      createdAt: DateTime.now(),
    );
  }

  /// 정기 일정 취소용 생성자
  factory CourseOverride.cancelSession({
    required String id,
    required String courseId,
    required String placeId,
    required String date,
    required int dayOfWeek,
    required String weekStartDate,
  }) {
    return CourseOverride(
      id: id,
      courseId: courseId,
      placeId: placeId,
      date: date,
      dayOfWeek: dayOfWeek,
      isCancelled: true,
      weekStartDate: weekStartDate,
      createdAt: DateTime.now(),
    );
  }

  /// 복사본 생성
  CourseOverride copyWith({
    String? id,
    String? courseId,
    String? placeId,
    String? date,
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

  /// JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'courseId': courseId,
      'placeId': placeId,
      'date': date,
      'dayOfWeek': dayOfWeek,
      if (startTime != null) 'startTime': startTime,
      if (endTime != null) 'endTime': endTime,
      if (capacity != null) 'capacity': capacity,
      'isCancelled': isCancelled,
      'weekStartDate': weekStartDate,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
    };
  }

  /// JSON에서 생성
  factory CourseOverride.fromJson(Map<String, dynamic> json) {
    return CourseOverride(
      id: json['id'] as String,
      courseId: json['courseId'] as String,
      placeId: json['placeId'] as String,
      date: json['date'] as String,
      dayOfWeek: json['dayOfWeek'] as int,
      startTime: json['startTime'] as String?,
      endTime: json['endTime'] as String?,
      capacity: json['capacity'] as int?,
      isCancelled: json['isCancelled'] as bool? ?? false,
      weekStartDate: json['weekStartDate'] as String,
      createdAt: (json['createdAt'] as Timestamp).toDate(),
      updatedAt:
          json['updatedAt'] != null
              ? (json['updatedAt'] as Timestamp).toDate()
              : null,
    );
  }

  @override
  String toString() {
    if (isCancelled) {
      return 'CourseOverride(cancel: $date, day: $dayOfWeek)';
    } else {
      return 'CourseOverride(add: $date, $startTime-$endTime, capacity: $capacity)';
    }
  }
}
