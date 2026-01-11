# 자동 로그인 가이드

## 🔐 Firebase Auth 자동 로그인

Firebase Auth는 **자동으로 인증 상태를 유지**합니다. 별도의 로컬 저장소 관리가 필요 없습니다!

---

## ✅ Firebase Auth의 자동 로그인 기능

### 1. 인증 상태 자동 유지

Firebase Auth는 다음을 자동으로 처리합니다:

- ✅ **인증 상태 저장**: 로그인 후 자동으로 로컬에 저장
- ✅ **앱 재시작 시 복원**: 앱을 다시 열면 자동으로 인증 상태 복원
- ✅ **세션 관리**: 토큰 만료 시 자동 갱신
- ✅ **크로스 디바이스**: 같은 계정으로 여러 기기에서 사용 가능

### 2. 전화번호 인증 플로우

```
1. 사용자: 전화번호 입력
   ↓
2. Firebase Auth: SMS 코드 발송
   ↓
3. 사용자: 인증 코드 입력
   ↓
4. Firebase Auth: 인증 완료 → 자동으로 인증 상태 저장
   ↓
5. 앱 재시작 시: Firebase Auth가 자동으로 인증 상태 복원
```

---

## 📱 구현 방법

### 1. Firebase Auth 설정

```dart
// pubspec.yaml
dependencies:
  firebase_auth: ^4.15.0
  firebase_core: ^2.24.0
```

```dart
// main.dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MyApp());
}
```

### 2. 전화번호 인증 코드 발송

```dart
final FirebaseAuth _auth = FirebaseAuth.instance;

Future<void> sendVerificationCode(String phoneNumber) async {
  await _auth.verifyPhoneNumber(
    phoneNumber: phoneNumber,
    verificationCompleted: (PhoneAuthCredential credential) async {
      // Android에서 자동 인증 완료 (SMS 자동 읽기)
      await _auth.signInWithCredential(credential);
    },
    verificationFailed: (FirebaseAuthException e) {
      throw Exception('인증 실패: ${e.message}');
    },
    codeSent: (String verificationId, int? resendToken) {
      // verificationId를 저장 (SharedPreferences 등)
      // 나중에 인증 코드 확인 시 사용
    },
    codeAutoRetrievalTimeout: (String verificationId) {
      // 자동 인증 타임아웃
    },
  );
}
```

### 3. 인증 코드 확인 및 로그인

```dart
Future<void> verifyCodeAndSignIn({
  required String verificationId,
  required String smsCode,
}) async {
  // 인증 정보 생성
  final credential = PhoneAuthProvider.credential(
    verificationId: verificationId,
    smsCode: smsCode,
  );

  // Firebase Auth에 로그인 (자동으로 인증 상태 저장됨)
  final userCredential = await _auth.signInWithCredential(credential);
  final firebaseUser = userCredential.user;

  if (firebaseUser == null) {
    throw Exception('인증에 실패했습니다.');
  }

  // 이제 firebaseUser.phoneNumber로 사용자 정보 조회
  // Firestore에서 사용자 정보 가져오기
}
```

### 4. 앱 시작 시 자동 로그인 확인

```dart
Future<AuthResult?> checkAutoLogin() async {
  // Firebase Auth가 자동으로 인증 상태를 유지하므로
  // currentUser로 현재 인증된 사용자 확인 가능
  final firebaseUser = _auth.currentUser;

  if (firebaseUser == null) {
    return null; // 로그인 안됨
  }

  // 전화번호로 사용자 조회
  final phoneNumber = firebaseUser.phoneNumber!;
  final user = await _findUserByPhone(phoneNumber);

  if (user == null) {
    return null; // Firestore에 사용자 정보 없음
  }

  // 인증 완료 처리
  return await _completeAuthentication(user);
}
```

### 5. 인증 상태 변경 감지

```dart
Stream<AuthState> authStateChanges() {
  return _auth.authStateChanges().asyncMap((firebaseUser) async {
    if (firebaseUser == null) {
      return AuthState.unauthenticated();
    }

    // 인증된 사용자 처리
    final phoneNumber = firebaseUser.phoneNumber!;
    final user = await _findUserByPhone(phoneNumber);

    if (user == null) {
      return AuthState.unauthenticated();
    }

    // 사용자 정보 로드 및 처리
    return AuthState.authenticated(user: user, ...);
  });
}
```

---

## 🎯 앱 시작 시 플로우

### main.dart에서 자동 로그인 처리

```dart
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final AuthService _authService = AuthService();
  AuthResult? _authResult;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkAutoLogin();
  }

  Future<void> _checkAutoLogin() async {
    try {
      // 자동 로그인 확인
      final result = await _authService.checkAutoLogin();
      
      setState(() {
        _authResult = result;
        _isLoading = false;
      });

      if (result != null) {
        // 자동 로그인 성공 → 적절한 화면으로 이동
        _navigateToAppropriateScreen(result);
      } else {
        // 로그인 안됨 → 로그인 화면
        _navigateToLogin();
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      _navigateToLogin();
    }
  }

  void _navigateToAppropriateScreen(AuthResult result) {
    if (result.role == UserRole.admin) {
      // 관리자 화면
      Navigator.pushReplacementNamed(context, '/admin');
    } else if (result.hasApprovedPlaces) {
      // 멤버 화면 (승인된 플레이스 있음)
      Navigator.pushReplacementNamed(context, '/main');
    } else if (result.hasOnlyPending) {
      // 승인 대기 화면
      Navigator.pushReplacementNamed(context, '/pending');
    } else {
      // 플레이스 검색 화면
      Navigator.pushReplacementNamed(context, '/place-search');
    }
  }

  void _navigateToLogin() {
    Navigator.pushReplacementNamed(context, '/login');
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const MaterialApp(
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return MaterialApp(
      // ... 기존 설정
    );
  }
}
```

---

## 🔄 인증 상태 스트림 구독

### 실시간 인증 상태 감지

```dart
class AuthWrapper extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final authService = AuthService();

    return StreamBuilder<AuthState>(
      stream: authService.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final authState = snapshot.data;

        if (authState == null || !authState.isAuthenticated) {
          return LoginScreen();
        }

        // 인증된 사용자 → 적절한 화면으로
        if (authState.role == UserRole.admin) {
          return AdminScreen();
        } else {
          return MainScreen();
        }
      },
    );
  }
}
```

---

## 📋 주요 포인트

### ✅ Firebase Auth가 자동으로 처리하는 것

1. **인증 상태 저장**: 로그인 후 자동으로 로컬에 저장
2. **세션 유지**: 앱 재시작 시 자동으로 복원
3. **토큰 갱신**: 만료 시 자동 갱신
4. **보안**: 암호화된 방식으로 저장

### ❌ 별도로 해야 할 것

1. **사용자 정보 저장**: Firestore에 사용자 정보 저장 (Firebase Auth는 인증만)
2. **플레이스 멤버십**: 자동 매칭 및 관리
3. **UI 라우팅**: 인증 상태에 따른 화면 이동

---

## 🎯 결론

**Firebase Auth를 사용하면 자동 로그인이 자동으로 지원됩니다!**

- ✅ 별도의 로컬 저장소 관리 불필요
- ✅ `_auth.currentUser`로 현재 인증 상태 확인
- ✅ `authStateChanges()`로 실시간 감지
- ✅ 앱 재시작 시 자동 복원

**구현 시 주의사항:**
- Firebase Auth는 **인증만** 담당
- 사용자 정보는 **Firestore**에 별도 저장 필요
- 인증 후 Firestore에서 사용자 정보 조회하여 처리

