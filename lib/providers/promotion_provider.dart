import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/firestore_service.dart';

/// 프로모션 모델 (Firestore용)
class Promotion {
  final String id;
  final String placeId;
  final String title;
  final String description;
  final String? tag;
  final String? imageUrl;
  final int? backgroundColorValue; // Color를 int로 저장
  final DateTime createdAt;

  Promotion({
    required this.id,
    required this.placeId,
    required this.title,
    required this.description,
    this.tag,
    this.imageUrl,
    this.backgroundColorValue,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'placeId': placeId,
      'title': title,
      'description': description,
      'tag': tag,
      'imageUrl': imageUrl,
      'backgroundColorValue': backgroundColorValue,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  factory Promotion.fromJson(Map<String, dynamic> json) {
    // createdAt은 String 또는 Timestamp일 수 있음
    DateTime createdAt;
    if (json['createdAt'] is String) {
      createdAt = DateTime.parse(json['createdAt'] as String);
    } else if (json['createdAt'] is Timestamp) {
      createdAt = (json['createdAt'] as Timestamp).toDate();
    } else {
      createdAt = DateTime.now();
    }

    return Promotion(
      id: json['id'] as String,
      placeId: json['placeId'] as String,
      title: json['title'] as String,
      description: json['description'] as String,
      tag: json['tag'] as String?,
      imageUrl: json['imageUrl'] as String?,
      backgroundColorValue: json['backgroundColorValue'] as int?,
      createdAt: createdAt,
    );
  }
}

/// 프로모션 관리 Provider
class PromotionProvider with ChangeNotifier {
  List<Promotion> _promotions = [];
  bool _isLoading = false;
  String? _error;
  final FirestoreService _firestoreService = FirestoreService();

  List<Promotion> get promotions => List.unmodifiable(_promotions);
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 프로모션 목록 로드
  Future<void> loadPromotions(String placeId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _promotions = await _firestoreService.getPromotionsByPlace(placeId);
      _error = null;
    } catch (e) {
      _error = e.toString();
      _promotions = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 프로모션 생성
  Future<Promotion> createPromotion({
    required String placeId,
    required String title,
    required String description,
    String? tag,
    String? imageUrl,
    int? backgroundColorValue,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final promotion = Promotion(
        id: _generatePromotionId(),
        placeId: placeId,
        title: title,
        description: description,
        tag: tag,
        imageUrl: imageUrl,
        backgroundColorValue: backgroundColorValue,
        createdAt: DateTime.now(),
      );

      final createdPromotion = await _firestoreService.createPromotion(
        promotion,
      );
      _promotions = [..._promotions, createdPromotion];
      _error = null;
      notifyListeners();
      return createdPromotion;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 프로모션 업데이트
  Future<void> updatePromotion(Promotion promotion) async {
    _isLoading = true;
    notifyListeners();

    try {
      final updatedPromotion = await _firestoreService.updatePromotion(
        promotion,
      );
      final index = _promotions.indexWhere((p) => p.id == promotion.id);
      if (index != -1) {
        _promotions[index] = updatedPromotion;
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

  /// 프로모션 삭제
  Future<void> deletePromotion(String promotionId) async {
    _isLoading = true;
    notifyListeners();

    try {
      await _firestoreService.deletePromotion(promotionId);
      _promotions = _promotions.where((p) => p.id != promotionId).toList();
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
    _promotions = [];
    _isLoading = false;
    _error = null;
    notifyListeners();
  }

  String _generatePromotionId() {
    return 'promo_${DateTime.now().millisecondsSinceEpoch}';
  }
}
