import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:reservation/services/auth_service.dart';
import '../models/user.dart';
import '../utils/timezone_utils.dart';
import 'firestore_service.dart';

/// 유저 관리 서비스 (users 컬렉션 CRUD)
///
/// 코스 등록(enrollments)은 EnrollmentService에서 처리
class UserService {
  static final UserService _instance = UserService._internal();
  factory UserService() => _instance;
  UserService._internal();

  final FirestoreService _firestoreService = FirestoreService();
  FirebaseFirestore get _firestore => _firestoreService.firestore;

  User? _currentUser;
  final _userUpdateController = StreamController<User>.broadcast();

  Timestamp _dateTimeToTimestamp(DateTime dateTime) =>
      Timestamp.fromDate(dateTime);

  DateTime _timestampToDateTime(dynamic timestamp) {
    if (timestamp == null) return TimezoneUtils.getSeoulDateTime();
    if (timestamp is Timestamp) return timestamp.toDate();
    if (timestamp is String) return DateTime.parse(timestamp);
    throw Exception('Invalid timestamp format');
  }

  // ==================== 현재 유저 ====================

  User? get currentUser => _currentUser;

  Future<void> login(String userId) async {
    _currentUser = await getUser(userId);
    _userUpdateController.add(_currentUser!);
  }

  void logout() {
    _currentUser = null;
  }

  Stream<User> watchUser() => _userUpdateController.stream;

  // ==================== CRUD ====================

  Future<User> createUser({
    required String userId,
    required String username,
    required String phoneNumber,
  }) async {
    final user = User(
      userId: userId,
      username: username,
      phoneNumber: phoneNumber,
      createdAt: TimezoneUtils.getSeoulDateTime(),
    );
    final docRef = _firestore.collection('users').doc(user.userId);
    await docRef.set({
      ...user.toJson(),
      'createdAt': _dateTimeToTimestamp(user.createdAt),
      'updatedAt':
          user.updatedAt != null ? _dateTimeToTimestamp(user.updatedAt!) : null,
    });
    if (_currentUser?.userId == userId) {
      _currentUser = user;
      _userUpdateController.add(user);
    }
    return user;
  }

  Future<User> createUserFromModel(User user) async {
    final docRef = _firestore.collection('users').doc(user.userId);
    await docRef.set({
      ...user.toJson(),
      'createdAt': _dateTimeToTimestamp(user.createdAt),
      'updatedAt':
          user.updatedAt != null ? _dateTimeToTimestamp(user.updatedAt!) : null,
    });
    return user;
  }

  Future<void> deleteUser(String userId) async {
    await _firestore.collection('users').doc(userId).delete();
    if (_currentUser?.userId == userId) _currentUser = null;
  }

  Future<User> getUser(String userId) async {
    final doc = await _firestore.collection('users').doc(userId).get();
    if (!doc.exists) throw Exception('사용자를 찾을 수 없습니다.');

    final data = doc.data()!;
    data['userId'] = doc.id;
    data['createdAt'] =
        _timestampToDateTime(data['createdAt']).toIso8601String();
    if (data['updatedAt'] != null) {
      data['updatedAt'] =
          _timestampToDateTime(data['updatedAt']).toIso8601String();
    }
    final user = User.fromJson(data);
    if (_currentUser?.userId == userId) {
      _currentUser = user;
      _userUpdateController.add(user);
    }
    return user;
  }

  Future<List<User>> getUsersByIds(List<String> userIds) async {
    if (userIds.isEmpty) return [];
    const maxBatchSize = 10;
    final allUsers = <User>[];

    for (int i = 0; i < userIds.length; i += maxBatchSize) {
      final batch = userIds.skip(i).take(maxBatchSize).toList();
      try {
        final snapshot =
            await _firestore
                .collection('users')
                .where(FieldPath.documentId, whereIn: batch)
                .get();
        for (final doc in snapshot.docs) {
          final data = doc.data();
          data['userId'] = doc.id;
          data['createdAt'] =
              _timestampToDateTime(data['createdAt']).toIso8601String();
          if (data['updatedAt'] != null) {
            data['updatedAt'] =
                _timestampToDateTime(data['updatedAt']).toIso8601String();
          }
          allUsers.add(User.fromJson(data));
        }
      } catch (_) {
        for (final uid in batch) {
          try {
            allUsers.add(await getUser(uid));
          } catch (_) {}
        }
      }
    }
    return allUsers;
  }

  /// 본인 정보만 수정 가능 (Firebase Auth uid 기준 — 플레이스 등록 등에서 _currentUser 미설정이어도 동작)
  Future<User> updateUser(User user) async {
    final authUid = AuthService().currentFirebaseUser?.uid;
    if (authUid == null || authUid != user.userId) {
      throw Exception('본인의 정보만 수정할 수 있습니다.');
    }
    await _writeUser(user);
    if (_currentUser?.userId == user.userId) {
      _currentUser = user;
      _userUpdateController.add(user);
    }
    return user;
  }

  /// 호환용 (updateUser와 동일)
  Future<User> updateAdmin(User user) async => updateUser(user);

  /// 관리자용: 타인 유저 직접 수정
  Future<User> updateUserDirect(User user) async {
    await _writeUser(user);
    if (_currentUser?.userId == user.userId) {
      _currentUser = user;
      _userUpdateController.add(user);
    }
    return user;
  }

  Future<void> _writeUser(User user) async {
    final docRef = _firestore.collection('users').doc(user.userId);
    await docRef.update({
      ...user.toJson(),
      'placeIds': FieldValue.delete(),
      'reservations': FieldValue.delete(),
      'updatedAt': _dateTimeToTimestamp(TimezoneUtils.getSeoulDateTime()),
    });
  }

  Future<void> updateCurrentPlaceId(String userId, String? placeId) async {
    await _firestore.collection('users').doc(userId).update({
      'currentPlaceId': placeId,
      'updatedAt': _dateTimeToTimestamp(TimezoneUtils.getSeoulDateTime()),
    });
    if (_currentUser?.userId == userId) {
      _currentUser = _currentUser!.copyWith(currentPlaceId: placeId);
      _userUpdateController.add(_currentUser!);
    }
  }

  // ==================== 플레이스 ====================

  Future<User> addPlace(String userId, String placeId) async {
    final user = await getUser(userId);
    return updateUser(user.addPlace(placeId));
  }

  Future<User> removePlace(String userId, String placeId) async {
    final user = await getUser(userId);
    return updateUser(user.removePlace(placeId));
  }

  void dispose() {
    _userUpdateController.close();
  }
}
