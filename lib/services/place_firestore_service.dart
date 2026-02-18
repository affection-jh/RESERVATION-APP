import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import '../models/place.dart';
import '../utils/firestore_utils.dart';

/// 플레이스 관련 Firestore 작업
class PlaceFirestoreService {
  static final PlaceFirestoreService _instance =
      PlaceFirestoreService._internal();
  factory PlaceFirestoreService() => _instance;
  PlaceFirestoreService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Firestore 인스턴스 (FirestoreService 파사드에서 공개용)
  FirebaseFirestore get firestore => _firestore;

  Future<Place> createPlace(Place place) async {
    final docRef = _firestore.collection('places').doc(place.id);
    await docRef.set(place.toJson());
    return place;
  }

  Future<Place?> getPlace(String placeId) async {
    try {
      final doc = await _firestore.collection('places').doc(placeId).get();
      if (!doc.exists) {
        debugPrint('[PlaceFirestoreService] 플레이스 문서가 존재하지 않습니다: $placeId');
        return null;
      }
      return Place.fromJson(doc.data()!);
    } catch (e, stackTrace) {
      debugPrint('[PlaceFirestoreService] 플레이스 로드 실패: $placeId');
      debugPrint('[PlaceFirestoreService] 에러: $e');
      debugPrint('[PlaceFirestoreService] 스택 트레이스: $stackTrace');
      rethrow;
    }
  }

  Future<List<String>> getManagedPlaceIdsByAdminId(String adminId) async {
    final snapshot =
        await _firestore
            .collection('places')
            .where('adminId', isEqualTo: adminId)
            .get();
    return snapshot.docs.map((d) => d.id).toList();
  }

  Stream<Place?> watchPlace(String placeId) {
    return _firestore.collection('places').doc(placeId).snapshots().map((
      snapshot,
    ) {
      if (!snapshot.exists) return null;
      return Place.fromJson(snapshot.data()!);
    });
  }

  Future<Place> updatePlace(Place place) async {
    final docRef = _firestore.collection('places').doc(place.id);
    final data = Map<String, dynamic>.from(place.toJson());
    data.remove('courses');
    await docRef.update(data);
    return place;
  }

  /// 리버트 시 Firestore 로컬 캐시·펜딩 큐를 원래 플레이스로 덮어씁니다.
  Future<void> overwritePlaceForRevert(Place oldPlace) async {
    final docRef = _firestore.collection('places').doc(oldPlace.id);
    final data = Map<String, dynamic>.from(oldPlace.toJson());
    data.remove('courses');
    await FirestoreUtils.overwritePendingWrite(docRef, data);
  }

  Future<void> deletePlace(String placeId) async {
    final callable = FirebaseFunctions.instance.httpsCallable('deletePlace');
    try {
      await callable.call({'placeId': placeId});
      debugPrint('✅ [PlaceFirestoreService] 플레이스 삭제 완료: $placeId');
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? '플레이스 삭제 중 오류가 발생했습니다.');
    }
  }

  Future<List<Place>> searchPlaces(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    debugPrint('[PlaceFirestoreService.searchPlaces] 호출: "$trimmed"');
    final callable = FirebaseFunctions.instance.httpsCallable('searchPlaces');
    try {
      final result = await callable.call({'query': trimmed});
      final data = result.data as Map<String, dynamic>?;
      final list = data?['places'] as List<dynamic>?;
      if (list == null) return [];

      final places = <Place>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        try {
          final item = Map<String, dynamic>.from(raw);
          final normalized = <String, dynamic>{
            'id': FirestoreUtils.ensureString(item['id']),
            'name': FirestoreUtils.ensureString(item['name']),
            'adminId': FirestoreUtils.ensureString(item['adminId']),
            'description': FirestoreUtils.ensureStringOrNull(
              item['description'],
            ),
            'location': FirestoreUtils.ensureStringOrNull(item['location']),
            'appBarText': FirestoreUtils.ensureStringOrNull(item['appBarText']),
            'greetingText': FirestoreUtils.ensureStringOrNull(
              item['greetingText'],
            ),
            'hideGreeting': item['hideGreeting'] as bool? ?? false,
            'imageUrl': FirestoreUtils.ensureStringOrNull(item['imageUrl']),
            'courses': [],
          };
          places.add(Place.fromJson(normalized));
        } catch (e) {
          debugPrint('[PlaceFirestoreService.searchPlaces] 항목 파싱 스킵: $e');
        }
      }
      return places;
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        '[PlaceFirestoreService.searchPlaces] Callable 오류: ${e.message}',
      );
      rethrow;
    }
  }
}
