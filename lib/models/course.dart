import 'package:flutter/material.dart';
import 'course_policy.dart';

/// 유효기간 단위 타입
enum PeriodType {
  weeks,
  days,
  months,
}

/// 코스 모델 (정의 + 운영 정책만 보유, 예약/수용인원 상태는 포함하지 않음)
class Course {
  final String id;
  final String placeId;

  final String name;
  final String description;
  final int color;
  final String? imageUrl;

  final int defaultTotalReservations;
  final PeriodType? defaultPeriodType;
  final int? defaultPeriodValue;

  final List<CourseSession> sessions;
  final CoursePolicy policy;

  final DateTime createdAt;
  final DateTime updatedAt;

  const Course({
    required this.id,
    required this.placeId,
    required this.name,
    required this.description,
    required this.color,
    required this.defaultTotalReservations,
    required this.sessions,
    required this.policy,
    required this.createdAt,
    required this.updatedAt,
    this.imageUrl,
    this.defaultPeriodType,
    this.defaultPeriodValue,
  });

  Color get colorValue => Color(color);

  List<CourseSession> getSessionsByDay(int dayOfWeek) {
    return sessions.where((s) => s.dayOfWeek == dayOfWeek).toList();
  }

  List<CourseSession> getSessionsByDayName(String dayName) {
    const dayMap = {'월': 1, '화': 2, '수': 3, '목': 4, '금': 5, '토': 6, '일': 7};
    final dayOfWeek = dayMap[dayName];
    if (dayOfWeek == null) return [];
    return getSessionsByDay(dayOfWeek);
  }

  List<int> get availableDays {
    return sessions.map((s) => s.dayOfWeek).toSet().toList()..sort();
  }

  List<String> get availableDayNames {
    const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
    return availableDays.map((day) => dayNames[day]).toList();
  }

  CourseSession? findSession(int dayOfWeek, String startTime) {
    try {
      return sessions.firstWhere(
        (s) => s.dayOfWeek == dayOfWeek && s.startTime == startTime,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'sessions': sessions.map((s) => s.toJson()).toList(),
      'color': color,
      'defaultTotalReservations': defaultTotalReservations,
      if (imageUrl != null) 'imageUrl': imageUrl,
      if (defaultPeriodType != null) 'defaultPeriodType': defaultPeriodType!.name,
      if (defaultPeriodValue != null) 'defaultPeriodValue': defaultPeriodValue,
      'policy': policy.toJson(),
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  factory Course.fromJson(Map<String, dynamic> json, {String? placeId}) {
    PeriodType? parsePeriodType(String? name) {
      if (name == null) return null;
      switch (name) {
        case 'weeks': return PeriodType.weeks;
        case 'days': return PeriodType.days;
        case 'months': return PeriodType.months;
        default: return null;
      }
    }

    final policyRaw = json['policy'];
    final policy = CoursePolicy.fromJson(
      policyRaw is Map<String, dynamic> ? policyRaw : null,
    );

    DateTime parseTime(String key) {
      final v = json[key];
      if (v == null) return DateTime.now();
      if (v is String) return DateTime.parse(v).toLocal();
      return DateTime.now();
    }

    return Course(
      id: json['id'] as String,
      placeId: (placeId ?? json['placeId'] as String? ?? ''),
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      sessions: (json['sessions'] as List?)
          ?.map((s) => CourseSession.fromJson(s as Map<String, dynamic>))
          .toList() ?? [],
      color: json['color'] as int? ?? 0xFF087044,
      imageUrl: json['imageUrl'] as String?,
      defaultTotalReservations: json['defaultTotalReservations'] as int? ?? 10,
      defaultPeriodType: parsePeriodType(json['defaultPeriodType'] as String?),
      defaultPeriodValue: json['defaultPeriodValue'] as int?,
      policy: policy,
      createdAt: parseTime('createdAt'),
      updatedAt: parseTime('updatedAt'),
    );
  }

  @override
  String toString() => 'Course(id: $id, name: $name, sessions: ${sessions.length})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Course && other.id == id);

  @override
  int get hashCode => id.hashCode;
}

/// 코스 세션 정의 (상태 없음: reservations, dateCapacityOverrides 제거)
class CourseSession {
  final int dayOfWeek;
  final String startTime;
  final String endTime;
  final int capacity;

  const CourseSession({
    required this.dayOfWeek,
    required this.startTime,
    required this.endTime,
    required this.capacity,
  });

  String get dayName {
    const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
    return dayNames[dayOfWeek];
  }

  String get timeRange => '$startTime ~ $endTime';

  int get durationInMinutes {
    final start = _parseTime(startTime);
    final end = _parseTime(endTime);
    return end.difference(start).inMinutes;
  }

  String get formattedDuration {
    final minutes = durationInMinutes;
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (hours > 0 && mins > 0) return '${hours}시간 ${mins}분';
    if (hours > 0) return '${hours}시간';
    return '${mins}분';
  }

  DateTime _parseTime(String time) {
    final parts = time.split(':');
    return DateTime(2024, 1, 1, int.parse(parts[0]), int.parse(parts[1]));
  }

  Map<String, dynamic> toJson() => {
    'dayOfWeek': dayOfWeek,
    'startTime': startTime,
    'endTime': endTime,
    'capacity': capacity,
  };

  factory CourseSession.fromJson(Map<String, dynamic> json) {
    return CourseSession(
      dayOfWeek: json['dayOfWeek'] as int,
      startTime: json['startTime'] as String,
      endTime: json['endTime'] as String,
      capacity: json['capacity'] as int,
    );
  }

  @override
  String toString() => 'CourseSession(day: $dayName, time: $timeRange, capacity: $capacity)';
}
