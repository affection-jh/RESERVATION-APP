# 네비게이션 정책 분석 및 개선 제안

## 현재 네비게이션 메서드 사용 현황

### 1. AppStartupScreen (스플래시)
**방식:** Navigator 미사용, `setState`로 `_targetScreen` 변경
```dart
setState(() {
  _targetScreen = const AdminScreen(); // 또는 MainScreen, PlaceWaitingScreen 등
});
```
**평가:** ✅ 적절함 - 스플래시는 스택에 포함되지 않는 특수한 화면

---

### 2. 로그인/회원가입 플로우

#### VerificationCodeScreen → PlaceWaitingScreen
```dart
Navigator.of(context).pushReplacementNamed(
  '/place-waiting',
  arguments: widget.phoneNumber,
);
```
**평가:** ⚠️ 문제 가능성
- `pushReplacementNamed`는 현재 화면만 교체 (이전 화면 1개만 제거)
- PhoneNumberInputScreen이 스택에 남아있을 수 있음
- **권장:** `pushNamedAndRemoveUntil('/place-waiting', (route) => false)` 사용

#### NameInputScreen → PlaceWaitingScreen
```dart
Navigator.of(context).pushNamedAndRemoveUntil(
  '/place-waiting',
  (route) => false,
  arguments: widget.phoneNumber,
);
```
**평가:** ✅ 적절함 - 모든 이전 화면 제거

---

### 3. PlaceWaitingScreen → MainScreen/AdminScreen

#### 일반 사용자 플레이스 선택 후
```dart
Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
```
**평가:** ✅ 적절함 - 모든 이전 화면 제거

#### 관리자 PIN 입력 후
```dart
// 플레이스 없음
Navigator.of(context).pushAndRemoveUntil(
  MaterialPageRoute(
    builder: (context) => AdminPlaceRegistrationScreen(...),
  ),
  (route) => false,
);

// 플레이스 있음
Navigator.of(context).pushAndRemoveUntil(
  MaterialPageRoute(builder: (context) => const AdminScreen()),
  (route) => false,
);
```
**평가:** ✅ 적절함 - 모든 이전 화면 제거

---

### 4. 관리자 플레이스 등록 플로우

#### AdminPlaceRegistrationScreen → AdminGreetingSettingScreen
```dart
Navigator.of(context).push(
  MaterialPageRoute(
    builder: (context) => AdminGreetingSettingScreen(...),
  ),
);
```
**평가:** ✅ 적절함 - 뒤로가기 가능 (사용자가 정보 수정 가능)

#### AdminGreetingSettingScreen → AdminScreen (플레이스 등록 완료)
```dart
Navigator.of(context).pushAndRemoveUntil(
  MaterialPageRoute(
    builder: (context) => const AdminScreen(),
  ),
  (route) => false,
);
```
**평가:** ✅ 적절함 - 모든 이전 화면 제거

#### AdminPlaceRegistrationScreen 뒤로가기 (기존 관리자가 플레이스 추가)
```dart
Navigator.of(context).pushReplacementNamed('/admin');
```
**평가:** ⚠️ 문제 가능성
- `pushReplacementNamed`는 현재 화면만 교체
- AdminPlaceRegistrationScreen 위에 다른 화면이 있을 수 있음
- **권장:** `pushNamedAndRemoveUntil('/admin', (route) => false)` 사용

---

### 5. 로그아웃

#### PlaceWaitingScreen에서 로그아웃
```dart
Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
```
**평가:** ✅ 적절함 - 모든 화면 제거 후 AppStartupScreen으로

#### MyPageScreen에서 로그아웃
```dart
Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
```
**평가:** ✅ 적절함

---

## 네비게이션 메서드별 사용 가이드

### `push` - 일반적인 화면 이동
**사용 시기:**
- 뒤로가기가 필요한 경우
- 상세 화면, 설정 화면 등

**예시:**
- AdminPlaceRegistrationScreen → AdminGreetingSettingScreen ✅

---

### `pushReplacement` / `pushReplacementNamed` - 현재 화면만 교체
**사용 시기:**
- 현재 화면을 대체하고 싶지만, 이전 화면은 유지
- **주의:** 스택에 이전 화면이 남아있을 수 있음

**현재 사용:**
- VerificationCodeScreen → PlaceWaitingScreen ⚠️
- AdminPlaceRegistrationScreen 뒤로가기 → AdminScreen ⚠️

