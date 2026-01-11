# 서브컬렉션 마이그레이션 계획

## 📋 목표
히스토리 데이터(`reenrollmentHistory`, `adminActions`, `extensionRequests`)를 배열 필드에서 서브컬렉션으로 분리하여 페이지네이션 지원

## 🗄️ 새로운 Firestore 구조

### 변경 전 (현재)
```
enrollments/{enrollmentId}
├── 기본 정보...
├── reenrollmentHistory: []  ← 배열 필드
├── adminActions: []         ← 배열 필드
└── extensionRequests: []    ← 배열 필드
```

### 변경 후 (목표)
```
enrollments/{enrollmentId}
├── 기본 정보만 (히스토리 제외)
│
├── reenrollmentHistory/{recordId}  ← 서브컬렉션
│   ├── enrollmentNumber: number
│   ├── totalReservations: number
│   ├── enrolledAt: timestamp
│   ├── validFrom: timestamp
│   ├── validUntil: timestamp
│   └── cancelledAt?: timestamp
│
├── adminActions/{actionId}  ← 서브컬렉션
│   ├── actionType: string
│   ├── performedAt: timestamp
│   ├── performedBy: string
│   ├── details?: string
│   ├── oldValue?: map
│   └── newValue?: map
│
└── extensionRequests/{requestId}  ← 서브컬렉션
    ├── requestedAt: timestamp
    ├── reason: string
    ├── status: string
    ├── approvedAt?: timestamp
    ├── rejectedAt?: timestamp
    └── rejectionReason?: string
```

## 🔄 마이그레이션 전략

### Phase 1: 이중 쓰기 (호환성 유지)
- 새 데이터는 서브컬렉션과 배열 필드 모두에 저장
- 읽기는 배열 필드 우선, 없으면 서브컬렉션에서 읽기

### Phase 2: 읽기 전환
- 모든 읽기를 서브컬렉션으로 전환
- 배열 필드는 더 이상 읽지 않음

### Phase 3: 배열 필드 제거
- 기존 배열 필드 제거
- 서브컬렉션만 사용

## 📝 구현 단계

### 1. EnrollmentService에 서브컬렉션 메서드 추가
- `addReenrollmentRecord()`
- `addAdminAction()`
- `addExtensionRequest()`
- `getReenrollmentHistory()` (페이지네이션 지원)
- `getAdminActions()` (페이지네이션 지원)
- `getExtensionRequests()` (페이지네이션 지원)

### 2. 기존 코드 수정
- `createEnrollment()`: 서브컬렉션에도 저장
- `updateEnrollment()`: 서브컬렉션에도 저장
- `watchUserEnrollments()`: 서브컬렉션에서 히스토리 로드

### 3. UI 수정
- `enrollment_detail_screen.dart`: 서브컬렉션에서 페이지네이션으로 로드

### 4. 마이그레이션 스크립트
- 기존 배열 필드 → 서브컬렉션으로 데이터 이동

## ⚠️ 주의사항
- 기존 데이터와의 호환성 유지 필수
- 점진적 마이그레이션으로 다운타임 최소화
- 롤백 계획 준비



