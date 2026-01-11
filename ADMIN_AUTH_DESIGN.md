# 관리자(Admin) 가입 및 인증 설계

## 🎯 관리자 인증 방식

### 옵션 비교

| 방식 | 보안 | 편의성 | 구현 복잡도 | 추천도 |
|------|------|--------|------------|--------|
| 전화번호 인증 + adminUsers 확인 | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| 관리자 코드 + 전화번호 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| 이메일 + 비밀번호 | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| 슈퍼 관리자 승인 | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |

---

## ✅ 추천 방식: 전화번호 인증 + adminUsers 확인

### 핵심 아이디어
**관리자는 미리 등록된 전화번호만 로그인 가능**

### 플로우

```
1. 관리자: 전화번호 입력
   ↓
2. SMS 인증 코드 발송
   ↓
3. 인증 코드 확인
   ↓
4. adminUsers 컬렉션에서 전화번호 확인
   ↓
5-1. 등록됨 → 관리자 로그인 성공
5-2. 등록 안됨 → "관리자로 등록되지 않은 번호입니다" 에러
```

### 장점
- ✅ 일반 사용자와 동일한 인증 방식 (일관성)
- ✅ 전화번호만으로 간단하게 인증
- ✅ adminUsers 컬렉션으로 관리자 권한 제어
- ✅ 구현 간단

---

## 🔄 대안: 관리자 코드 방식

### 플로우

```
1. 관리자: 전화번호 입력
   ↓
2. SMS 인증 코드 발송
   ↓
3. 인증 코드 확인
   ↓
4. 관리자 코드 입력 화면
   ↓
5. 관리자 코드 확인
   ↓
6. adminUsers 생성 또는 확인
   ↓
7. 관리자 로그인 성공
```

### 장점
- ✅ 추가 보안 레이어
- ✅ 관리자 코드로 접근 제어

### 단점
- ❌ 관리자 코드 관리 필요
- ❌ 코드 유출 시 보안 위험

---

## 📋 최종 추천: 전화번호 인증 + adminUsers 확인

### 데이터 구조

#### adminUsers 컬렉션
```
adminUsers/{userId}
├── userId: string
├── phoneNumber: string
├── name: string
├── email: string?
├── placeIds: string[]  // 관리하는 플레이스 목록
├── role: "admin" | "super_admin"  // 역할 (선택적)
├── createdAt: timestamp
└── isActive: boolean  // 활성화 여부
```

### 인증 플로우

#### 1. 관리자 로그인
```dart
Future<AuthResult> authenticateAdmin({
  required String phoneNumber,
  required String verificationCode,
}) async {
  // 1. 전화번호 인증 확인
  final isValid = await verifyCode(phoneNumber, verificationCode);
  if (!isValid) {
    throw Exception('인증 코드가 올바르지 않습니다.');
  }

  // 2. adminUsers에서 전화번호 확인
  final admin = await _findAdminByPhone(phoneNumber);
  
  if (admin == null) {
    throw Exception('관리자로 등록되지 않은 전화번호입니다.');
  }

  if (!admin.isActive) {
    throw Exception('비활성화된 관리자 계정입니다.');
  }

  // 3. 관리자 로그인
  await _adminService.login(admin.userId);

  return AuthResult(
    user: admin.toUser(), // AdminUser를 User로 변환
    role: UserRole.admin,
    memberships: [],
  );
}
```

#### 2. 관리자 등록 (슈퍼 관리자 또는 초기 설정)

```dart
/// 슈퍼 관리자가 새 관리자 등록
Future<AdminUser> createAdmin({
  required String phoneNumber,
  required String name,
  required String createdBy, // 슈퍼 관리자 ID
  String? email,
  List<String>? placeIds,
}) async {
  // 이미 등록된 전화번호인지 확인
  final existing = await _findAdminByPhone(phoneNumber);
  if (existing != null) {
    throw Exception('이미 등록된 관리자입니다.');
  }

  // AdminUser 생성
  final admin = AdminUser(
    userId: _generateUserId(),
    name: name,
    phoneNumber: phoneNumber,
    email: email,
    placeIds: placeIds ?? [],
    createdAt: DateTime.now(),
    isActive: true,
  );

  // Firestore에 저장
  await _firestoreService.createAdmin(admin);

  return admin;
}
```

---

## 🎯 구현 전략

### Phase 1: 기본 인증 (즉시)
1. 전화번호 인증
2. adminUsers 컬렉션 확인
3. 등록되지 않으면 에러

