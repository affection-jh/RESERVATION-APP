# 자동 로그인 화면 전환 플로우 모식도

## 전체 플로우 개요

```
AppStartupScreen (스플래시)
    ↓
_checkAutoLogin()
    ↓
[케이스별 분기]
```

---

## 케이스 1: 명시적 재로그인 (requireManualEntrySelection=true)

```
AppStartupScreen
    ↓
requireManualEntrySelection = true?
    ↓ YES
Firebase 세션 존재?
    ↓ YES
PlaceWaitingScreen
    (사용자가 수동으로 플레이스/역할 선택)
```

**조건:**
- 전화번호 인증 직후
- Firebase 세션이 존재

---

## 케이스 2: 관리자 자동 로그인 성공 (lastEntryMode='admin')

```
AppStartupScreen
    ↓
lastEntryMode = 'admin'
    ↓
checkAdminAutoLogin() 시도
    ↓
성공 ✅
    ↓
_prepareAdminScreen()
    ↓
관리자 플레이스 확인
    ├─ 플레이스 없음 → PlaceWaitingScreen
    └─ 플레이스 있음
        ↓
        마지막 접속 플레이스 확인
        ├─ 있음 & 유효 → 해당 플레이스 사용
        ├─ 있음 & 무효 → 첫 번째 플레이스 사용
        └─ 없음 → 첫 번째 플레이스 사용
        ↓
        플레이스 로드 & 설정
        ↓
        AdminScreen
```

**조건:**
- `lastEntryMode = 'admin'`
- 관리자 자동 로그인 성공
- 관리자 정보 조회 성공

---

## 케이스 3: 관리자 자동 로그인 실패 → 일반 사용자 시도 (lastEntryMode='admin')

```
AppStartupScreen
    ↓
lastEntryMode = 'admin'
    ↓
checkAdminAutoLogin() 시도
    ↓
실패 ❌
    ↓
checkUserAutoLogin() 시도
    ↓
[일반 사용자 자동 로그인 플로우로 이동]
```

---

## 케이스 4: 일반 사용자 자동 로그인 성공 → 관리자 역할 감지 (lastEntryMode='member' 또는 null)

```
AppStartupScreen
    ↓
lastEntryMode = 'member' 또는 null
    ↓
checkUserAutoLogin() 시도
    ↓
성공 ✅
    ↓
userResult.role = UserRole.admin?
    ↓ YES
관리자 정보 조회 (findAdminByPhone)
    ↓
관리자 정보 찾음?
    ↓ YES
관리자 플로우로 전환
    ↓
AdminAutoLoginResult 생성
    ↓
_prepareAdminScreen()
    ↓
[케이스 2의 _prepareAdminScreen 플로우와 동일]
```

**조건:**
- 일반 사용자 자동 로그인 성공
- `userResult.role = UserRole.admin`
- 관리자 정보 조회 성공

**중요:** 이 케이스가 수정된 부분입니다. 관리자 역할이 감지되면 관리자 플로우로 전환합니다.

---

## 케이스 5: 일반 사용자 자동 로그인 성공 (일반 사용자만, lastEntryMode='member' 또는 null)

```
AppStartupScreen
    ↓
lastEntryMode = 'member' 또는 null
    ↓
checkUserAutoLogin() 시도
    ↓
성공 ✅
    ↓
userResult.role = UserRole.admin?
    ↓ NO
연결된 관리자 계정 확인 (선택적)
    ↓
_prepareUserScreen()
    ↓
승인된 플레이스 확인
    ├─ 없음 → PlaceWaitingScreen
    └─ 있음
        ↓
        마지막 접속 플레이스 확인
        ├─ 있음 & 승인됨 → 해당 플레이스 사용
        ├─ 있음 & 미승인 → 첫 번째 승인된 플레이스 사용
        └─ 없음 → 첫 번째 승인된 플레이스 사용
        ↓
        플레이스 로드 & 설정
        ↓
        MainScreen
```

**조건:**
- 일반 사용자 자동 로그인 성공
- `userResult.role != UserRole.admin` 또는 관리자 정보 조회 실패

---

## 케이스 6: 일반 사용자 자동 로그인 실패 → 관리자 시도 (lastEntryMode='member')

```
AppStartupScreen
    ↓
lastEntryMode = 'member'
    ↓
checkUserAutoLogin() 시도
    ↓
실패 ❌
    ↓
checkAdminAutoLogin() 시도
    ↓
[관리자 자동 로그인 플로우로 이동]
```

---

## 케이스 7: 자동 로그인 완전 실패 (lastEntryMode=null)

