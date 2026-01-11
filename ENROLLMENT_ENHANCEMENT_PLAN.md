# 등록정보 화면 개선 계획

## 📊 중요도별 요구사항 정리

### 🔴 **최우선 (필수)**
1. **최초 등록일** (`firstEnrolledAt`)
   - 재등록 시에도 유지되어야 하는 최초 등록 시점
   - 현재 `enrolledAt`은 재등록 시 업데이트되어 최초 등록일을 잃음

2. **총 등록횟수** (`totalEnrollmentCount`)
   - 이 멤버가 이 코스에 등록한 총 횟수 (1회차, 2회차, 3회차...)
   - 재등록할 때마다 증가

3. **현재 등록 정보** (이미 존재하지만 UI 개선 필요)
   - 유효기간: `validFrom` ~ `validUntil`
   - 횟수: `totalReservations` / `remainingReservations`

### 🟡 **중요 (권장)**
4. **재등록정보 리스트** (`reenrollmentHistory`)
   - 각 재등록마다 기록: "1/4등록", "2/6재등록", "3/8재등록" 등
   - 재등록 시마다 히스토리에 추가
   - 형식: `{ enrollmentNumber: 1, totalReservations: 4, enrolledAt: timestamp, validFrom: timestamp, validUntil: timestamp }`

5. **연장요청 기록들** (`extensionRequests`)
   - 현재는 단일 `extensionRequest`만 저장 → 배열로 변경 필요
   - 모든 연장요청 이력 보관 (과거 기록 포함)
   - 형식: 기존 `ExtensionRequest` 구조 유지하되 배열로

### 🟢 **보통 (선택)**
6. **관리자 대응 기록** (`adminActions`)
   - 관리자가 수행한 작업 기록
   - 예: "횟수 조정", "기간 연장", "재등록", "연장 승인/거부" 등
   - 형식: `{ actionType: string, performedAt: timestamp, performedBy: string (adminId), details: string?, oldValue?: any, newValue?: any }`

7. **메모** (`memo`)
   - 관리자가 작성하는 자유 메모
   - 형식: `string?` (선택적)

---

## 🗄️ Firestore 구조 변경사항

### 변경 전 (현재)
```typescript
enrollments/{enrollmentId}
├── id: string
├── userId: string
├── courseId: string
├── placeId: string
├── enrolledAt: timestamp          // 재등록 시 업데이트됨
├── validFrom: timestamp
├── validUntil: timestamp
├── totalReservations: number
├── remainingReservations: number
└── extensionRequest: ExtensionRequest?  // 단일 객체만
```

### 변경 후 (제안)
```typescript
enrollments/{enrollmentId}
├── id: string
├── userId: string
├── courseId: string
├── placeId: string
├── firstEnrolledAt: timestamp          // ✨ 새로 추가: 최초 등록일
├── enrolledAt: timestamp                // 현재 등록일 (재등록 시 업데이트)
├── totalEnrollmentCount: number         // ✨ 새로 추가: 총 등록횟수 (1, 2, 3...)
├── validFrom: timestamp
├── validUntil: timestamp
├── totalReservations: number
├── remainingReservations: number
├── reenrollmentHistory: ReenrollmentRecord[]  // ✨ 새로 추가: 재등록 이력
├── extensionRequests: ExtensionRequest[]       // ✨ 변경: 단일 → 배열
├── adminActions: AdminAction[]                 // ✨ 새로 추가: 관리자 대응 기록
└── memo: string?                               // ✨ 새로 추가: 메모
```

### 새로운 중첩 객체 구조

**ReenrollmentRecord:**
```typescript
{
  enrollmentNumber: number        // 1, 2, 3... (몇 번째 등록인지)
  totalReservations: number       // 해당 등록의 총 횟수
  enrolledAt: timestamp           // 재등록일
  validFrom: timestamp
  validUntil: timestamp
  cancelledAt?: timestamp          // 취소된 경우
}
```

**AdminAction:**
```typescript
{
  id: string
  actionType: "adjust_count" | "extend_period" | "reenroll" | "approve_extension" | "reject_extension" | "cancel" | "memo_updated"
  performedAt: timestamp
  performedBy: string              // adminId
  details?: string                 // 상세 설명
  oldValue?: any                   // 변경 전 값 (선택적)
  newValue?: any                   // 변경 후 값 (선택적)
}
```

**ExtensionRequest** (기존 구조 유지, 배열로 변경):
```typescript
{
  id: string
  requestedAt: timestamp
  reason: string
  status: "pending" | "approved" | "rejected"
  approvedAt?: timestamp
  rejectedAt?: timestamp
  rejectionReason?: string
}
```

---

## 🔄 마이그레이션 필요사항

### 1. 기존 데이터 마이그레이션
- 기존 `enrolledAt` → `firstEnrolledAt`로 복사
- 기존 `extensionRequest` → `extensionRequests` 배열로 변환
- `totalEnrollmentCount` → 기본값 1로 설정
- `reenrollmentHistory` → 빈 배열로 초기화

