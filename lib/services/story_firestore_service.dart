import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import '../models/story.dart';
import '../utils/firestore_utils.dart';
import 'storage_service.dart';

/// 스토리 관련 Firestore 작업
class StoryFirestoreService {
  static final StoryFirestoreService _instance = StoryFirestoreService._internal();
  factory StoryFirestoreService() => _instance;
  StoryFirestoreService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// 최신(createdAt desc) 순 정렬. Provider 등에서 사용.
  static List<Story> sortStoriesLatestFirst(List<Story> list) {
    final copy = List<Story>.from(list);
    copy.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return copy;
  }

  Future<List<Story>> getStoriesByPlace(String placeId) async {
    try {
      final snapshot = await _firestore
          .collection('places')
          .doc(placeId)
          .collection('stories')
          .get();

      final stories = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        data['placeId'] = placeId;
        data['createdAt'] =
            FirestoreUtils.timestampToDateTime(data['createdAt']).toIso8601String();
        return Story.fromJson(data);
      }).toList();

      stories.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return stories.take(5).toList();
    } on FirebaseException catch (e) {
      // 권한 없음 등으로 읽기 실패 시 빈 목록 반환 (재시도·스택 트레이스 스팸 방지)
      if (e.code == 'permission-denied' || e.code == 'unauthenticated') {
        debugPrint('[StoryFirestoreService] getStoriesByPlace 읽기 불가 (${e.code}): $placeId');
        return [];
      }
      rethrow;
    } catch (e, stackTrace) {
      debugPrint('[StoryFirestoreService] getStoriesByPlace 에러: $e');
      debugPrint('[StoryFirestoreService] 스택: $stackTrace');
      rethrow;
    }
  }

  Future<Story> createStory(Story story) async {
    final docRef = _firestore
        .collection('places')
        .doc(story.placeId)
        .collection('stories')
        .doc(story.id);
    await docRef.set({
      ...story.toJson(),
      'createdAt': FirestoreUtils.dateTimeToTimestamp(story.createdAt),
    });
    return story;
  }

  Future<Story> updateStory(Story story) async {
    final docRef = _firestore
        .collection('places')
        .doc(story.placeId)
        .collection('stories')
        .doc(story.id);
    await docRef.update({
      ...story.toJson(),
      'createdAt': FirestoreUtils.dateTimeToTimestamp(story.createdAt),
    });
    return story;
  }

  /// 스토리 삭제 시 Firestore 문서 + Storage 이미지 전부 삭제 (예외 케이스 없이 동작)
  Future<void> deleteStory(String placeId, String storyId) async {
    final docRef = _firestore
        .collection('places')
        .doc(placeId)
        .collection('stories')
        .doc(storyId);

    final docSnap = await docRef.get();
    if (docSnap.exists) {
      final data = docSnap.data();
      if (data != null) {
        final imageUrls = data['imageUrls'] as List<dynamic>?;
        final backgroundImageUrl = data['backgroundImageUrl'] as String?;
        final urlsToDelete = <String>[];
        if (imageUrls != null) {
          for (final u in imageUrls) {
            if (u is String && u.isNotEmpty) urlsToDelete.add(u);
          }
        }
        if (backgroundImageUrl != null &&
            backgroundImageUrl.isNotEmpty &&
            !urlsToDelete.contains(backgroundImageUrl)) {
          urlsToDelete.add(backgroundImageUrl);
        }
        if (urlsToDelete.isNotEmpty) {
          StorageService.deleteImagesInBackground(urlsToDelete);
        }
      }
    }

    await docRef.delete();
  }
}
