import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/user.dart' as models;
import '../models/place.dart';
import 'firestore_service.dart';
import 'user_service.dart';
import 'member_service.dart';
import '../utils/phone_utils.dart';
import '../utils/local_storage_util.dart';
import '../utils/timezone_utils.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth show User;
import 'package:cloud_firestore/cloud_firestore.dart';
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
  final StorageService _storageService = StorageService();

  // Firebase Auth 인스턴스 (getter로 변경하여 늦은 초기화)
  // Firebase.initializeApp() 완료 후에만 접근하도록 함
  FirebaseAuth get _auth => FirebaseAuth.instance;

  // 현재 Firebase 사용자 (외부 접근용)
  firebase_auth.User? get currentFirebaseUser => _auth.currentUser;

  // Web PhoneAuth: signInWithPhoneNumber 결과(캡챠 완료 후 confirm에 필요)
  ConfirmationResult? _webConfirmationResult;
  // Web: 같은 번호로 이미 발송한 경우 재호출 시 리캡챠 없이 재사용 (이중 호출/재발송 시 리캡챠 중복 방지)
  String? _webLastSentPhone;

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

    // ✅ Web은 verifyPhoneNumber 미지원 → signInWithPhoneNumber만 사용 (매번 reCAPTCHA 표시).
    //    앱 개발 시 리캡챠 없이 테스트하려면 iOS 시뮬레이터/Android 에뮬레이터 또는 실기기에서 실행하세요.
    if (kIsWeb) {
      try {
        // 이미 같은 번호로 발송 완료된 경우 리캡챠 없이 기존 결과 재사용 (이중 호출/재발송 시 리캡챠 중복 방지)
        if (_webConfirmationResult != null &&
            _webLastSentPhone == formattedPhone) {
          final verificationId = _webConfirmationResult!.verificationId;
          debugPrint(
            '[AuthService.sendVerificationCode] (web) 기존 발송 결과 재사용 (리캡챠 스킵)',
          );
          await _storageService.saveVerificationId(verificationId, phoneNumber);
          return verificationId;
        }

        debugPrint(
          '[AuthService.sendVerificationCode] (web) signInWithPhoneNumber 호출 시작...',
        );
        final confirmationResult = await _auth.signInWithPhoneNumber(
          formattedPhone,
        );
        _webConfirmationResult = confirmationResult;
        _webLastSentPhone = formattedPhone;

        final verificationId = confirmationResult.verificationId;
        debugPrint('[AuthService.sendVerificationCode] (web) ✅ 완료');
        debugPrint(
          '[AuthService.sendVerificationCode] (web) verificationId: "${verificationId.substring(0, verificationId.length > 20 ? 20 : verificationId.length)}..." (length: ${verificationId.length})',
        );

        // 다른 플로우와 일관성 유지 (저장소에도 보관)
        await _storageService.saveVerificationId(verificationId, phoneNumber);
        return verificationId;
      } on FirebaseAuthException catch (e) {
        debugPrint('[AuthService.sendVerificationCode] (web) ❌ 실패');
        debugPrint('[AuthService.sendVerificationCode] (web) 에러 코드: ${e.code}');
        debugPrint(
          '[AuthService.sendVerificationCode] (web) 에러 메시지: ${e.message}',
        );

        // web 전용 사용자 친화 메시지
        if (e.code == 'web-context-cancelled') {
          throw Exception('캡챠(인증) 창이 닫혔습니다. 다시 시도해주세요.');
        }
        if (e.code == 'popup-blocked') {
          throw Exception('팝업이 차단되어 인증을 진행할 수 없습니다. 팝업 차단을 해제해주세요.');
        }
        if (e.code == 'too-many-requests') {
          throw Exception('너무 많은 요청이 발생했습니다. 잠시 후 다시 시도해주세요.');
        }
        if (e.code == 'invalid-phone-number') {
          throw Exception('전화번호 형식이 올바르지 않습니다.');
        }
        throw Exception('인증 실패: ${e.message ?? e.code}');
      }
    }

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
            // 플랫폼/사용자 취소 등 사용자 친화 메시지
            if (e.code == 'channel-error') {
              completer.completeError(
                Exception('인증 서비스 초기화 중입니다. 잠시 후 다시 시도해주세요.'),
              );
            } else if (e.code == 'web-context-cancelled' ||
                (e.message != null &&
                    e.message!.toLowerCase().contains(
                      'cancelled by the user',
                    ))) {
              completer.completeError(Exception('인증이 취소되었습니다. 다시 시도해주세요.'));
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
        completer.completeError(Exception('인증 코드 발송 시간이 초과되었습니다.\n다시 시도해주세요.'));
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
      try {
        // ✅ Web: ConfirmationResult.confirm()
        if (kIsWeb) {
          final confirmationResult = _webConfirmationResult;
          if (confirmationResult == null) {
            throw Exception('인증 ID를 찾을 수 없습니다. 인증 코드를 다시 요청해주세요.');
          }
          debugPrint(
            '[AuthService.verifyCodeAndSignIn] (web) confirm 호출 시작...',
          );
          final userCredential = await confirmationResult.confirm(smsCode);
          debugPrint('[AuthService.verifyCodeAndSignIn] (web) ✅ confirm 성공');
          firebaseUser = userCredential.user;
        } else {
          // Native: verificationId + smsCode로 credential 생성
          final finalVerificationId =
              verificationId ?? await _storageService.getVerificationId();

          final preview =
              (finalVerificationId == null || finalVerificationId.isEmpty)
                  ? 'null/empty'
                  : '${finalVerificationId.substring(0, finalVerificationId.length > 20 ? 20 : finalVerificationId.length)}...';
          debugPrint(
            '[AuthService.verifyCodeAndSignIn] finalVerificationId: "$preview" (length: ${finalVerificationId?.length ?? 0})',
          );

          if (finalVerificationId == null || finalVerificationId.isEmpty) {
            debugPrint(
              '[AuthService.verifyCodeAndSignIn] ❌ verificationId를 찾을 수 없음',
            );
            throw Exception('인증 ID를 찾을 수 없습니다. 인증 코드를 다시 요청해주세요.');
          }

          final credential = PhoneAuthProvider.credential(
            verificationId: finalVerificationId,
            smsCode: smsCode,
          );

          debugPrint(
            '[AuthService.verifyCodeAndSignIn] signInWithCredential 호출 시작...',
          );
          final userCredential = await _auth.signInWithCredential(credential);
          debugPrint(
            '[AuthService.verifyCodeAndSignIn] ✅ signInWithCredential 성공',
          );
          firebaseUser = userCredential.user;
        }
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
        // 잘못된 인증 코드: 재입력 가능하도록 verificationId 유지
        if (e.code == 'invalid-verification-code') {
          throw Exception('인증번호가 올바르지 않습니다.');
        }
        // 세션 만료(또는 verificationId 무효): 재발송 필요
        if (e.code == 'session-expired' ||
            e.code == 'invalid-verification-id') {
          await _storageService.clearVerificationData();
          _webConfirmationResult = null;
          _webLastSentPhone = null;
          debugPrint(
            '[AuthService.verifyCodeAndSignIn] verificationId 삭제 완료 (세션 만료/무효)',
          );
          throw Exception('인증 시간이 만료되었습니다. 인증번호를 다시 요청해주세요.');
        }
        rethrow;
      } catch (e, stackTrace) {
        debugPrint('[AuthService.verifyCodeAndSignIn] ❌ 예상치 못한 에러 발생');
        debugPrint('[AuthService.verifyCodeAndSignIn] 에러 타입: ${e.runtimeType}');
        debugPrint('[AuthService.verifyCodeAndSignIn] 에러 내용: $e');
        debugPrint('[AuthService.verifyCodeAndSignIn] 스택 트레이스: $stackTrace');
        rethrow;
      }
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

    finalPhoneNumber = PhoneUtils.normalize(finalPhoneNumber);
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
        authUid: firebaseUser.uid,
        phoneNumber: finalPhoneNumber,
        name: name,
      );
    } else {
      // 기존 사용자: Firestore 규칙이 users/request.auth.uid 존재를 요구하므로,
      // 예전 문서 ID(user_123 등)만 있는 경우 users/{auth.uid} 문서를 생성해 둠.
      // (pendingMembers 읽기 시 hasUserDoc() && phoneNumber 일치로 권한 통과)
      if (user.userId != firebaseUser.uid) {
        await _ensureAuthUidUserDoc(
          authUid: firebaseUser.uid,
          phoneNumber: finalPhoneNumber,
          username: user.username,
        );
      }
    }

    // 인증 정보 삭제
    await _storageService.clearVerificationData();
    _webConfirmationResult = null;
    _webLastSentPhone = null;

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
    _webConfirmationResult = null;
    _webLastSentPhone = null;
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
      phoneNumber = PhoneUtils.normalize(phoneNumber);

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

  /// 로그아웃 (관리자/멤버 통합: 저장소 정리 + Firebase signOut)
  Future<void> logoutAdmin() async {
    debugPrint('[AuthService.logoutAdmin] 시작');
    try {
      debugPrint('[AuthService.logoutAdmin] clearAdminData 호출');
      await _storageService.clearAdminData();
      debugPrint('[AuthService.logoutAdmin] 완료');
    } catch (e, stackTrace) {
      debugPrint('[AuthService.logoutAdmin] ❌ 에러: $e');
      debugPrint('[AuthService.logoutAdmin] 스택: $stackTrace');
      rethrow;
    }
  }

  /// 최근 접속한 플레이스 업데이트 (User.currentPlaceId + 로컬 저장소)
  /// AppStartup에서 getLastAccessedPlaceId()로 복원하므로 로컬 저장 필수
  Future<void> updateLastAccessedPlace(String placeId) async {
    await _storageService.saveLastAccessedPlaceId(placeId);
    final savedUserId = await _storageService.getAdminUserId();
    if (savedUserId != null) {
      await _userService.updateCurrentPlaceId(savedUserId, placeId);
    }
    await _storageService.saveLastEntryMode('admin');
  }

  /// 마지막 접속 모드 조회 (admin/member)
  Future<String?> getLastEntryMode() async {
    return await _storageService.getLastEntryMode();
  }

  /// 마지막 접속 플레이스 ID (매니저용)
  Future<String?> getLastAccessedPlaceId() async {
    return await _storageService.getLastAccessedPlaceId();
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
            phoneNumber = PhoneUtils.normalize(phoneNumber);

            // 사용자 조회
            final user = await findUserByPhone(phoneNumber);
            if (user == null) {
              return AuthState.unauthenticated();
            }

            // 관리자(매니저) 여부: places/{placeId}/members 기반
            final isAdmin = await _checkIfAdmin(user.userId);
            if (isAdmin) {
              return AuthState.authenticated(user: user, role: UserRole.admin);
            }

            await _autoMatchMemberships(user.userId, phoneNumber);
            await _userService.login(user.userId);

            final placeIds = await _fetchPlaceIdsForUser(user.userId);
            return AuthState.authenticated(
              user: user,
              role: UserRole.member,
              placeIds: placeIds,
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

  /// 접근 가능 플레이스: places/{placeId}/members 기준 (enrollment 아님)
  Future<List<String>> _fetchPlaceIdsForUser(String userId) async {
    final members = await MemberService().getPlaceMembershipsForUser(userId);
    final placeIds = members
        .map((m) => m.placeId)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    return placeIds.toList();
  }

  /// 인증 완료 후 공통 처리
  /// 관리자도 일반 사용자로 처리하여 다른 플레이스의 멤버가 될 수 있도록 함
  Future<AuthResult> _completeAuthentication(models.User user) async {
    // places/.../members 기준이므로 현재 인증 UID 사용
    final authUid = _auth.currentUser?.uid;
    final effectiveUserId = authUid ?? user.userId;

    // 자동 매칭 시도 (Auth UID로 생성해야 규칙 통과)
    await _autoMatchMemberships(effectiveUserId, user.phoneNumber);

    // 기존 + 신규 placeId 목록
    final existing = await _fetchPlaceIdsForUser(effectiveUserId);
    final placeIds = existing.toSet().toList();

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
      placeIds: placeIds,
      lastAccessedPlaceId: lastPlaceId,
    );
  }

  // ==================== 사용자 관리 ====================

  /// 전화번호로 사용자 찾기
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
    final d = Map<String, dynamic>.from(data);
    // name 필드 제거, username만 사용 (읽기 호환: name → username 폴백)
    if (d['username'] == null && d['name'] != null) {
      d['username'] = d['name'];
    }
    return models.User.fromJson(d);
  }

  /// 전화번호로 관리자(매니저) 사용자 조회. 없으면 null.
  Future<models.User?> findAdminByPhone(String phoneNumber) async {
    final user = await findUserByPhone(PhoneUtils.normalize(phoneNumber));
    if (user == null) return null;
    final isAdmin = await _checkIfAdmin(user.userId);
    return isAdmin ? user : null;
  }

  /// users/{authUid} 문서 생성 (Firestore 규칙 hasUserDoc() 통과용)
  Future<void> _ensureAuthUidUserDoc({
    required String authUid,
    required String phoneNumber,
    required String username,
  }) async {
    final firestore = _firestoreService.firestore;
    await firestore.collection('users').doc(authUid).set({
      'userId': authUid,
      'phoneNumber': phoneNumber,
      'username': username,
      'updatedAt': _firestoreService.dateTimeToTimestamp(
        TimezoneUtils.getSeoulDateTime(),
      ),
    }, SetOptions(merge: true));
  }

  /// 신규 사용자 생성 (createUserDoc Callable 사용, Firebase Auth UID 기반)
  Future<models.User> _createUser({
    required String authUid,
    required String phoneNumber,
    required String name,
  }) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('createUserDoc')
        .call({'username': name.trim(), 'phoneNumber': phoneNumber});
    final data = result.data as Map<String, dynamic>;
    final createdAt =
        data['createdAt'] != null
            ? DateTime.parse(data['createdAt'] as String)
            : TimezoneUtils.getSeoulDateTime();
    final username = data['username'] as String? ?? data['name'] as String? ?? '';
    return models.User(
      userId: data['userId'] as String,
      username: username,
      phoneNumber: data['phoneNumber'] as String,
      createdAt: createdAt,
    );
  }

  /// 관리자(매니저/부매니저) 여부: places/{placeId}/members에서 판별
  Future<bool> _checkIfAdmin(String userId) async {
    try {
      final list = await MemberService().getPlaceMembershipsForUser(userId);
      return list.any((m) => m.canManagePlace);
    } catch (e) {
      return false;
    }
  }

  // ==================== 자동 매칭 ====================

  /// 전화번호로 자동 매칭: pendingMembers → enrollments (Callable 호출)
  /// 서버·pendingMembers와 동일 형식(0 + 10자리)으로 보내야 쿼리 매칭됨
  Future<void> _autoMatchMemberships(String userId, String phoneNumber) async {
    try {
      final normalized = PhoneUtils.normalizeForStorage(phoneNumber);
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createEnrollmentsFromPendingMembers',
      );
      await callable.call({'phoneNumber': normalized});
    } catch (e) {
      debugPrint('[AuthService._autoMatchMemberships] callable error: $e');
    }
  }

  // ==================== 플레이스 멤버십 관리 ====================

  /// 승인된 플레이스 목록 (places/{placeId}/members 기준, enrollment 아님)
  Future<List<Place>> getApprovedPlaces(String userId) async {
    final members = await MemberService().getPlaceMembershipsForUser(userId);
    final placeIds = members
        .map((m) => m.placeId)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (placeIds.isEmpty) return [];

    final places = <Place>[];
    for (final placeId in placeIds) {
      final place = await _firestoreService.getPlace(placeId);
      if (place != null) places.add(place);
    }
    return places;
  }

  /// 플레이스 가입 요청 (pendingMember만 생성, 승인 시 enrollments로 멤버됨)
  Future<void> requestPlaceMembership({
    required String userId,
    required String placeId,
    String? message,
  }) async {
    final existing = await _hasPlaceAccess(userId, placeId);
    if (existing) {
      throw Exception('이미 가입 요청하거나 승인된 플레이스입니다.');
    }

    final firestore = _firestoreService.firestore;
    final userDoc = await firestore.collection('users').doc(userId).get();
    final phoneNumber = userDoc.data()?['phoneNumber'] as String?;
    if (phoneNumber == null || phoneNumber.isEmpty) {
      throw Exception('전화번호가 없어 가입 요청을 할 수 없습니다.');
    }

    final now = TimezoneUtils.getSeoulDateTime();
    final normalizedPhone = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
    final normalized =
        normalizedPhone.startsWith('82')
            ? '0${normalizedPhone.substring(2)}'
            : normalizedPhone.startsWith('0')
            ? normalizedPhone
            : '0$normalizedPhone';
    final pendingId = '${placeId}_$normalized';
    final pendingRef = firestore
        .collection('places')
        .doc(placeId)
        .collection('pendingMembers')
        .doc(pendingId);
    await pendingRef.set({
      'placeId': placeId,
      'phoneNumber': normalized,
      'invitedBy': userId,
      'role': 'member',
      'allowedCourseIds': [],
      'userId': userId,
      'createdAt': _firestoreService.dateTimeToTimestamp(now),
      'updatedAt': _firestoreService.dateTimeToTimestamp(now),
    }, SetOptions(merge: true));
  }

  /// 기존 멤버십 확인 (enrollment 존재 여부)
  Future<bool> _hasPlaceAccess(String userId, String placeId) async {
    final firestore = _firestoreService.firestore;
    final snap =
        await firestore
            .collection('enrollments')
            .where('userId', isEqualTo: userId)
            .where('placeId', isEqualTo: placeId)
            .limit(1)
            .get();
    return snap.docs.isNotEmpty;
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
    // ✅ 멤버 마지막 접속 플레이스 로컬 저장 (관리자→멤버 전환 직후 AppStartup에서 복원)
    await _storageService.saveUserLastAccessedPlaceId(place.id);
  }

  /// 로그아웃 (일반 로그아웃 및 회원탈퇴 완료 후 호출)
  Future<void> logout() async {
    debugPrint('[AuthService.logout] 시작');
    try {
      // Firebase Auth 세션 정리
      debugPrint('[AuthService.logout] Firebase Auth signOut 호출');
      await _auth.signOut();
      debugPrint('[AuthService.logout] Firebase Auth signOut 완료');

      _currentPlace = null;
      debugPrint('[AuthService.logout] _userService.logout() 호출');
      _userService.logout();
      // 사용자 데이터 삭제
      debugPrint('[AuthService.logout] clearUserData 호출');
      await _storageService.clearUserData();

      // 관리자 데이터도 삭제 (일반 사용자 로그아웃 시에도 관리자 자동 로그인 방지)
      debugPrint('[AuthService.logout] clearAdminData 호출');
      await _storageService.clearAdminData();

      // 마지막 접속 모드 삭제 (완전 로그아웃)
      debugPrint('[AuthService.logout] clearLastEntryMode 호출');
      await _storageService.clearLastEntryMode();

      // 수동 진입 선택 플래그 삭제 (다음 기동 시 PlaceWaiting으로 정상 분기)
      await _storageService.clearRequireManualEntrySelection();

      // 인증 상태 스트림 초기화
      _authStateStream = null;
      debugPrint('[AuthService.logout] 완료');
    } catch (e, stackTrace) {
      debugPrint('[AuthService.logout] ❌ 에러: $e');
      debugPrint('[AuthService.logout] 스택: $stackTrace');
      rethrow;
    }
  }
}

/// 인증 결과
class AuthResult {
  final models.User user;
  final UserRole role;
  final List<String> placeIds;
  final String? lastAccessedPlaceId;

  AuthResult({
    required this.user,
    required this.role,
    required this.placeIds,
    this.lastAccessedPlaceId,
  });

  bool get hasApprovedPlaces => placeIds.isNotEmpty;
  bool get hasNoPlaces => placeIds.isEmpty;
}

/// 인증 상태
class AuthState {
  final bool isAuthenticated;
  final models.User? user;
  final UserRole? role;
  final List<String>? placeIds;

  AuthState._({
    required this.isAuthenticated,
    this.user,
    this.role,
    this.placeIds,
  });

  factory AuthState.authenticated({
    required models.User user,
    required UserRole role,
    List<String>? placeIds,
  }) {
    return AuthState._(
      isAuthenticated: true,
      user: user,
      role: role,
      placeIds: placeIds ?? [],
    );
  }

  factory AuthState.unauthenticated() {
    return AuthState._(isAuthenticated: false);
  }
}

/// 사용자 역할
enum UserRole { admin, member }
