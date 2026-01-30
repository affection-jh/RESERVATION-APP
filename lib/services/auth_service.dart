import 'dart:async';
import 'package:flutter/material.dart';

import '../models/user.dart' as models;
import '../models/admin_user.dart';
import '../models/place.dart';
import '../models/place_membership.dart';
import 'firestore_service.dart';
import 'user_service.dart';
import 'admin_service.dart';
import '../utils/storage_service.dart';
import '../utils/timezone_utils.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth show User;
import 'package:cloud_functions/cloud_functions.dart';
import '../firebase_options.dart';

/// 인증 및 플레이스 멤버십 관리 서비스
class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  /// Firebase 초기화는 `main.dart`에서 수행되지만,
  /// iOS/Hot Restart/비동기 타이밍 이슈로 인해 PhoneAuth 진입 시점에
  /// 아직 Default FirebaseApp이 준비되지 않은 경우가 있어 방어적으로 보장한다.
  static Future<void>? _firebaseInitFuture;

  static Future<void> ensureFirebaseInitialized() async {
    // 이미 초기화된 경우
    if (Firebase.apps.isNotEmpty) {
      return;
    }

    // 동시 호출 방지 (한 번만 초기화 시도)
    _firebaseInitFuture ??= Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await _firebaseInitFuture!;
  }

  final FirestoreService _firestoreService = FirestoreService();
  final UserService _userService = UserService();
  final AdminService _adminService = AdminService();
  final StorageService _storageService = StorageService();

  // Firebase Auth 인스턴스 (getter로 변경하여 늦은 초기화)
  // Firebase.initializeApp() 완료 후에만 접근하도록 함
  FirebaseAuth get _auth => FirebaseAuth.instance;

  // 현재 Firebase 사용자 (외부 접근용)
  firebase_auth.User? get currentFirebaseUser => _auth.currentUser;

  // 현재 선택된 플레이스
  Place? _currentPlace;

  // 인증 상태 스트림
  Stream<AuthState>? _authStateStream;

  /// 현재 선택된 플레이스
  Place? get currentPlace => _currentPlace;

  /// 익명 로그인
  Future<firebase_auth.User> signInAnonymously() async {
    await AuthService.ensureFirebaseInitialized();
    final userCredential = await _auth.signInAnonymously();
    return userCredential.user!;
  }

  // ==================== 전화번호 인증 (Firebase Auth 사용) ====================

  /// 전화번호로 SMS 인증 코드 발송
  ///
  /// Firebase Auth를 사용하여 자동으로 처리
  ///
  /// [phoneNumber] 전화번호 (국가코드 포함, 예: +821012345678)
  ///
  /// Returns: verificationId (인증 코드 확인 시 사용)
  ///
  /// Throws: Exception (플랫폼 채널 에러 또는 인증 실패)
  Future<String> sendVerificationCode(String phoneNumber) async {
    debugPrint('[AuthService.sendVerificationCode] 시작');
    debugPrint('[AuthService.sendVerificationCode] 입력 전화번호: "$phoneNumber"');

    // iOS에서 PhoneAuthProvider가 Default FirebaseApp을 강제 언래핑(!)하는 경로가 있어
    // verifyPhoneNumber 호출 전 Firebase 초기화 완료를 보장한다.
    await AuthService.ensureFirebaseInitialized();

    // 전화번호 포맷팅 (국가코드 추가)
    String formattedPhone = phoneNumber;
    if (!formattedPhone.startsWith('+')) {
      // 한국 번호인 경우 +82 추가
      if (formattedPhone.startsWith('0')) {
        formattedPhone = '+82${formattedPhone.substring(1)}';
      } else if (formattedPhone.startsWith('82')) {
        formattedPhone = '+$formattedPhone';
      } else {
        formattedPhone = '+82$formattedPhone';
      }
    }

    debugPrint(
      '[AuthService.sendVerificationCode] 포맷팅된 전화번호: "$formattedPhone"',
    );

    // Completer를 사용하여 비동기 콜백을 Future로 변환
    final completer = Completer<String>();

    // iOS 네이티브 PhoneAuthProvider 내부 초기화 타이밍 이슈로 인한 크래시 방지
    // verifyPhoneNumber 호출을 try-catch로 감싸서 크래시 대신 에러로 처리
    try {
      debugPrint(
        '[AuthService.sendVerificationCode] verifyPhoneNumber 호출 시작...',
      );
      await _auth.verifyPhoneNumber(
        phoneNumber: formattedPhone,
        verificationCompleted: (PhoneAuthCredential credential) async {
          // 자동 인증 완료 (Android에서만 발생)
          try {
            await _auth.signInWithCredential(credential);
            // 자동 인증 완료 시 verificationId는 필요 없지만,
            // 일관성을 위해 credential.verificationId 사용 (null일 수 있음)
            if (!completer.isCompleted) {
              completer.complete(credential.verificationId ?? '');
            }
          } catch (e) {
            if (!completer.isCompleted) {
              completer.completeError(e);
            }
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          debugPrint('[AuthService.sendVerificationCode] ❌ verificationFailed');
          debugPrint('[AuthService.sendVerificationCode] 에러 코드: ${e.code}');
          debugPrint('[AuthService.sendVerificationCode] 에러 메시지: ${e.message}');
          debugPrint(
            '[AuthService.sendVerificationCode] 에러 상세: ${e.toString()}',
          );

          if (!completer.isCompleted) {
            // 플랫폼 채널 에러인 경우 더 친화적인 메시지
            if (e.code == 'channel-error') {
              completer.completeError(
                Exception('인증 서비스 초기화 중입니다. 잠시 후 다시 시도해주세요.'),
              );
            } else if (e.code == 'invalid-phone-number') {
              completer.completeError(Exception('전화번호 형식이 올바르지 않습니다.'));
            } else if (e.code == 'too-many-requests') {
              completer.completeError(
                Exception('너무 많은 요청이 발생했습니다. 잠시 후 다시 시도해주세요.'),
              );
            } else {
              completer.completeError(
                Exception('인증 실패: ${e.message ?? e.code}'),
              );
            }
          }
        },
        codeSent: (String verificationId, int? resendToken) {
          debugPrint('[AuthService.sendVerificationCode] ✅ codeSent');
          debugPrint(
            '[AuthService.sendVerificationCode] verificationId: "${verificationId.substring(0, verificationId.length > 20 ? 20 : verificationId.length)}..." (length: ${verificationId.length})',
          );
          debugPrint(
            '[AuthService.sendVerificationCode] resendToken: $resendToken',
          );

          // verificationId를 저장하여 나중에 사용
          _storageService.saveVerificationId(verificationId, phoneNumber);
          if (!completer.isCompleted) {
            completer.complete(verificationId);
          }
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          debugPrint(
            '[AuthService.sendVerificationCode] ⏱️ codeAutoRetrievalTimeout',
          );
          debugPrint(
            '[AuthService.sendVerificationCode] verificationId: "${verificationId.substring(0, verificationId.length > 20 ? 20 : verificationId.length)}..." (length: ${verificationId.length})',
          );

          // 자동 인증 타임아웃 (iOS에서만 발생)
          // verificationId는 이미 codeSent에서 받았으므로 여기서는 무시
          // 하지만 codeSent가 호출되지 않은 경우를 대비해 처리
          if (!completer.isCompleted) {
            _storageService.saveVerificationId(verificationId, phoneNumber);
            completer.complete(verificationId);
          }
        },
        timeout: const Duration(seconds: 60),
      );
    } catch (e, stackTrace) {
      debugPrint('[AuthService.sendVerificationCode] ❌ 예상치 못한 에러 발생');
      debugPrint('[AuthService.sendVerificationCode] 에러 타입: ${e.runtimeType}');
      debugPrint('[AuthService.sendVerificationCode] 에러 내용: $e');
      debugPrint('[AuthService.sendVerificationCode] 스택 트레이스: $stackTrace');

      // 플랫폼 채널 에러 처리
      if (e.toString().contains('channel-error') ||
          e.toString().contains('PlatformException')) {
        throw Exception('인증 서비스 초기화 중입니다. 앱을 완전히 재시작하거나 잠시 후 다시 시도해주세요.');
      }
      // iOS에서 발생할 수 있는 nil unwrap 에러 처리
      if (e.toString().contains('nil') ||
          e.toString().contains('Unexpectedly found nil')) {
        throw Exception('인증 서비스 초기화에 실패했습니다. 앱을 재시작해주세요.');
      }
      rethrow;
    }

    // 타임아웃 설정 (60초 후 완료되지 않으면 에러)
    Future.delayed(const Duration(seconds: 65), () {
      if (!completer.isCompleted) {
        completer.completeError(Exception('인증 코드 발송 시간이 초과되었습니다. 다시 시도해주세요.'));
      }
    });

    return completer.future;
  }

  /// 인증 코드 확인 및 로그인
  ///
  /// Firebase Auth를 사용하여 자동으로 처리
  ///
  /// [smsCode] SMS로 받은 6자리 인증 코드
  /// [name] 회원가입 시 필요한 이름 (기존 사용자는 null 가능)
  /// [phoneNumber] 전화번호 (옵션)
  ///
  /// Returns: AuthResult (사용자 정보 및 인증 결과)
  Future<AuthResult> verifyCodeAndSignIn({
    String? verificationId, // null이면 저장된 verificationId 사용
    required String smsCode,
    String? name, // 회원가입 시 필요
    String? phoneNumber, // 옵션
  }) async {
    debugPrint('[AuthService.verifyCodeAndSignIn] 시작');
    debugPrint(
      '[AuthService.verifyCodeAndSignIn] smsCode: "$smsCode" (length: ${smsCode.length})',
    );
    debugPrint('[AuthService.verifyCodeAndSignIn] phoneNumber: "$phoneNumber"');
    debugPrint(
      '[AuthService.verifyCodeAndSignIn] verificationId 파라미터: "$verificationId"',
    );

    // signInWithCredential 전에 Firebase 초기화 완료 보장
    await AuthService.ensureFirebaseInitialized();

    // 이미 Firebase Auth에 로그인되어 있는지 확인 (이름 입력 화면에서 재호출된 경우)
    firebase_auth.User? firebaseUser = _auth.currentUser;
    debugPrint(
      '[AuthService.verifyCodeAndSignIn] 현재 로그인된 사용자: ${firebaseUser?.uid ?? "없음"}',
    );

    if (firebaseUser == null) {
      // 로그인되지 않은 경우에만 인증 코드로 로그인
      // verificationId가 없으면 저장된 것 사용
      final finalVerificationId =
          verificationId ?? await _storageService.getVerificationId();

      debugPrint(
        '[AuthService.verifyCodeAndSignIn] finalVerificationId: "${finalVerificationId?.substring(0, finalVerificationId.length > 20 ? 20 : finalVerificationId.length)}..." (length: ${finalVerificationId?.length ?? 0})',
      );

      if (finalVerificationId == null) {
        debugPrint(
          '[AuthService.verifyCodeAndSignIn] ❌ verificationId를 찾을 수 없음',
        );
        throw Exception('인증 ID를 찾을 수 없습니다. 인증 코드를 다시 요청해주세요.');
      }

      // PhoneAuthCredential 생성
      final credential = PhoneAuthProvider.credential(
        verificationId: finalVerificationId,
        smsCode: smsCode,
      );

      debugPrint('[AuthService.verifyCodeAndSignIn] PhoneAuthCredential 생성 완료');
      debugPrint(
        '[AuthService.verifyCodeAndSignIn] signInWithCredential 호출 시작...',
      );

      // Firebase Auth에 로그인 (자동으로 인증 상태 저장)
      UserCredential userCredential;
      try {
        userCredential = await _auth.signInWithCredential(credential);
        debugPrint(
          '[AuthService.verifyCodeAndSignIn] ✅ signInWithCredential 성공',
        );
        debugPrint(
          '[AuthService.verifyCodeAndSignIn] userCredential.user.uid: ${userCredential.user?.uid}',
        );
        debugPrint(
          '[AuthService.verifyCodeAndSignIn] userCredential.user.phoneNumber: ${userCredential.user?.phoneNumber}',
        );
      } on FirebaseAuthException catch (e) {
        debugPrint(
          '[AuthService.verifyCodeAndSignIn] ❌ FirebaseAuthException 발생',
        );
        debugPrint('[AuthService.verifyCodeAndSignIn] 에러 코드: ${e.code}');
        debugPrint('[AuthService.verifyCodeAndSignIn] 에러 메시지: ${e.message}');
        debugPrint('[AuthService.verifyCodeAndSignIn] 에러 상세: ${e.toString()}');
        if (e.stackTrace != null) {
          debugPrint(
            '[AuthService.verifyCodeAndSignIn] 스택 트레이스: ${e.stackTrace}',
          );
        }
        // 세션 만료 또는 잘못된 인증 코드 에러 처리
        if (e.code == 'session-expired' ||
            e.code == 'invalid-verification-code') {
          // 저장된 verificationId 삭제 (재발송 필요)
          await _storageService.clearVerificationData();
          debugPrint('[AuthService.verifyCodeAndSignIn] verificationId 삭제 완료');
          throw Exception('인증 코드가 만료되었거나 올바르지 않습니다. 인증 코드를 다시 요청해주세요.');
        }
        rethrow;
      } catch (e, stackTrace) {
        debugPrint('[AuthService.verifyCodeAndSignIn] ❌ 예상치 못한 에러 발생');
        debugPrint('[AuthService.verifyCodeAndSignIn] 에러 타입: ${e.runtimeType}');
        debugPrint('[AuthService.verifyCodeAndSignIn] 에러 내용: $e');
        debugPrint('[AuthService.verifyCodeAndSignIn] 스택 트레이스: $stackTrace');
        rethrow;
      }

      firebaseUser = userCredential.user;
    }

    if (firebaseUser == null) {
      debugPrint('[AuthService.verifyCodeAndSignIn] ❌ firebaseUser가 null');
      throw Exception('인증에 실패했습니다.');
    }

    debugPrint(
      '[AuthService.verifyCodeAndSignIn] firebaseUser.phoneNumber: ${firebaseUser.phoneNumber}',
    );

    // 전화번호 가져오기
    String finalPhoneNumber;
    if (firebaseUser.phoneNumber != null) {
      finalPhoneNumber = firebaseUser.phoneNumber!;
      debugPrint(
        '[AuthService.verifyCodeAndSignIn] Firebase Auth에서 전화번호 가져옴: $finalPhoneNumber',
      );
    } else if (phoneNumber != null) {
      // 파라미터로 전달된 전화번호 사용
      finalPhoneNumber = phoneNumber;
      debugPrint(
        '[AuthService.verifyCodeAndSignIn] 파라미터에서 전화번호 사용: $finalPhoneNumber',
      );
    } else {
      // phoneNumber가 null인 경우 저장된 전화번호 사용
      final savedPhone = await _storageService.getVerificationPhone();
      if (savedPhone == null) {
        debugPrint('[AuthService.verifyCodeAndSignIn] ❌ 저장된 전화번호를 찾을 수 없음');
        throw Exception('전화번호를 찾을 수 없습니다.');
      }
      finalPhoneNumber = savedPhone;
      debugPrint(
        '[AuthService.verifyCodeAndSignIn] 저장된 전화번호 사용: $finalPhoneNumber',
      );
    }

    // 전화번호 포맷 정규화 (국가코드 제거)
    finalPhoneNumber = _normalizePhoneNumber(finalPhoneNumber);
    debugPrint(
      '[AuthService.verifyCodeAndSignIn] 정규화된 전화번호: $finalPhoneNumber',
    );

    // 사용자 조회 또는 생성
    models.User? user = await findUserByPhone(finalPhoneNumber);

    if (user == null) {
      // 신규 사용자 - 회원가입
      if (name == null || name.trim().isEmpty) {
        throw Exception('회원가입을 위해 이름이 필요합니다.');
      }
      user = await _createUser(
        userId: firebaseUser.uid, // Firebase Auth UID 사용
        phoneNumber: finalPhoneNumber,
        name: name,
      );
    } else {
      // 기존 사용자 - userId가 Firebase UID와 다를 수 있으므로 업데이트 고려
      // (선택적: 기존 userId 유지 또는 Firebase UID로 업데이트)
    }

    // 인증 정보 삭제
    await _storageService.clearVerificationData();

    // 인증 완료 처리
    return await _completeAuthentication(user);
  }

  /// 저장된 verificationId 가져오기 (회원가입 플로우용)
  Future<String?> getVerificationId() async {
    return await _storageService.getVerificationId();
  }

  /// 인증 정보 초기화 (뒤로가기 등으로 취소 시 사용)
  Future<void> clearVerificationData() async {
    await _storageService.clearVerificationData();
  }

  /// (관리자 플로우용) SMS 인증코드만 검증하고 바로 로그아웃.
  /// - `FirebaseAuth.instance`를 UI에서 직접 만지지 않도록 중앙화
  /// - Firebase 초기화 타이밍 문제를 여기서 방어
  Future<void> verifySmsCodeOnly({
    required String smsCode,
    String? verificationId,
  }) async {
    await AuthService.ensureFirebaseInitialized();

    final finalVerificationId =
        verificationId ?? await _storageService.getVerificationId();

    if (finalVerificationId == null) {
      throw Exception('인증 ID를 찾을 수 없습니다. 인증 코드를 다시 요청해주세요.');
    }

    final credential = PhoneAuthProvider.credential(
      verificationId: finalVerificationId,
      smsCode: smsCode,
    );

    final userCredential = await _auth.signInWithCredential(credential);
    if (userCredential.user == null) {
      throw Exception('인증에 실패했습니다.');
    }

    await _auth.signOut();
  }

  /// 전화번호 정규화 (국가코드 제거)
  String _normalizePhoneNumber(String phoneNumber) {
    // +82로 시작하는 경우 0으로 변환
    if (phoneNumber.startsWith('+82')) {
      return '0${phoneNumber.substring(3)}';
    }
    // +로 시작하는 다른 국가코드 제거
    if (phoneNumber.startsWith('+')) {
      // 간단히 + 제거 (실제로는 국가코드 길이에 따라 다르지만, 한국만 고려)
      return phoneNumber.substring(phoneNumber.length - 10);
    }
    return phoneNumber;
  }

  // ==================== 자동 로그인 ====================

  // ==================== "명시적 진입 선택" 플래그 ====================

  /// 전화번호 인증 직후에는 관리자/멤버 자동 분기를 하지 않고,
  /// Waiting 화면에서 멈춘 뒤 사용자가 플레이스를 선택하게 하기 위한 플래그.
  Future<void> setRequireManualEntrySelection(bool value) async {
    await _storageService.setRequireManualEntrySelection(value);
  }

  Future<bool> requiresManualEntrySelection() async {
    return await _storageService.getRequireManualEntrySelection();
  }

  Future<void> clearRequireManualEntrySelection() async {
    await _storageService.clearRequireManualEntrySelection();
  }

  /// 일반 사용자 자동 로그인 확인 (Firebase Auth 세션 활용)
  ///
  /// Firebase Auth의 현재 인증 상태를 확인하여 자동 로그인
  Future<AuthResult?> checkUserAutoLogin() async {
    try {
      final firebaseUser = _auth.currentUser;
      if (firebaseUser == null) {
        return null; // 로그인 안됨
      }

      // 전화번호 가져오기
      String? phoneNumber = firebaseUser.phoneNumber;
      if (phoneNumber == null) {
        return null;
      }

      // 전화번호 정규화
      phoneNumber = _normalizePhoneNumber(phoneNumber);

      // 사용자 조회
      final user = await findUserByPhone(phoneNumber);
      if (user == null) {
        // Firebase Auth에는 있지만 Firestore에 사용자 정보가 없음
        // 이 경우는 로그아웃 처리
        await _auth.signOut();
        return null;
      }

      // 관리자 여부 확인 (관리자도 일반 사용자로 로그인 가능)
      // 관리자 자동 로그인은 이미 checkAdminAutoLogin에서 처리되므로
      // 여기서는 일반 사용자로 처리 (관리자도 다른 플레이스의 멤버가 될 수 있음)

      // 인증 완료 처리 (관리자도 일반 사용자로 처리)
      return await _completeAuthentication(user);
    } catch (e) {
      // ⚠️ 인증 외(네트워크/Firestore 등) 예외로 세션을 깨면
      // "자동로그인이 아예 안됨"처럼 보일 수 있으므로 signOut하지 않는다.
      debugPrint('[AuthService.checkUserAutoLogin] 예외: $e');
      return null;
    }
  }

  /// 앱 시작 시 자동 로그인 확인
  ///
  /// 저장된 전화번호로 자동 로그인 시도
  ///
  /// PIN은 저장하지 않고, 전화번호와 userId만으로 자동 로그인
  Future<AdminAutoLoginResult?> checkAdminAutoLogin() async {
    debugPrint('[AuthService.checkAdminAutoLogin] 시작');
    try {
      // 1. Firebase Auth 세션 확인 (우선순위)
      final firebaseUser = _auth.currentUser;
      String? phoneNumber;
      String? userId;

      if (firebaseUser != null && firebaseUser.phoneNumber != null) {
        // Firebase Auth 세션에서 전화번호 가져오기
        phoneNumber = _normalizePhoneNumber(firebaseUser.phoneNumber!);
        debugPrint(
          '[AuthService.checkAdminAutoLogin] Firebase Auth 세션에서 전화번호 가져옴: $phoneNumber',
        );
      } else {
        // 2. 저장된 전화번호와 userId 확인 (폴백)
        phoneNumber = await _storageService.getAdminPhone();
        userId = await _storageService.getAdminUserId();
        debugPrint('[AuthService.checkAdminAutoLogin] 저장된 전화번호: $phoneNumber');
        debugPrint('[AuthService.checkAdminAutoLogin] 저장된 userId: $userId');
      }

      if (phoneNumber == null) {
        debugPrint('[AuthService.checkAdminAutoLogin] 전화번호를 찾을 수 없음');
        return null;
      }

      // 3. 관리자 정보 조회
      AdminUser? admin;
      try {
        debugPrint(
          '[AuthService.checkAdminAutoLogin] findAdminByPhone 호출: $phoneNumber',
        );
        admin = await findAdminByPhone(phoneNumber);
        debugPrint(
          '[AuthService.checkAdminAutoLogin] findAdminByPhone 결과: ${admin != null ? "성공" : "null"}',
        );
        if (admin != null) {
          debugPrint(
            '[AuthService.checkAdminAutoLogin] 관리자 정보: userId=${admin.userId}, placeIds=${admin.placeIds}',
          );
        }
      } catch (e) {
        debugPrint('[AuthService.checkAdminAutoLogin] findAdminByPhone 에러: $e');
        // Firestore 미구현 시 저장된 정보로 임시 관리자 생성
        if (e.toString().contains('UnimplementedError')) {
          if (userId == null) {
            userId =
                firebaseUser?.uid ??
                'temp_${DateTime.now().millisecondsSinceEpoch}';
          }
          admin = AdminUser(
            userId: userId,
            phoneNumber: phoneNumber,
            name: '관리자', // 임시
            authPin: null, // PIN은 저장하지 않음
            placeIds: [],
            createdAt: TimezoneUtils.getSeoulDateTime(),
          );
        } else {
          return null;
        }
      }

      if (admin == null) {
        debugPrint('[AuthService.checkAdminAutoLogin] 관리자 정보를 찾을 수 없음');
        return null;
      }

      // 4. userId 일치 확인 (저장된 userId가 있는 경우만)
      if (userId != null && admin.userId != userId) {
        debugPrint(
          '[AuthService.checkAdminAutoLogin] userId 불일치: 저장된=$userId, 조회된=${admin.userId}',
        );
        // userId가 다르면 저장된 정보 삭제
        await _storageService.clearAdminData();
        return null;
      }

      // 5. 관리자 정보 저장 (자동 로그인을 위해)
      if (firebaseUser != null) {
        await _storageService.saveAdminPhone(phoneNumber);
        await _storageService.saveAdminUserId(admin.userId);
        debugPrint('[AuthService.checkAdminAutoLogin] 관리자 정보 저장 완료');
      }

      // 6. 관리자 로그인 (이미 가져온 관리자 정보 사용)
      debugPrint('[AuthService.checkAdminAutoLogin] 관리자 로그인 시작');
      await _adminService.loginWithAdmin(admin);
      debugPrint('[AuthService.checkAdminAutoLogin] 관리자 로그인 완료');

      // ✅ 플레이스 업데이트 여부와 무관하게 "마지막 접속 모드=admin"을 저장
      // (관리자 화면에 진입했는데도 lastEntryMode가 member로 남는 문제 방지)
      await _storageService.saveLastEntryMode('admin');

      // 7. 최근 접속한 플레이스 확인
      final lastPlaceId = await _storageService.getLastAccessedPlaceId();
      final effectivePlaceId = admin.lastAccessedPlaceId ?? lastPlaceId;
      debugPrint(
        '[AuthService.checkAdminAutoLogin] 마지막 접속 플레이스: $effectivePlaceId',
      );

      final result = AdminAutoLoginResult(
        admin: admin,
        lastAccessedPlaceId: effectivePlaceId,
      );
      debugPrint(
        '[AuthService.checkAdminAutoLogin] 성공: 관리자 ID=${admin.userId}, 플레이스 개수=${admin.placeIds.length}',
      );
      return result;
    } catch (e, stackTrace) {
      debugPrint('[AuthService.checkAdminAutoLogin] ❌ 에러 발생: $e');
      debugPrint('[AuthService.checkAdminAutoLogin] 스택 트레이스: $stackTrace');
      // 에러 발생 시 저장된 정보 삭제
      await _storageService.clearAdminData();
      return null;
    }
  }

  /// 관리자 로그아웃
  Future<void> logoutAdmin() async {
    await _storageService.clearAdminData();
    _adminService.logout();
  }

  /// 최근 접속한 플레이스 업데이트
  Future<void> updateLastAccessedPlace(String placeId) async {
    // 서버에 현재 플레이스 ID 저장
    final savedUserId = await _storageService.getAdminUserId();
    if (savedUserId != null) {
      await _userService.updateCurrentPlaceId(savedUserId, placeId);
    }

    // ✅ 관리자 모드로 접속했음을 저장 (자동 로그인 시 모드 복원)
    await _storageService.saveLastEntryMode('admin');

    // AdminUser에도 업데이트 (Firestore 연동 시)
    try {
      if (savedUserId != null) {
        final userService = UserService();
        final admin = await userService.getAdmin(savedUserId);
        if (admin != null) {
          final updatedAdmin = admin.copyWith(
            lastAccessedPlaceId: placeId,
            updatedAt: TimezoneUtils.getSeoulDateTime(),
          );
          final userService = UserService();
          await userService.updateAdmin(updatedAdmin);
        }
      }
    } catch (e) {
      // Firestore 미구현 시 무시
    }
  }

  /// 마지막 접속 모드 조회 (admin/member)
  Future<String?> getLastEntryMode() async {
    return await _storageService.getLastEntryMode();
  }

  /// 인증 상태 변경 스트림 구독
  ///
  /// Firebase Auth의 인증 상태 변경을 실시간으로 감지
  ///
  /// 주의: Hot Restart 후 플랫폼 채널 연결 오류가 발생할 수 있으나,
  /// 이는 Firebase Auth 플러그인의 알려진 이슈이며 기능에는 영향 없음
  Stream<AuthState> authStateChanges() {
    if (_authStateStream != null) {
      return _authStateStream!;
    }

    try {
      // Firebase Auth의 authStateChanges() 호출
      // Hot Restart 후 초기화되지 않았을 때 PlatformException이 발생할 수 있음
      // 하지만 이는 무시해도 되는 에러 (플러그인이 자동으로 재시도)
      final firebaseStream = _auth.authStateChanges();

      _authStateStream = firebaseStream
          .asyncMap((firebaseUser) async {
            if (firebaseUser == null) {
              return AuthState.unauthenticated();
            }

            // 전화번호 가져오기
            String? phoneNumber = firebaseUser.phoneNumber;
            if (phoneNumber == null) {
              return AuthState.unauthenticated();
            }

            // 전화번호 정규화
            phoneNumber = _normalizePhoneNumber(phoneNumber);

            // 사용자 조회
            final user = await findUserByPhone(phoneNumber);
            if (user == null) {
              return AuthState.unauthenticated();
            }

            // 관리자 여부 확인
            final isAdmin = await _checkIfAdmin(user.userId);
            if (isAdmin) {
              await _adminService.login(user.userId);
              return AuthState.authenticated(user: user, role: UserRole.admin);
            }

            // 플레이스 멤버십 확인
            final memberships = await _autoMatchMemberships(
              user.userId,
              phoneNumber,
            );

            await _userService.login(user.userId);

            return AuthState.authenticated(
              user: user,
              role: UserRole.member,
              memberships: memberships,
            );
          })
          .handleError((error, stackTrace) {
            // 플랫폼 채널 연결 오류 등 에러 처리
            // Hot Restart 후 플러그인이 초기화되지 않았을 때 발생할 수 있음
            // 이는 Firebase Auth 플러그인의 알려진 이슈이며,
            // 플러그인이 자동으로 재시도하므로 무시해도 됨
            // 에러 발생 시 인증되지 않은 상태로 반환
            return AuthState.unauthenticated();
          });

      return _authStateStream!;
    } catch (e) {
      // 초기화 실패 시 빈 스트림 반환
      // Hot Restart 후 발생할 수 있는 정상적인 상황
      return Stream.value(AuthState.unauthenticated());
    }
  }

  // ==================== 인증 완료 처리 ====================

  Future<List<PlaceMembership>> _fetchPlaceMembershipsForUser(
    String userId,
  ) async {
    final firestore = _firestoreService.firestore;
    final snap =
        await firestore
            .collection('placeMemberships')
            .where('userId', isEqualTo: userId)
            .get();

    DateTime toDateTime(dynamic v) => _firestoreService.timestampToDateTime(v);

    return snap.docs.map((doc) {
      final data = doc.data();
      // Timestamp → ISO string 정규화 (fromJson이 string을 기대)
      if (data['requestedAt'] != null) {
        data['requestedAt'] = toDateTime(data['requestedAt']).toIso8601String();
      }
      if (data['approvedAt'] != null) {
        data['approvedAt'] = toDateTime(data['approvedAt']).toIso8601String();
      }
      if (data['rejectedAt'] != null) {
        data['rejectedAt'] = toDateTime(data['rejectedAt']).toIso8601String();
      }
      return PlaceMembership.fromJson(data);
    }).toList();
  }

  PlaceMembership _pickPreferredMembership(
    PlaceMembership a,
    PlaceMembership b,
  ) {
    // status 제거로 항상 멤버이므로, 시간 정보가 있는 쪽/더 최신을 선호
    DateTime? timeOf(PlaceMembership m) {
      if (m.approvedAt != null) return m.approvedAt;
      return m.requestedAt;
    }

    final ta = timeOf(a);
    final tb = timeOf(b);
    if (ta == null || tb == null) return a;
    return ta.isAfter(tb) ? a : b;
  }

  /// 인증 완료 후 공통 처리
  /// 관리자도 일반 사용자로 처리하여 다른 플레이스의 멤버가 될 수 있도록 함
  Future<AuthResult> _completeAuthentication(models.User user) async {
    // 자동 매칭 시도 (관리자도 일반 사용자로 처리)
    final newlyCreated = await _autoMatchMemberships(
      user.userId,
      user.phoneNumber,
    );

    // ✅ 기존 placeMemberships까지 합쳐서 "전체 멤버십"을 구성해야 한다.
    // (pendingMembers가 없으면 _autoMatchMemberships는 []를 반환하므로)
    final existing = await _fetchPlaceMembershipsForUser(user.userId);

    final byPlaceId = <String, PlaceMembership>{};
    for (final m in existing) {
      byPlaceId[m.placeId] = m;
    }
    for (final m in newlyCreated) {
      final prev = byPlaceId[m.placeId];
      byPlaceId[m.placeId] =
          prev == null ? m : _pickPreferredMembership(prev, m);
    }

    final memberships = byPlaceId.values.toList();

    // status 제거로 항상 멤버이므로 모든 멤버십이 승인된 것으로 처리
    final approvedMemberships = memberships;
    final pendingMemberships = <PlaceMembership>[];

    // 서버에서 마지막 접속 플레이스 확인 (currentPlaceId)
    String? lastPlaceId = user.currentPlaceId;
    // 서버에 없으면 로컬에서 읽어오기 (마이그레이션용)
    if (lastPlaceId == null) {
      lastPlaceId = await _storageService.getUserLastAccessedPlaceId();
      // 로컬에 있으면 서버에도 저장 (마이그레이션)
      if (lastPlaceId != null) {
        await _userService.updateCurrentPlaceId(user.userId, lastPlaceId);
      }
    }

    // 관리자 여부 확인 (역할 정보만, 일반 사용자로도 처리 가능)
    final isAdmin = await _checkIfAdmin(user.userId);
    final role = isAdmin ? UserRole.admin : UserRole.member;

    return AuthResult(
      user: user,
      role: role,
      memberships: memberships,
      approvedMemberships: approvedMemberships,
      pendingMemberships: pendingMemberships,
      lastAccessedPlaceId: lastPlaceId,
    );
  }

  // ==================== 기존 메서드들 (하위 호환성) ====================

  /// 전화번호로 사용자 로그인/회원가입
  ///
  /// [deprecated] verifyCodeAndSignIn 사용 권장
  @Deprecated('verifyCodeAndSignIn을 사용하세요')
  Future<AuthResult> authenticateWithPhone({
    required String phoneNumber,
    required String verificationCode,
    String? name, // 회원가입 시 필요
  }) async {
    // 기존 로직 유지 (하위 호환성)
    // 1. 인증 코드 확인
    final isValid = await verifyCode(phoneNumber, verificationCode);
    if (!isValid) {
      throw Exception('인증 코드가 올바르지 않습니다.');
    }

    // 2. 사용자 조회 또는 생성
    models.User? user = await findUserByPhone(phoneNumber);

    if (user == null) {
      // 신규 사용자 - 회원가입
      if (name == null || name.trim().isEmpty) {
        throw Exception('회원가입을 위해 이름이 필요합니다.');
      }
      user = await _createUser(phoneNumber: phoneNumber, name: name);
    }

    return await _completeAuthentication(user);
  }

  /// 인증 코드 확인 (기존 방식)
  ///
  /// [deprecated] Firebase Auth 사용 권장
  @Deprecated('Firebase Auth를 사용하세요')
  Future<bool> verifyCode(String phoneNumber, String code) async {
    // TODO: 실제 인증 코드 확인 로직
    throw UnimplementedError('인증 코드 확인 기능을 구현해주세요.');
  }

  // ==================== 사용자 관리 ====================

  /// 전화번호로 사용자 찾기
  /// 전화번호로 사용자 찾기 (public)
  Future<models.User?> findUserByPhone(String phoneNumber) async {
    // 임시로 직접 접근
    final firestore = _firestoreService.firestore;
    final query = firestore
        .collection('users')
        .where('phoneNumber', isEqualTo: phoneNumber)
        .limit(1);

    final snapshot = await query.get();
    if (snapshot.docs.isEmpty) return null;

    final data = snapshot.docs.first.data();
    // Timestamp 변환 처리
    if (data['createdAt'] != null) {
      data['createdAt'] =
          _firestoreService
              .timestampToDateTime(data['createdAt'])
              .toIso8601String();
    }
    if (data['updatedAt'] != null) {
      data['updatedAt'] =
          _firestoreService
              .timestampToDateTime(data['updatedAt'])
              .toIso8601String();
    }
    return models.User.fromJson(data);
  }

  /// 신규 사용자 생성
  Future<models.User> _createUser({
    String? userId, // Firebase Auth UID 사용 시
    required String phoneNumber,
    required String name,
  }) async {
    final finalUserId = userId ?? _generateUserId();

    final user = models.User(
      userId: finalUserId,
      name: name,
      phoneNumber: phoneNumber,
      createdAt: TimezoneUtils.getSeoulDateTime(),
    );

    // UserService를 통해 저장
    final userService = UserService();
    return await userService.createUserFromModel(user);
  }

  /// 관리자 여부 확인
  Future<bool> _checkIfAdmin(String userId) async {
    try {
      final userService = UserService();
      final admin = await userService.getAdmin(userId);
      return admin != null;
    } catch (e) {
      return false;
    }
  }

  /// 전화번호로 관리자 찾기
  Future<AdminUser?> findAdminByPhone(String phoneNumber) async {
    // Firestore에 저장된 값과 동일한 방식으로 정규화해서 조회
    final normalizedPhone = _normalizePhoneNumber(phoneNumber);
    final userService = UserService();
    return await userService.getAdminByPhone(normalizedPhone);
  }

  // ==================== 관리자 인증 ====================

  /// 관리자 전화번호 인증 및 로그인 (PIN 포함)
  ///
  /// 1. 전화번호 인증 확인
  /// 2. adminUsers 컬렉션에서 전화번호 확인
  /// 3. PIN 확인
  /// 4. 등록되지 않으면 에러
  /// 5. 등록되어 있으면 관리자 로그인
  Future<AuthResult> authenticateAdmin({
    required String phoneNumber,
    required String verificationCode,
    required String pin,
  }) async {
    try {
      // 입력값 검증
      if (phoneNumber.isEmpty) {
        throw Exception('전화번호가 필요합니다.');
      }
      if (pin.isEmpty) {
        throw Exception('PIN이 필요합니다.');
      }

      // 전화번호 정규화 (Cloud Function과 동일한 방식)
      final normalizedPhone = _normalizePhoneNumber(phoneNumber);

      debugPrint(
        '[AuthService.authenticateAdmin] phoneNumber: "$phoneNumber" -> normalized: "$normalizedPhone"',
      );
      debugPrint(
        '[AuthService.authenticateAdmin] pin: "$pin" (length: ${pin.length})',
      );
      debugPrint(
        '[AuthService.authenticateAdmin] verificationCode: "$verificationCode" (length: ${verificationCode.length})',
      );

      // Cloud Function 호출
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('authenticateAdmin');

      final result = await callable.call({
        'phoneNumber': normalizedPhone,
        'verificationCode': verificationCode,
        'pin': pin,
      });

      final data = result.data as Map<String, dynamic>;

      if (data['success'] == true) {
        // Cloud Function에서 성공 응답 받음
        final adminUserId = data['userId'] as String;
        final adminName = data['name'] as String;
        final adminPhoneNumber = data['phoneNumber'] as String;
        final adminPlaceIds =
            (data['placeIds'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            [];

        // 4. 관리자 정보로 AdminUser 생성 및 로그인
        final admin = AdminUser(
          userId: adminUserId,
          name: adminName,
          phoneNumber: adminPhoneNumber,
          placeIds: adminPlaceIds,
          createdAt: TimezoneUtils.getSeoulDateTime(),
          updatedAt: TimezoneUtils.getSeoulDateTime(),
        );
        await _adminService.loginWithAdmin(admin);

        // 5. 자동 로그인을 위한 정보 저장 (PIN은 저장하지 않음)
        await _storageService.saveAdminPhone(phoneNumber);
        await _storageService.saveAdminUserId(adminUserId);

        // 6. AdminUser를 User로 변환 (AuthResult 호환성)
        // User.placeIds는 더 이상 사용하지 않음 (빈 배열로 설정)
        final user = models.User(
          userId: adminUserId,
          name: adminName,
          phoneNumber: adminPhoneNumber,
          placeIds: [], // User.placeIds는 더 이상 사용하지 않음
          createdAt: TimezoneUtils.getSeoulDateTime(),
          updatedAt: TimezoneUtils.getSeoulDateTime(),
        );

        return AuthResult(user: user, role: UserRole.admin, memberships: []);
      } else {
        throw Exception('관리자 인증에 실패했습니다.');
      }
    } on FirebaseFunctionsException catch (e) {
      // Cloud Function 에러 처리
      String errorMessage = e.message ?? '관리자 인증 중 오류가 발생했습니다.';

      // 에러 코드에 따른 메시지 처리
      switch (e.code) {
        case 'permission-denied':
          errorMessage = 'PIN이 올바르지 않습니다.';
          break;
        case 'not-found':
          errorMessage = '관리자로 등록되지 않은 전화번호입니다.';
          break;
        case 'failed-precondition':
          errorMessage = 'PIN이 등록되지 않았습니다. PIN 등록이 필요합니다.';
          break;
        case 'unauthenticated':
          errorMessage = '인증 코드가 올바르지 않습니다.';
          break;
        case 'invalid-argument':
          errorMessage = '입력 정보가 올바르지 않습니다.';
          break;
        default:
          errorMessage = e.message ?? '관리자 인증 중 오류가 발생했습니다.';
      }

      throw Exception(errorMessage);
    } catch (e) {
      // 연결 오류 등 기타 에러
      final errorString = e.toString();
      if (errorString.contains('connection') ||
          errorString.contains('channel')) {
        throw Exception('서버 연결에 실패했습니다. 네트워크 연결을 확인하고 앱을 재시작해주세요.');
      }
      throw Exception('관리자 인증 중 오류가 발생했습니다: ${e.toString()}');
    }
  }

  /// 관리자 회원가입 (전화번호 인증 후 PIN 등록)
  ///
  /// 1. 전화번호 인증 확인
  /// 2. AdminUser 생성
  /// 3. PIN 저장
  Future<AdminUser> registerAdmin({
    required String phoneNumber,
    required String verificationCode,
    required String name,
    required String pin,
  }) async {
    // adminUsers는 rules에서 클라이언트 create/update가 막혀있으므로
    // Cloud Function으로만 등록한다.
    final normalizedPhone = _normalizePhoneNumber(phoneNumber);

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'registerAdminPin',
      );
      final res = await callable.call({
        'phoneNumber': normalizedPhone,
        'verificationCode': verificationCode, // 서버에서 참조하지 않지만 로깅용
        'name': name,
        'pin': pin,
      });
      final data = (res.data as Map).cast<String, dynamic>();
      if (data['success'] != true) {
        throw Exception('관리자 코드 등록에 실패했습니다.');
      }

      final admin = AdminUser(
        userId: data['userId'] as String,
        name: data['name'] as String? ?? name,
        phoneNumber: data['phoneNumber'] as String? ?? normalizedPhone,
        authPin: pin,
        placeIds:
            (data['placeIds'] as List<dynamic>? ?? [])
                .map((e) => e.toString())
                .toList(),
        createdAt: TimezoneUtils.getSeoulDateTime(),
        updatedAt: TimezoneUtils.getSeoulDateTime(),
      );

      return admin;
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'already-exists') {
        throw Exception('이미 등록된 관리자입니다.');
      }
      if (e.code == 'permission-denied') {
        throw Exception('전화번호가 일치하지 않습니다.');
      }
      throw Exception(e.message ?? '관리자 코드 등록 중 오류가 발생했습니다.');
    }
  }

  /// 관리자 PIN 업데이트
  Future<AdminUser> updateAdminPin({
    required String userId,
    required String newPin,
  }) async {
    final admin = await _adminService.getAdmin(userId);

    final updatedAdmin = admin.copyWith(
      authPin: newPin, // 실제로는 해시화 필요
      updatedAt: TimezoneUtils.getSeoulDateTime(),
    );

    final userService = UserService();
    await userService.updateAdmin(updatedAdmin);
    return updatedAdmin;
  }

  /// 관리자 등록 (슈퍼 관리자 또는 초기 설정)
  ///
  /// 새로운 관리자를 adminUsers 컬렉션에 등록
  /// 베타 버전: placeIds는 항상 빈 배열로 시작
  Future<AdminUser> createAdmin({
    required String phoneNumber,
    required String name,
    required String createdBy, // 슈퍼 관리자 ID 또는 시스템
    List<String>? placeIds,
  }) async {
    // 이미 등록된 전화번호인지 확인
    final existing = await findAdminByPhone(phoneNumber);
    if (existing != null) {
      throw Exception('이미 등록된 관리자입니다.');
    }

    // 베타 버전: placeIds는 무시하고 항상 빈 배열로 시작
    // 일반 사용자로도 등록되어 있는지 확인
    final existingUser = await findUserByPhone(phoneNumber);
    final userId = existingUser?.userId ?? _generateUserId();

    // AdminUser 생성 (베타 버전: placeIds는 항상 빈 배열)
    final admin = AdminUser(
      userId: userId,
      name: name,
      phoneNumber: phoneNumber,
      placeIds: [], // 베타 버전: 항상 빈 배열로 시작
      createdAt: TimezoneUtils.getSeoulDateTime(),
    );

    // UserService를 통해 저장
    final userService = UserService();
    await userService.createAdmin(admin);

    return admin;
  }

  /// 사용자 ID 생성 (임시)
  ///
  /// 실제로는 Firebase Auth UID 사용 권장
  String _generateUserId() {
    return 'user_${DateTime.now().millisecondsSinceEpoch}';
  }

  // ==================== 자동 매칭 ====================

  /// 전화번호로 자동 매칭
  ///
  /// pendingMembers 컬렉션에서 전화번호로 검색하여
  /// PlaceMembership 생성
  Future<List<PlaceMembership>> _autoMatchMemberships(
    String userId,
    String phoneNumber,
  ) async {
    // pendingMembers에서 전화번호로 검색
    final firestore = _firestoreService.firestore;
    final query = firestore
        .collection('pendingMembers')
        .where('phoneNumber', isEqualTo: phoneNumber);

    final snapshot = await query.get();

    if (snapshot.docs.isEmpty) {
      return []; // 매칭 안됨
    }

    final memberships = <PlaceMembership>[];

    // 트랜잭션으로 처리
    // ✅ 중복 확인은 트랜잭션 내부에서 수행 (race condition 방지)
    await firestore.runTransaction((transaction) async {
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final placeId = data['placeId'] as String;
        final autoApprove = data['autoApprove'] as bool? ?? true;

        // PlaceMembership 생성 (중복 방지: placeId+userId로 고정 ID 사용)
        final membershipId = '${placeId}_$userId';
        final membershipRef = firestore
            .collection('placeMemberships')
            .doc(membershipId);

        // ✅ 트랜잭션 내부에서도 중복 확인 (race condition 방지)
        final existingMembership = await transaction.get(membershipRef);
        if (existingMembership.exists) {
          // 이미 있으면 스킵
          continue;
        }

        final now = TimezoneUtils.getSeoulDateTime();
        final membership = PlaceMembership(
          id: membershipId,
          userId: userId,
          placeId: placeId,
          requestedAt: now,
          approvedAt: autoApprove ? now : now, // status 제거로 항상 approvedAt 설정
          invitedBy: data['createdBy'] as String?,
        );

        // PlaceMembership 저장 (Timestamp 변환)
        final membershipData = membership.toJson();
        final timestamp = _firestoreService.dateTimeToTimestamp(now);
        membershipData['requestedAt'] = timestamp.toDate().toIso8601String();
        if (membership.approvedAt != null) {
          membershipData['approvedAt'] = timestamp.toDate().toIso8601String();
        }

        transaction.set(membershipRef, membershipData);

        // users.placeIds는 더 이상 사용하지 않음 (courseMembers 기반으로 조회)

        // ✅ pendingMembers는 클라이언트에서 삭제하지 않는다.
        // - 일반 유저는 rules상 pendingMembers delete 권한이 없음(트랜잭션 실패 위험)
        // - 관리자(겸용) 계정은 delete가 가능해서, 오히려 서버 트리거(onPlaceMembershipCreated)가
        //   pendingMembers를 못 찾아 enrollments 생성이 누락되는 문제가 생길 수 있음
        // - pendingMembers 정리는 서버 트리거가 담당한다.

        memberships.add(membership);
      }
    });

    return memberships;
  }

  // ==================== 플레이스 멤버십 관리 ====================

  /// 승인된 플레이스 목록 가져오기 (status 제거로 모든 멤버십이 승인된 것으로 처리)
  Future<List<Place>> getApprovedPlaces(String userId) async {
    final firestore = _firestoreService.firestore;
    final memberships =
        await firestore
            .collection('placeMemberships')
            .where('userId', isEqualTo: userId)
            .get();

    final placeIds =
        memberships.docs.map((doc) => doc.data()['placeId'] as String).toList();

    if (placeIds.isEmpty) return [];

    // Place 정보 가져오기
    final places = <Place>[];
    for (final placeId in placeIds) {
      final place = await _firestoreService.getPlace(placeId);
      if (place != null) {
        places.add(place);
      }
    }

    return places;
  }

  /// Pending 상태 멤버십 목록 가져오기 (status 제거로 빈 리스트 반환)
  Future<List<PlaceMembership>> getPendingMemberships(String userId) async {
    // status 제거로 항상 멤버이므로 빈 리스트 반환
    return [];
  }

  /// 플레이스 가입 요청
  Future<PlaceMembership> requestPlaceMembership({
    required String userId,
    required String placeId,
    String? message,
  }) async {
    // 이미 멤버십이 있는지 확인
    final existing = await _checkExistingMembership(userId, placeId);
    if (existing != null) {
      throw Exception('이미 가입 요청하거나 승인된 플레이스입니다.');
    }

    // PlaceMembership 생성
    final firestore = _firestoreService.firestore;
    final membershipRef = firestore.collection('placeMemberships').doc();

    final now = TimezoneUtils.getSeoulDateTime();
    final membership = PlaceMembership(
      id: membershipRef.id,
      userId: userId,
      placeId: placeId,
      requestedAt: now,
      approvedAt: now, // status 제거로 항상 approvedAt 설정
    );

    final membershipData = membership.toJson();
    final timestamp = _firestoreService.dateTimeToTimestamp(now);
    // Firestore에 저장할 때는 Timestamp로 변환
    membershipData['requestedAt'] = timestamp;
    membershipData['approvedAt'] = timestamp;

    await membershipRef.set(membershipData);

    // TODO: 관리자에게 알림 (Cloud Functions)

    return membership;
  }

  /// 기존 멤버십 확인
  Future<PlaceMembership?> _checkExistingMembership(
    String userId,
    String placeId,
  ) async {
    final firestore = _firestoreService.firestore;
    final query = firestore
        .collection('placeMemberships')
        .where('userId', isEqualTo: userId)
        .where('placeId', isEqualTo: placeId)
        .limit(1);

    final snapshot = await query.get();
    if (snapshot.docs.isEmpty) return null;

    final data = snapshot.docs.first.data();
    // Timestamp 변환
    if (data['requestedAt'] != null) {
      data['requestedAt'] =
          _firestoreService
              .timestampToDateTime(data['requestedAt'])
              .toIso8601String();
    }
    if (data['approvedAt'] != null) {
      data['approvedAt'] =
          _firestoreService
              .timestampToDateTime(data['approvedAt'])
              .toIso8601String();
    }
    if (data['rejectedAt'] != null) {
      data['rejectedAt'] =
          _firestoreService
              .timestampToDateTime(data['rejectedAt'])
              .toIso8601String();
    }
    return PlaceMembership.fromJson(data);
  }

  /// 현재 플레이스 설정
  Future<void> setCurrentPlace(Place place) async {
    _currentPlace = place;

    // 서버에 현재 플레이스 ID 저장
    final currentUser = _userService.currentUser;
    if (currentUser != null) {
      await _userService.updateCurrentPlaceId(currentUser.userId, place.id);
    }

    // ✅ 일반(멤버) 모드로 접속했음을 저장 (자동 로그인 시 모드 복원)
    await _storageService.saveLastEntryMode('member');
  }

  /// 로그아웃
  Future<void> logout() async {
    // Firebase Auth 세션 정리
    await _auth.signOut();

    _currentPlace = null;
    _userService.logout();
    _adminService.logout();

    // 사용자 데이터 삭제
    await _storageService.clearUserData();

    // 관리자 데이터도 삭제 (일반 사용자 로그아웃 시에도 관리자 자동 로그인 방지)
    await _storageService.clearAdminData();

    // 마지막 접속 모드 삭제 (완전 로그아웃)
    await _storageService.clearLastEntryMode();

    // 인증 상태 스트림 초기화
    _authStateStream = null;
  }
}

