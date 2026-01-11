import 'package:flutter/material.dart';
import 'reservation.dart';

/// 유효기간 단위 타입
enum PeriodType {
  weeks, // 주
  days, // 일
  months, // 달
}

/// 코스 모델
///
/// 예시:
/// - 화요일: 11-13시, 15-16시
/// - 목요일: 12-13시, 15-16시
class Course {
  final String id;
  final String name;
  final String description; // 코스 설명
  final List<CourseSession> sessions;
  final int color; // 색상 (ARGB hex 값, 예: 0xFF087044)
  final String? imageUrl; // 코스 이미지 URL
  final int defaultTotalReservations; // 등록당 기본 수업 횟수 (예약 리밋)
  final bool useUniformSettings; // 일괄 적용 모드 여부
  final int? uniformTotalReservations; // 일괄 적용 수업 횟수
  final PeriodType? uniformPeriodType; // 일괄 적용 유효기간 단위
  final int? uniformPeriodValue; // 일괄 적용 유효기간 값

  Course({
    required this.id,
    required this.name,
    required this.description,
    required this.sessions,
    required this.color,
    this.imageUrl,
    this.defaultTotalReservations = 10, // 기본값: 10회
    this.useUniformSettings = false, // 기본값: 일괄 적용 OFF
    this.uniformTotalReservations,
    this.uniformPeriodType,
    this.uniformPeriodValue,
  });

  // Color 객체로 변환
  Color get colorValue => Color(color);

  // 특정 요일의 세션들 가져오기
  List<CourseSession> getSessionsByDay(int dayOfWeek) {
    return sessions.where((session) => session.dayOfWeek == dayOfWeek).toList();
  }

  // 특정 요일의 세션들 가져오기 (요일명으로)
  List<CourseSession> getSessionsByDayName(String dayName) {
    final dayMap = {'월': 1, '화': 2, '수': 3, '목': 4, '금': 5, '토': 6, '일': 7};
    final dayOfWeek = dayMap[dayName];
    if (dayOfWeek == null) return [];
    return getSessionsByDay(dayOfWeek);
  }

  // 모든 요일 목록
  List<int> get availableDays {
    return sessions.map((s) => s.dayOfWeek).toSet().toList()..sort();
  }

  // 요일명 목록
  List<String> get availableDayNames {
    const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
    return availableDays.map((day) => dayNames[day]).toList();
  }

  // 특정 세션 찾기
  CourseSession? findSession(int dayOfWeek, String startTime) {
    try {
      return sessions.firstWhere(
        (session) =>
            session.dayOfWeek == dayOfWeek && session.startTime == startTime,
      );
    } catch (e) {
      return null;
    }
  }

  // JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'sessions': sessions.map((s) => s.toJson()).toList(),
      'color': color,
      'defaultTotalReservations': defaultTotalReservations,
      if (imageUrl != null) 'imageUrl': imageUrl,
      'useUniformSettings': useUniformSettings,
      if (uniformTotalReservations != null)
        'uniformTotalReservations': uniformTotalReservations,
      if (uniformPeriodType != null)
        'uniformPeriodType': uniformPeriodType!.name,
      if (uniformPeriodValue != null) 'uniformPeriodValue': uniformPeriodValue,
    };
  }

  // JSON에서 생성
  factory Course.fromJson(Map<String, dynamic> json) {
    PeriodType? parsePeriodType(String? name) {
      if (name == null) return null;
      switch (name) {
        case 'weeks':
          return PeriodType.weeks;
        case 'days':
          return PeriodType.days;
        case 'months':
          return PeriodType.months;
        default:
          return null;
      }
    }

    return Course(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '', // 기본값: 빈 문자열
      sessions: (json['sessions'] as List)
          .map((s) => CourseSession.fromJson(s as Map<String, dynamic>))
          .toList(),
      color: json['color'] as int? ?? 0xFF087044, // 기본값: primaryGreen
      imageUrl: json['imageUrl'] as String?,
      defaultTotalReservations:
          json['defaultTotalReservations'] as int? ?? 10, // 기본값: 10회
      useUniformSettings: json['useUniformSettings'] as bool? ?? false,
      uniformTotalReservations: json['uniformTotalReservations'] as int?,
      uniformPeriodType: parsePeriodType(json['uniformPeriodType'] as String?),
      uniformPeriodValue: json['uniformPeriodValue'] as int?,
    );
  }

  @override
  String toString() {
    return 'Course(id: $id, name: $name, sessions: ${sessions.length})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Course && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// 코스 세션 모델
///
/// 특정 요일의 특정 시간대 세션
/// 예: 화요일 11시-13시 세션
class CourseSession {
  final int dayOfWeek; // 1=월요일, 2=화요일, ..., 7=일요일
  final String startTime; // "11:00"
  final String endTime; // "13:00"
  final int capacity; // 기본 수용인원
  final Map<DateTime, int> dateCapacityOverrides; // 특정 날짜별 수용인원 오버라이드
  final List<Reservation> reservations; // 예약 내역

  CourseSession({
    required this.dayOfWeek,
    required this.startTime,
    required this.endTime,
    required this.capacity,
    this.dateCapacityOverrides = const {},
    this.reservations = const [],
  });

  // 요일명
  String get dayName {
    const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
    return dayNames[dayOfWeek];
  }

  // 특정 날짜의 수용인원 가져오기 (오버라이드 있으면 그것 사용, 없으면 기본 capacity)
  int getCapacityForDate(DateTime date) {
    // 날짜만 비교하기 위해 시간 제거
    final dateOnly = DateTime(date.year, date.month, date.day);

    // 오버라이드 맵에서 날짜만 비교하여 찾기
    for (final entry in dateCapacityOverrides.entries) {
      final overrideDate = DateTime(
        entry.key.year,
        entry.key.month,
        entry.key.day,
      );
      if (overrideDate == dateOnly) {
        return entry.value;
      }
    }
    return capacity;
  }

  // 특정 날짜의 남은 인원
  int getRemainingCapacityForDate(DateTime date) {
    final dateCapacity = getCapacityForDate(date);
    // 해당 날짜의 예약만 카운트
    final dateReservations = reservations.where((reservation) {
      final resDate = DateTime(
        reservation.reservedAt.year,
        reservation.reservedAt.month,
        reservation.reservedAt.day,
      );
      final targetDate = DateTime(date.year, date.month, date.day);
      return resDate == targetDate;
    }).length;
    return dateCapacity - dateReservations;
  }

  // 남은 인원 (기본 capacity 기준, 날짜 무관)
  int get remainingCapacity => capacity - reservations.length;

  // 예약 가능 여부 (기본 capacity 기준)
  bool get isAvailable => remainingCapacity > 0;

  // 특정 날짜의 예약 가능 여부
  bool isAvailableForDate(DateTime date) {
    return getRemainingCapacityForDate(date) > 0;
  }

  // 예약된 인원 수
  int get reservedCount => reservations.length;

  // 시간 범위 포맷팅
  String get timeRange => '$startTime ~ $endTime';

  // 소요 시간 계산 (분 단위)
  int get durationInMinutes {
    final start = _parseTime(startTime);
    final end = _parseTime(endTime);
    return end.difference(start).inMinutes;
  }

  // 소요 시간 포맷팅 (예: "2시간 30분")
  String get formattedDuration {
    final minutes = durationInMinutes;
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (hours > 0 && mins > 0) {
      return '${hours}시간 ${mins}분';
    } else if (hours > 0) {
      return '${hours}시간';
    } else {
      return '${mins}분';
    }
  }

  // 시간 파싱 헬퍼
  DateTime _parseTime(String time) {
    final parts = time.split(':');
    final hour = int.parse(parts[0]);
    final minute = int.parse(parts[1]);
    return DateTime(2024, 1, 1, hour, minute);
  }

  // 예약 추가
  CourseSession addReservation(Reservation reservation) {
    if (!isAvailable) {
      throw Exception('예약 가능한 인원이 없습니다.');
    }
    return copyWith(reservations: [...reservations, reservation]);
  }

  // 예약 제거
  CourseSession removeReservation(String reservationId) {
    return copyWith(
      reservations: reservations.where((r) => r.id != reservationId).toList(),
    );
  }

  // 특정 날짜의 수용인원 오버라이드 설정
  CourseSession withDateCapacity(DateTime date, int capacity) {
    final dateOnly = DateTime(date.year, date.month, date.day);
    final newOverrides = Map<DateTime, int>.from(dateCapacityOverrides);
    newOverrides[dateOnly] = capacity;
    return copyWith(dateCapacityOverrides: newOverrides);
  }

  // 특정 날짜의 수용인원 오버라이드 제거
  CourseSession removeDateCapacity(DateTime date) {
    final dateOnly = DateTime(date.year, date.month, date.day);
    final newOverrides = Map<DateTime, int>.from(dateCapacityOverrides);
    newOverrides.remove(dateOnly);
    return copyWith(dateCapacityOverrides: newOverrides);
  }

  // 복사본 생성
  CourseSession copyWith({
    int? dayOfWeek,
    String? startTime,
    String? endTime,
    int? capacity,
    Map<DateTime, int>? dateCapacityOverrides,
    List<Reservation>? reservations,
  }) {
    return CourseSession(
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      capacity: capacity ?? this.capacity,
      dateCapacityOverrides:
          dateCapacityOverrides ?? this.dateCapacityOverrides,
      reservations: reservations ?? this.reservations,
    );
  }

  // JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'dayOfWeek': dayOfWeek,
      'startTime': startTime,
      'endTime': endTime,
      'capacity': capacity,
      'reservations': reservations.map((r) => r.toJson()).toList(),
    };
  }

  // JSON에서 생성
  factory CourseSession.fromJson(Map<String, dynamic> json) {
    return CourseSession(
      dayOfWeek: json['dayOfWeek'] as int,
      startTime: json['startTime'] as String,
      endTime: json['endTime'] as String,
      capacity: json['capacity'] as int,
      reservations:
          (json['reservations'] as List?)
              ?.map((r) => Reservation.fromJson(r as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  @override
  String toString() {
    return 'CourseSession(day: $dayName, time: $timeRange, capacity: $capacity/$remainingCapacity)';
  }
}
