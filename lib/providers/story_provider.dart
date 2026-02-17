import 'package:flutter/foundation.dart';
import '../models/story.dart';
import '../services/firestore_service.dart';
import '../services/story_firestore_service.dart';
import '../utils/timezone_utils.dart';

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

  void _sortStoriesLatestFirst() {
    _stories = StoryFirestoreService.sortStoriesLatestFirst(_stories);
  }

  /// 스토리 목록 로드 (중복 로드 방지)
  Future<void> loadStories(String placeId) async {
    // 이미 같은 플레이스에 대해 시도했으면 스킵 (성공/실패 무관, 재시도 방지)
    if (_loadedPlaceId == placeId) {
      return;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _stories = await _firestoreService.getStoriesByPlace(placeId);
      _sortStoriesLatestFirst();
      _loadedPlaceId = placeId;
      _error = null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[StoryProvider.loadStories] placeId=$placeId 에러: $e');
      }
      _error = e.toString();
      _stories = [];
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
        createdAt: TimezoneUtils.getSeoulDateTime(),
        imageUrls: imageUrls,
        backgroundImageUrl: backgroundImageUrl,
      );

      final createdStory = await _firestoreService.createStory(story);
      // ✅ 로컬 리스트에 먼저 반영할 때도 최신순 유지:
      // - 추가 직후(리로드 없이도) 가장 앞에 보이도록 prepend 후 정렬
      _stories = [createdStory, ..._stories];
      _sortStoriesLatestFirst();
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
      _sortStoriesLatestFirst();
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
  Future<void> deleteStory(String placeId, String storyId) async {
    _isLoading = true;
    notifyListeners();

    try {
      await _firestoreService.deleteStory(placeId, storyId);
      _stories = _stories.where((s) => s.id != storyId).toList();
      _sortStoriesLatestFirst();
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
