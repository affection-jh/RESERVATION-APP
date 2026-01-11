import 'course.dart';

/// 플레이스 모델 (어드민이 관리하는 장소/시설)
class Place {
  final String id;
  final String name;
  final String adminId; // 어드민 사용자 ID
  final String? description;
  final String? location; // 주소
  final String? appBarText; // 앱바에 표시될 텍스트
  final String? greetingText; // 홈 화면 인사말
  final String? highlightedText; // 형광펜으로 강조할 텍스트
  final int? highlightColorValue; // 형광펜 색상 (ARGB 값)
  final String? imageUrl; // 플레이스 이미지 URL
  final List<Course> courses; // 이 플레이스에서 진행되는 코스들

  Place({
    required this.id,
    required this.name,
    required this.adminId,
    this.description,
    this.location,
    this.appBarText,
    this.greetingText,
    this.highlightedText,
    this.highlightColorValue,
    this.imageUrl,
    this.courses = const [],
  });

  // 특정 코스 찾기
  Course? findCourse(String courseId) {
    try {
      return courses.firstWhere((course) => course.id == courseId);
    } catch (e) {
      return null;
    }
  }

  // 모든 세션 가져오기
  List<CourseSession> getAllSessions() {
    return courses.expand((course) => course.sessions).toList();
  }

  // 특정 요일의 모든 세션 가져오기
  List<CourseSession> getSessionsByDay(int dayOfWeek) {
    return getAllSessions()
        .where((session) => session.dayOfWeek == dayOfWeek)
        .toList();
  }

  // JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'adminId': adminId,
      'description': description,
      'location': location,
      'appBarText': appBarText,
      'greetingText': greetingText,
      'highlightedText': highlightedText,
      'highlightColorValue': highlightColorValue,
      'imageUrl': imageUrl,
      'courses': courses.map((c) => c.toJson()).toList(),
    };
  }

  // JSON에서 생성
  factory Place.fromJson(Map<String, dynamic> json) {
    // courses 필드 안전하게 처리
    List<Course> coursesList = [];
    try {
      final coursesData = json['courses'];
      if (coursesData != null) {
        if (coursesData is List) {
          coursesList = coursesData
              .map((c) {
                try {
                  return Course.fromJson(c as Map<String, dynamic>);
                } catch (e) {
                  print('[Place.fromJson] 코스 파싱 실패: $e');
                  return null;
                }
              })
              .whereType<Course>()
              .toList();
        } else if (coursesData is Map) {
          // Map인 경우 빈 리스트로 처리 (잘못된 데이터 구조)
          print('[Place.fromJson] courses가 Map 형식입니다. List로 변환할 수 없습니다.');
        }
      }
    } catch (e) {
      print('[Place.fromJson] courses 파싱 중 에러: $e');
    }

    return Place(
      id: json['id'] as String,
      name: json['name'] as String,
      adminId: json['adminId'] as String,
      description: json['description'] as String?,
      location: json['location'] as String?,
      appBarText: json['appBarText'] as String?,
      greetingText: json['greetingText'] as String?,
      highlightedText: json['highlightedText'] as String?,
      highlightColorValue: json['highlightColorValue'] as int?,
      imageUrl: json['imageUrl'] as String?,
      courses: coursesList,
    );
  }

  // 복사본 생성
  Place copyWith({
    String? id,
    String? name,
    String? adminId,
    String? description,
    String? location,
    String? appBarText,
    String? greetingText,
    String? highlightedText,
    int? highlightColorValue,
    String? imageUrl,
    List<Course>? courses,
  }) {
    return Place(
      id: id ?? this.id,
      name: name ?? this.name,
      adminId: adminId ?? this.adminId,
      description: description ?? this.description,
      location: location ?? this.location,
      appBarText: appBarText ?? this.appBarText,
      greetingText: greetingText ?? this.greetingText,
      highlightedText: highlightedText ?? this.highlightedText,
      highlightColorValue: highlightColorValue ?? this.highlightColorValue,
      imageUrl: imageUrl ?? this.imageUrl,
      courses: courses ?? this.courses,
    );
  }

  @override
  String toString() {
    return 'Place(id: $id, name: $name, courses: ${courses.length})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Place && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