### 2. 호환성 유지
- 기존 코드에서 `extensionRequest`를 참조하는 부분을 `extensionRequests.last` 또는 `extensionRequests.firstWhere(...)`로 변경
- 또는 `extensionRequest` getter를 추가하여 하위 호환성 유지

---

## 💡 구현 우선순위

### Phase 1: 필수 기능 (즉시 구현)
1. ✅ `firstEnrolledAt` 필드 추가
2. ✅ `totalEnrollmentCount` 필드 추가
3. ✅ UI에 최초 등록일, 총 등록횟수 표시

### Phase 2: 중요 기능 (단기)
4. ✅ `reenrollmentHistory` 배열 추가
5. ✅ 재등록 시 히스토리에 기록 추가
6. ✅ `extensionRequests` 배열로 변경
7. ✅ 연장요청 시 배열에 추가 (기존 단일 객체 대체)

### Phase 3: 선택 기능 (중기)
8. ✅ `adminActions` 배열 추가
9. ✅ 관리자 작업 시마다 기록 추가
10. ✅ `memo` 필드 추가
11. ✅ 메모 편집 UI 추가

---

## 📱 UI 설계

### 간략 보기 (기본)
```
┌─────────────────────────────┐
│ 등록 정보                     │
├─────────────────────────────┤
│ 최초 등록일: 2024-01-15      │
│ 총 등록횟수: 3회차            │
│ 현재 유효기간: 2024-03-01 ~   │
│             2024-06-01      │
│ 총 예약 횟수: 8회             │
│ 남은 예약 횟수: 3회           │
│                              │
│ [자세히 보기 ▼]              │
└─────────────────────────────┘
```

### 자세히 보기 (확장)
```
┌─────────────────────────────┐
│ 등록 정보                     │
├─────────────────────────────┤
│ 최초 등록일: 2024-01-15      │
│ 총 등록횟수: 3회차            │
│ 현재 등록일: 2024-03-01      │
│                              │
│ ┌─ 재등록 이력 ───────────┐ │
│ │ 1회차: 2024-01-15        │ │
│ │    4회 등록 (2024-01-15  │ │
│ │    ~ 2024-04-15)         │ │
│ │                          │ │
│ │ 2회차: 2024-04-16        │ │
│ │    6회 재등록 (2024-04-16│ │
│ │    ~ 2024-07-16)         │ │
│ │                          │ │
│ │ 3회차: 2024-07-17 (현재) │ │
│ │    8회 재등록 (2024-07-17│ │
│ │    ~ 2024-10-17)         │ │
│ └──────────────────────────┘ │
│                              │
│ ┌─ 연장요청 기록 ──────────┐ │
│ │ 2024-05-01: 승인됨        │ │
│ │    사유: 개인 사정         │ │
│ │    연장: +30일            │ │
│ │                          │ │
│ │ 2024-08-01: 대기 중       │ │
│ │    사유: 병원 예약         │ │
│ └──────────────────────────┘ │
│                              │
│ ┌─ 관리자 대응 기록 ───────┐ │
│ │ 2024-05-02: 연장 승인     │ │
│ │    관리자: 홍길동          │ │
│ │                          │ │
│ │ 2024-07-17: 재등록 처리   │ │
│ │    관리자: 홍길동          │ │
│ └──────────────────────────┘ │
│                              │
│ ┌─ 메모 ──────────────────┐ │
│ │ [편집]                    │ │
│ │ 장기 회원, 특별 관리 필요  │ │
│ └──────────────────────────┘ │
└─────────────────────────────┘
```

---

## ❓ 데이터베이스 구조 변경이 많이 필요한가?

### 답변: **아니요, 큰 변경은 필요 없습니다!**

1. **기존 컬렉션 유지**: `enrollments` 컬렉션에 필드만 추가
2. **새 컬렉션 불필요**: 모든 정보를 `enrollments` 문서에 중첩 객체/배열로 저장
3. **인덱스 변경 불필요**: 새로 추가되는 필드들은 대부분 조회용이므로 인덱스 불필요
4. **마이그레이션 간단**: 기존 데이터에 기본값만 추가하면 됨

### 주의사항
- `extensionRequest` → `extensionRequests` 배열 변경 시 기존 코드 수정 필요
- 하지만 getter로 하위 호환성 유지 가능

---

## 🎯 결론

**구조 변경 난이도: ⭐⭐☆☆☆ (쉬움)**
- 필드 추가만으로 해결 가능
- 기존 데이터 마이그레이션 간단
- 큰 리팩토링 불필요

**구현 시간 예상:**
- Phase 1 (필수): 2-3시간
- Phase 2 (중요): 4-6시간  
- Phase 3 (선택): 3-4시간
- **총 예상: 9-13시간**