### Phase 2: 관리자 등록 (추가)
1. 슈퍼 관리자 화면
2. 관리자 추가 기능
3. 권한 관리

### Phase 3: 고급 기능 (선택)
1. 관리자 코드
2. 역할 기반 권한
3. 활동 로그

---

## 📱 화면 플로우

### 관리자 로그인 화면

```
[관리자 로그인]
    ↓
[전화번호 입력]
    ↓
[SMS 인증 코드 발송]
    ↓
[인증 코드 입력]
    ↓
[adminUsers 확인]
    ↓
[등록됨] → 관리자 화면
[등록 안됨] → "관리자로 등록되지 않은 번호입니다"
```

### 슈퍼 관리자 화면 (관리자 등록)

```
[슈퍼 관리자 화면]
    ↓
[관리자 추가]
    ↓
[전화번호, 이름 입력]
    ↓
[플레이스 선택]
    ↓
[관리자 등록]
    ↓
[adminUsers에 저장]
```

---

## 🔐 보안 고려사항

### 1. 관리자 등록 제한
- 슈퍼 관리자만 새 관리자 등록 가능
- 또는 초기 설정 시에만 등록

### 2. 전화번호 검증
- 실제 전화번호인지 SMS 인증으로 확인
- 중복 등록 방지

### 3. 비활성화 기능
- 관리자 계정 비활성화 가능
- `isActive: false`로 설정

### 4. 역할 기반 권한 (선택)
- `super_admin`: 모든 권한 + 관리자 등록
- `admin`: 플레이스 관리만

---

## 💡 초기 관리자 설정

### 방법 1: 수동 등록
```
1. Firestore 콘솔에서 직접 adminUsers 문서 생성
2. 전화번호, 이름 등 입력
3. isActive: true 설정
```

### 방법 2: 초기 설정 화면
```
1. 앱 첫 실행 시 초기 관리자 등록 화면
2. 전화번호, 이름 입력
3. SMS 인증
4. adminUsers에 저장 (role: "super_admin")
```

### 방법 3: 환경 변수
```
1. .env 파일에 초기 관리자 전화번호 설정
2. 앱 시작 시 자동으로 adminUsers에 등록
```

---

## 🚀 구현 예시

### AuthService에 관리자 인증 추가

```dart
/// 관리자 전화번호 인증
Future<AuthResult> authenticateAdmin({
  required String phoneNumber,
  required String verificationCode,
}) async {
  // 1. 전화번호 인증 확인
  final isValid = await verifyCode(phoneNumber, verificationCode);
  if (!isValid) {
    throw Exception('인증 코드가 올바르지 않습니다.');
  }

  // 2. adminUsers에서 전화번호 확인
  final admin = await _findAdminByPhone(phoneNumber);
  
  if (admin == null) {
    throw Exception('관리자로 등록되지 않은 전화번호입니다.');
  }

  if (!admin.isActive) {
    throw Exception('비활성화된 관리자 계정입니다.');
  }

  // 3. 관리자 로그인
  await _adminService.login(admin.userId);

  return AuthResult(
    user: admin.toUser(),
    role: UserRole.admin,
    memberships: [],
  );
}

/// 전화번호로 관리자 찾기
Future<AdminUser?> _findAdminByPhone(String phoneNumber) async {
  final firestore = _firestoreService.firestore;
  final query = firestore
      .collection('adminUsers')
      .where('phoneNumber', isEqualTo: phoneNumber)
      .limit(1);

  final snapshot = await query.get();
  if (snapshot.docs.isEmpty) return null;

  final data = snapshot.docs.first.data();
  // Timestamp 변환
  if (data['createdAt'] != null) {
    data['createdAt'] = _firestoreService
        .timestampToDateTime(data['createdAt'])
        .toIso8601String();
  }
  
  return AdminUser.fromJson(data);
}
```

---

## 📝 결론

### 추천 방식
**전화번호 인증 + adminUsers 확인**

### 이유
1. ✅ 일반 사용자와 동일한 인증 방식
2. ✅ 구현 간단
3. ✅ adminUsers 컬렉션으로 권한 제어
4. ✅ 전화번호만으로 간단하게 인증

### 구현 순서
1. adminUsers 컬렉션 구조 확인
2. 관리자 인증 메서드 추가
3. 관리자 로그인 화면
4. 슈퍼 관리자 화면 (관리자 등록)