/// 인증 결과
class AuthResult {
  final models.User user;
  final UserRole role;
  final List<PlaceMembership> memberships;
  final List<PlaceMembership> approvedMemberships;
  final List<PlaceMembership> pendingMemberships;
  final String? lastAccessedPlaceId; // 마지막 접속한 플레이스 ID

  AuthResult({
    required this.user,
    required this.role,
    required this.memberships,
    this.approvedMemberships = const [],
    this.pendingMemberships = const [],
    this.lastAccessedPlaceId,
  });

  /// 승인된 플레이스가 있는지
  bool get hasApprovedPlaces => approvedMemberships.isNotEmpty;

  /// Pending 상태만 있는지
  bool get hasOnlyPending =>
      memberships.isNotEmpty && approvedMemberships.isEmpty;

  /// 플레이스가 없는지
  bool get hasNoPlaces => memberships.isEmpty;
}

/// 인증 상태
class AuthState {
  final bool isAuthenticated;
  final models.User? user;
  final UserRole? role;
  final List<PlaceMembership>? memberships;

  AuthState._({
    required this.isAuthenticated,
    this.user,
    this.role,
    this.memberships,
  });

  factory AuthState.authenticated({
    required models.User user,
    required UserRole role,
    List<PlaceMembership>? memberships,
  }) {
    return AuthState._(
      isAuthenticated: true,
      user: user,
      role: role,
      memberships: memberships,
    );
  }

  factory AuthState.unauthenticated() {
    return AuthState._(isAuthenticated: false);
  }
}

/// 사용자 역할
enum UserRole { admin, member }

/// 관리자 자동 로그인 결과
class AdminAutoLoginResult {
  final AdminUser admin;
  final String? lastAccessedPlaceId;

  AdminAutoLoginResult({required this.admin, this.lastAccessedPlaceId});
}
