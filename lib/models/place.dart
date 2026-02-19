import 'course.dart';

/// 플레이스 모델 (어드민이 관리하는 장소/시설)
class Place {
  final String id;
  final String name;
  /// 전체 매니저(소유자) UID 목록. 복수 명 지원.
  final List<String> adminIds;
  final String? description;
  final String? greetingText; // 홈 화면 인사말
  final bool hideGreeting; // true면 홈 화면에 환영 메시지 미표시
  final String? imageUrl; // 플레이스 이미지 URL
  final List<Course> courses; // 이 플레이스에서 진행되는 코스들

  /// 호환용: 첫 번째 전체 매니저 ID (adminIds.firstOrNull ?? '')
  String get adminId => adminIds.isNotEmpty ? adminIds.first : '';

  Place({
    required this.id,
    required this.name,
    List<String>? adminIds,
    this.description,
    this.greetingText,
    this.hideGreeting = false,
    this.imageUrl,
    this.courses = const [],
  }) : adminIds = adminIds ?? const [];

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
      'adminIds': adminIds,
      if (description != null) 'description': description,
      if (greetingText != null) 'greetingText': greetingText,
      'hideGreeting': hideGreeting,
      if (imageUrl != null) 'imageUrl': imageUrl,
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
          final placeId = json['id'] as String? ?? '';
          coursesList =
              coursesData
                  .map((c) {
                    try {
                      return Course.fromJson(
                        c as Map<String, dynamic>,
                        placeId: placeId,
                      );
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

    // adminIds 배열만 사용
    List<String> adminIdsList = [];
    if (json['adminIds'] is List) {
      adminIdsList = (json['adminIds'] as List)
          .map((e) => e?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    }

    return Place(
      id: json['id'] as String,
      name: json['name'] as String,
      adminIds: adminIdsList,
      description: json['description'] as String?,
      greetingText: json['greetingText'] as String?,
      hideGreeting: json['hideGreeting'] as bool? ?? false,
      imageUrl: json['imageUrl'] as String?,
      courses: coursesList,
    );
  }

  // 복사본 생성
  Place copyWith({
    String? id,
    String? name,
    List<String>? adminIds,
    String? description,
    String? appBarText,
    String? greetingText,
    bool? hideGreeting,
    String? imageUrl,
    List<Course>? courses,
  }) {
    return Place(
      id: id ?? this.id,
      name: name ?? this.name,
      adminIds: adminIds ?? this.adminIds,
      description: description ?? this.description,
      greetingText: greetingText ?? this.greetingText,
      hideGreeting: hideGreeting ?? this.hideGreeting,
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