**권장 변경:**
- 대부분의 경우 `pushNamedAndRemoveUntil` 사용 권장

---

### `pushAndRemoveUntil` / `pushNamedAndRemoveUntil` - 모든 이전 화면 제거
**사용 시기:**
- 로그인/회원가입 완료 후
- 플레이스 선택 후
- 로그아웃 후
- **핵심 화면으로 이동할 때**

**현재 사용:**
- NameInputScreen → PlaceWaitingScreen ✅
- PlaceWaitingScreen → MainScreen ✅
- AdminPinInputScreen → AdminScreen ✅
- AdminGreetingSettingScreen → AdminScreen ✅
- 로그아웃 → AppStartupScreen ✅

---

## 발견된 문제점

### 1. VerificationCodeScreen → PlaceWaitingScreen
**현재:**
```dart
Navigator.of(context).pushReplacementNamed('/place-waiting', ...);
```

**문제:**
- PhoneNumberInputScreen이 스택에 남아있을 수 있음
- 뒤로가기 시 PhoneNumberInputScreen으로 돌아갈 수 있음

**권장 수정:**
```dart
Navigator.of(context).pushNamedAndRemoveUntil(
  '/place-waiting',
  (route) => false,
  arguments: widget.phoneNumber,
);
```

---

### 2. AdminPlaceRegistrationScreen 뒤로가기
**현재:**
```dart
Navigator.of(context).pushReplacementNamed('/admin');
```

**문제:**
- AdminPlaceRegistrationScreen 위에 다른 화면이 있을 수 있음
- 스택이 깨끗하지 않을 수 있음

**권장 수정:**
```dart
Navigator.of(context).pushNamedAndRemoveUntil(
  '/admin',
  (route) => false,
);
```

---

## 네비게이션 정책 권장 사항

### ✅ 권장 패턴

1. **로그인/회원가입 완료 후**
   ```dart
   Navigator.pushNamedAndRemoveUntil(context, '/target', (route) => false);
   ```

2. **플레이스/역할 선택 후**
   ```dart
   Navigator.pushNamedAndRemoveUntil(context, '/main', (route) => false);
   // 또는
   Navigator.pushNamedAndRemoveUntil(context, '/admin', (route) => false);
   ```

3. **로그아웃 후**
   ```dart
   Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
   ```

4. **뒤로가기가 필요한 화면 이동**
   ```dart
   Navigator.push(context, MaterialPageRoute(...));
   ```

5. **현재 화면만 교체 (드물게 사용)**
   ```dart
   Navigator.pushReplacementNamed(context, '/target');
   // 주의: 이전 화면이 스택에 남을 수 있음
   ```

---

## 수정이 필요한 파일

### 1. `lib/screens/verification_code_screen.dart`
**라인 146:**
```dart
// 현재
Navigator.of(context).pushReplacementNamed(
  '/place-waiting',
  arguments: widget.phoneNumber,
);

// 권장
Navigator.of(context).pushNamedAndRemoveUntil(
  '/place-waiting',
  (route) => false,
  arguments: widget.phoneNumber,
);
```

### 2. `lib/screens/admin/widgets/admin_place_registration_screen.dart`
**라인 218:**
```dart
// 현재
Navigator.of(context).pushReplacementNamed('/admin');

// 권장
Navigator.of(context).pushNamedAndRemoveUntil(
  '/admin',
  (route) => false,
);
```

---

## 체크리스트

### ✅ 잘 사용되고 있는 케이스
- [x] NameInputScreen → PlaceWaitingScreen
- [x] PlaceWaitingScreen → MainScreen
- [x] AdminPinInputScreen → AdminScreen
- [x] AdminGreetingSettingScreen → AdminScreen
- [x] 로그아웃 → AppStartupScreen
- [x] AdminPlaceRegistrationScreen → AdminGreetingSettingScreen (push)

### ⚠️ 수정이 필요한 케이스
- [ ] VerificationCodeScreen → PlaceWaitingScreen
- [ ] AdminPlaceRegistrationScreen 뒤로가기 → AdminScreen

---

## 결론

대부분의 네비게이션은 적절하게 사용되고 있으나, **2가지 케이스에서 `pushReplacementNamed` 대신 `pushNamedAndRemoveUntil`을 사용하는 것이 권장됩니다.**

이렇게 하면:
1. 스택이 깨끗하게 유지됨
2. 뒤로가기 시 예상치 못한 화면으로 돌아가는 문제 방지
3. 일관성 있는 네비게이션 정책 유지

