import 'package:flutter/foundation.dart';
import '../models/place.dart';
import '../services/firestore_service.dart';

/// 플레이스 정보 Provider
///
/// 현재 선택된 플레이스 정보를 관리하고 실시간 업데이트
class PlaceProvider with ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();

  Place? _currentPlace;
  final Map<String, Place> _places = {}; // 플레이스 ID별로 저장
  bool _isLoading = false;
  String? _error;

  Place? get currentPlace => _currentPlace;

  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 특정 플레이스 가져오기
  Place? getPlace(String placeId) => _places[placeId];

  /// 모든 플레이스 목록
  List<Place> get allPlaces => _places.values.toList();

  /// 플레이스 로드
  Future<void> loadPlace(String placeId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final place = await _firestoreService.getPlace(placeId);
      if (place != null) {
        _places[placeId] = place;
        _currentPlace = place;
      }
      _error = null;
    } catch (e) {
      _error = e.toString();
      _currentPlace = null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 여러 플레이스 로드 (병렬 처리로 최적화)
  Future<void> loadPlaces(List<String> placeIds) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // 이미 로드된 플레이스는 스킵
      final placeIdsToLoad =
          placeIds.where((placeId) => !_places.containsKey(placeId)).toList();

      if (placeIdsToLoad.isEmpty) {
        _isLoading = false;
        notifyListeners();
        return;
      }

      // 병렬로 플레이스 로드
      final places = await Future.wait(
        placeIdsToLoad.map((placeId) async {
          try {
            return await _firestoreService.getPlace(placeId);
          } catch (e) {
            return null;
          }
        }),
      );

      // 로드된 플레이스를 맵에 추가
      for (int i = 0; i < placeIdsToLoad.length; i++) {
        final id = placeIdsToLoad[i];
        final place = places[i];
        if (place != null) {
          _places[id] = place;
        }
      }

      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Cloud Function 등으로 플레이스 생성 후 로컬 상태 반영
  void setCreatedPlace(Place place) {
    _places[place.id] = place;
    _currentPlace = place;
    _error = null;
    notifyListeners();
  }

  /// 플레이스 생성
  Future<Place> createPlace({
    required String name,
    String? description,
    String? appBarText,
    String? greetingText,
    bool hideGreeting = false,
    String? imageUrl,
    required String adminId,
  }) async {
    _isLoading = true;
    notifyListeners();

    final place = Place(
      id: _generatePlaceId(),
      name: name,
      adminId: adminId,
      description: description,

      greetingText: greetingText,
      hideGreeting: hideGreeting,
      imageUrl: imageUrl,
      courses: [],
    );

    try {
      await _firestoreService.createPlace(place);
      _places[place.id] = place;
      _currentPlace = place;
      _error = null;

      notifyListeners();
      return place;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 플레이스 업데이트
  Future<void> updatePlace(Place place) async {
    _isLoading = true;
    notifyListeners();

    try {
      await _firestoreService.updatePlace(place);
      if (_currentPlace?.id == place.id) {
        _currentPlace = place;
      }
      _places[place.id] = place;
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

  /// 플레이스 설정 (인사말, 앱바 텍스트 등)
  Future<void> updatePlaceSettings({
    String? appBarText,
    String? greetingText,
    bool? hideGreeting,
  }) async {
    if (_currentPlace == null) return;

    final updatedPlace = _currentPlace!.copyWith(
      greetingText: greetingText ?? _currentPlace!.greetingText,
      hideGreeting: hideGreeting ?? _currentPlace!.hideGreeting,
    );

    await updatePlace(updatedPlace);
  }

  /// 플레이스 삭제
  /// 서버 성공 시 반드시 provider 업데이트 (서버·로컬 동기화 보장)
  Future<void> deletePlace(String placeId) async {
    _isLoading = true;
    notifyListeners();

    try {
      await _firestoreService.deletePlace(placeId);

      // Provider에서 제거 (서버 성공 시 동기화 필수)
      _places.remove(placeId);

      // 현재 플레이스가 삭제된 플레이스인 경우 초기화
      if (_currentPlace?.id == placeId) {
        _currentPlace = null;
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

  /// 플레이스 선택
  void setCurrentPlace(Place place) {
    _currentPlace = place;
    notifyListeners();
  }

  /// 플레이스 초기화
  void clearPlace() {
    _currentPlace = null;
    _error = null;
    notifyListeners();
  }

  String _generatePlaceId() {
    return 'place_${DateTime.now().millisecondsSinceEpoch}';
  }
}
