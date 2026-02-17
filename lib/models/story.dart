import 'package:cloud_firestore/cloud_firestore.dart';

/// 스토리 추가/편집 폼용 DTO (id·placeId·createdAt 없음)
class StoryData {
  const StoryData({
    required this.title,
    required this.content,
    required this.date,
    this.imageUrls = const [],
    this.backgroundImageUrl,
  });

  final String title;
  final String content;
  final String date;
  final List<String> imageUrls;
  final String? backgroundImageUrl;
}

/// 스토리 모델 (Firestore용)
class Story {
  final String id;
  final String placeId;
  final String title;
  final String content;
  final DateTime createdAt;
  final List<String> imageUrls;
  final String? backgroundImageUrl;

  Story({
    required this.id,
    required this.placeId,
    required this.title,
    required this.content,
    required this.createdAt,
    this.imageUrls = const [],
    this.backgroundImageUrl,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'placeId': placeId,
      'title': title,
      'content': content,
      'createdAt': Timestamp.fromDate(createdAt),
      'imageUrls': imageUrls,
      'backgroundImageUrl': backgroundImageUrl,
    };
  }

  factory Story.fromJson(Map<String, dynamic> json) {
    DateTime createdAt;
    if (json['createdAt'] is String) {
      createdAt = DateTime.parse(json['createdAt'] as String);
    } else if (json['createdAt'] is Timestamp) {
      createdAt = (json['createdAt'] as Timestamp).toDate();
    } else {
      createdAt = DateTime.now();
    }

    return Story(
      id: json['id'] as String,
      placeId: json['placeId'] as String,
      title: json['title'] as String,
      content: json['content'] as String,
      createdAt: createdAt,
      imageUrls: json['imageUrls'] != null
          ? List<String>.from(json['imageUrls'] as List)
          : (json['imageUrl'] != null ? [json['imageUrl'] as String] : []),
      backgroundImageUrl: json['backgroundImageUrl'] as String?,
    );
  }

  Story copyWith({
    String? id,
    String? placeId,
    String? title,
    String? content,
    DateTime? createdAt,
    List<String>? imageUrls,
    String? backgroundImageUrl,
  }) {
    return Story(
      id: id ?? this.id,
      placeId: placeId ?? this.placeId,
      title: title ?? this.title,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      imageUrls: imageUrls ?? this.imageUrls,
      backgroundImageUrl: backgroundImageUrl ?? this.backgroundImageUrl,
    );
  }
}