```
AppStartupScreen
    ↓
lastEntryMode = null
    ↓
checkUserAutoLogin() 시도
    ↓
실패 ❌
    ↓
checkAdminAutoLogin() 시도
    ↓
실패 ❌
    ↓
Firebase 세션 확인
    ├─ 있음 → PlaceWaitingScreen
    └─ 없음 → PhoneNumberInputScreen
```

**조건:**
- 모든 자동 로그인 시도 실패
- Firebase 세션 존재 여부에 따라 분기

---

## 케이스 8: 에러 발생

```
AppStartupScreen
    ↓
_checkAutoLogin() 중 에러 발생
    ↓
Firebase 세션 확인
    ├─ 있음 → PlaceWaitingScreen
    └─ 없음 → PhoneNumberInputScreen
```

**조건:**
- 예외 발생 (네트워크 오류, Firestore 오류 등)
- 인증 세션은 유지 (세션을 깨지 않음)

---

## _prepareAdminScreen 상세 플로우

```
_prepareAdminScreen(AdminAutoLoginResult)
    ↓
AuthProvider.setCurrentAdmin()
    ↓
관리자 플레이스 목록 확인
    ├─ 비어있음 → PlaceWaitingScreen
    └─ 있음
        ↓
        마지막 접속 플레이스 확인
        ├─ 있음 & 유효 → 사용
        ├─ 있음 & 무효 → 첫 번째 플레이스 사용
        └─ 없음 → 첫 번째 플레이스 사용
        ↓
        플레이스 로드
        ├─ 성공 → PlaceProvider 설정, lastAccessedPlaceId 저장
        └─ 실패 → 에러 로그만 출력 (AdminScreen으로 이동)
        ↓
        알림 비동기 로드 (블로킹 안 함)
        ↓
        AdminScreen
```

---

## _prepareUserScreen 상세 플로우

```
_prepareUserScreen(AuthResult)
    ↓
마지막 접속 플레이스 확인
    ├─ 있음 → Firestore에서 승인 여부 확인
    └─ 없음 → 첫 번째 승인된 플레이스 사용
    ↓
승인된 플레이스 확인
    ├─ 없음 → PlaceWaitingScreen
    └─ 있음
        ↓
        플레이스 로드
        ├─ 성공 → PlaceProvider 설정, lastAccessedPlaceId 저장
        └─ 실패 → 에러 로그만 출력 (MainScreen으로 이동)
        ↓
        스토리/프로모션 선로딩
        ↓
        이미지 프리캐시
        ↓
        알림 비동기 로드 (블로킹 안 함)
        ↓
        MainScreen
```

---

## lastEntryMode 우선순위 로직

```
lastEntryMode 확인
    ├─ 'admin' → 관리자 먼저 시도 → 실패 시 일반 사용자 시도
    ├─ 'member' → 일반 사용자 먼저 시도 → 실패 시 관리자 시도
    └─ null → 일반 사용자 먼저 시도 → 실패 시 관리자 시도
```

---

## 주요 개선 사항 (최근 수정)

### ✅ 관리자 역할 감지 시 자동 전환

**이전:**
- 일반 사용자 자동 로그인 성공 → 관리자 역할 감지 → 일반 사용자 플로우 계속 진행
- 결과: 관리자가 `PlaceWaitingScreen`으로 이동 (승인된 멤버십이 없음)

**현재:**
- 일반 사용자 자동 로그인 성공 → 관리자 역할 감지 → 관리자 정보 조회 성공 → **관리자 플로우로 전환**
- 결과: 관리자가 `AdminScreen`으로 이동 (관리자 플레이스로)

---

## 화면 목록

1. **AppStartupScreen** - 스플래시 및 자동 로그인 체크
2. **PlaceWaitingScreen** - 플레이스/역할 선택 대기
3. **PhoneNumberInputScreen** - 전화번호 입력 (초기 로그인)
4. **AdminScreen** - 관리자 홈 화면
5. **MainScreen** - 일반 사용자 홈 화면

---

## 상태 저장

### lastEntryMode
- `'admin'`: 마지막 접속이 관리자 모드
- `'member'`: 마지막 접속이 일반 사용자 모드
- `null`: 저장된 정보 없음

### lastAccessedPlaceId
- 관리자: `StorageService` + `AdminUser.lastAccessedPlaceId`
- 일반 사용자: `User.lastAccessedPlaceId`

### requireManualEntrySelection
- `true`: 전화번호 인증 직후, 자동 분기 금지
- `false`: 일반 자동 로그인 허용

