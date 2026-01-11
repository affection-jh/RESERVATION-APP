import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/firestore_service.dart';

/// 스토리 모델 (Firestore용)
class Story {
  final String id;
  final String placeId;
  final String title;
  final String content;
  final DateTime createdAt;
  final List<String> imageUrls; // 이미지 URL 리스트
  final String? backgroundImageUrl; // 배경 이미지 URL (선택사항)

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
    // createdAt은 String 또는 Timestamp일 수 있음
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
          : (json['imageUrl'] != null
                ? [json['imageUrl'] as String]
                : []), // 하위 호환성
      backgroundImageUrl: json['backgroundImageUrl'] as String?,
    );
  }
}

/// 스토리 관리 Provider
class StoryProvider with ChangeNotifier {
  List<Story> _stories = [];
  bool _isLoading = false;
  String? _error;
  String? _loadedPlaceId; // 로드된 플레이스 ID 추적
  final FirestoreService _firestoreService = FirestoreService();

  List<Story> get stories => List.unmodifiable(_stories);
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 스토리 목록 로드 (중복 로드 방지)
  Future<void> loadStories(String placeId) async {
    debugPrint('[StoryProvider.loadStories] 시작 - placeId: $placeId');
    debugPrint(
      '[StoryProvider.loadStories] _loadedPlaceId: $_loadedPlaceId, _stories.length: ${_stories.length}',
    );

    // 이미 같은 플레이스의 데이터를 로드했으면 스킵
    if (_loadedPlaceId == placeId && _stories.isNotEmpty) {
      debugPrint('[StoryProvider.loadStories] 이미 로드된 플레이스, 스킵');
      return;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      debugPrint(
        '[StoryProvider.loadStories] FirestoreService.getStoriesByPlace 호출 - placeId: $placeId',
      );
      _stories = await _firestoreService.getStoriesByPlace(placeId);
      debugPrint(
        '[StoryProvider.loadStories] 로드 완료 - 스토리 개수: ${_stories.length}',
      );
      _loadedPlaceId = placeId;
      _error = null;
    } catch (e, stackTrace) {
      debugPrint('[StoryProvider.loadStories] 에러 발생: $e');
      debugPrint('[StoryProvider.loadStories] 스택 트레이스: $stackTrace');
      _error = e.toString();
      _stories = [];
      // 에러가 발생해도 _loadedPlaceId를 설정하여 무한 재시도 방지
      _loadedPlaceId = placeId;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 스토리 생성
  Future<Story> createStory({
    required String placeId,
    required String title,
    required String content,
    List<String> imageUrls = const [],
    String? backgroundImageUrl,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final story = Story(
        id: _generateStoryId(),
        placeId: placeId,
        title: title,
        content: content,
        createdAt: DateTime.now(),
        imageUrls: imageUrls,
        backgroundImageUrl: backgroundImageUrl,
      );

      final createdStory = await _firestoreService.createStory(story);
      _stories = [..._stories, createdStory];
      _error = null;
      notifyListeners();
      return createdStory;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 스토리 업데이트
  Future<void> updateStory(Story story) async {
    _isLoading = true;
    notifyListeners();

    try {
      final updatedStory = await _firestoreService.updateStory(story);
      final index = _stories.indexWhere((s) => s.id == story.id);
      if (index != -1) {
        _stories[index] = updatedStory;
      }
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 스토리 삭제
  Future<void> deleteStory(String storyId) async {
    _isLoading = true;
    notifyListeners();

    try {
      await _firestoreService.deleteStory(storyId);
      _stories = _stories.where((s) => s.id != storyId).toList();
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 데이터 초기화
  void clear() {
    _stories = [];
    _isLoading = false;
    _error = null;
    _loadedPlaceId = null;
    notifyListeners();
  }

  String _generateStoryId() {
    return 'story_${DateTime.now().millisecondsSinceEpoch}';
  }
}
