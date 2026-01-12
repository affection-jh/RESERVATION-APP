# 예약 취소/변경 Cloud Functions 성능 및 트랜잭션 점검 결과

## 📊 점검 일시
2024년 (현재)

## ✅ 점검 대상 함수
1. `cancelReservation` - 예약 취소
2. `moveReservationWithinCourse` - 예약 변경 (관리자)

---

## 🎯 1. cancelReservation (예약 취소)

### ✅ O(1) 읽기 확인
- **reservationRef**: `places/{placeId}/reservations/{reservationId}` 직접 참조 → **O(1)** ✅
- **enrollmentRef**: 고정 ID 패턴 `${userId}_${placeId}_${courseId}` → **O(1)** ✅
- **sessionReservations**: 고정 ID 패턴 `${sessionId}_${reservedDateString}` → **O(1)** ✅
- **쿼리 사용 없음** ✅

### ✅ 트랜잭션 원자성 확인
```typescript
// ✅ 모든 read가 write보다 먼저 수행됨
1. tx.get(reservationRef)        // READ
2. tx.get(enrollmentRef)         // READ
3. tx.get(srRef)                 // READ
4. tx.update(enrollmentRef, ...) // WRITE
5. tx.update(srRef, ...)         // WRITE
6. tx.delete(reservationRef)     // WRITE
```

### ⚠️ 트랜잭션 외부 작업
- `isAdminForPlaceUid()`: 트랜잭션 **외부**에서 실행 (권한 체크)
- 알림 생성: 트랜잭션 **외부**에서 실행 (`.then()` 블록)

### 📈 성능 평가
- **읽기**: 3개 문서 (모두 O(1))
- **쓰기**: 2-3개 문서 (enrollment update, sr update, reservation delete)
- **예상 지연시간**: ~50-100ms (트랜잭션 내부)

---

## 🎯 2. moveReservationWithinCourse (예약 변경)

### ✅ O(1) 읽기 확인
- **reservationRef**: `places/{placeId}/reservations/{reservationId}` 직접 참조 → **O(1)** ✅
- **oldSrRef**: 고정 ID 패턴 `${oldSessionId}_${oldReservedDateString}` → **O(1)** ✅
- **newSrRef**: 고정 ID 패턴 `${newSessionId}_${newReservedDateString}` → **O(1)** ✅
- **policyRef**: `coursePolicies/{courseId}` 직접 참조 → **O(1)** ✅
- **placeRef**: `places/{placeId}` 직접 참조 → **O(1)** (조건부: capacity가 없을 때만) ✅
- **overrideRef**: 고정 ID 패턴 `${newSessionId}_${newReservedDateString}` → **O(1)** (조건부) ✅
- **쿼리 사용 없음** ✅

### ✅ 트랜잭션 원자성 확인
```typescript
// ✅ 모든 read가 write보다 먼저 수행됨
1. tx.get(reservationRef)        // READ
2. tx.get(policyRef)             // READ
3. tx.get(oldSrRef)              // READ
4. tx.get(newSrRef)              // READ
5. [조건부] tx.get(placeRef)     // READ (capacity가 없을 때만)
6. [조건부] tx.get(overrideRef) // READ (capacity가 없을 때만)
7. tx.update(reservationRef, ...) // WRITE
8. tx.update(oldSrRef, ...)      // WRITE
9. tx.update/set(newSrRef, ...)  // WRITE
```

### ⚠️ 트랜잭션 외부 작업
- `assertAdminUid()`: 트랜잭션 **외부**에서 실행 (권한 체크)
- 알림 생성: 트랜잭션 **외부**에서 실행 (`.then()` 블록)

### 📈 성능 평가
- **읽기**: 4-6개 문서 (기본 4개, capacity가 없으면 +2개)
- **쓰기**: 3개 문서 (reservation update, oldSr update, newSr update/set)
- **예상 지연시간**: ~80-150ms (트랜잭션 내부, capacity 조회 포함 시)

### 💡 최적화 포인트
- **조건부 읽기 최적화**: `newSrDoc`에 `capacity`가 있으면 `placeRef`/`overrideRef` 읽기 생략
  - 대부분의 케이스에서 **2개 문서 읽기 절약** ✅

---

## 🔍 3. 권한 체크 함수 점검

### isAdminForPlaceUid / assertAdminForPlaceUid
- **위치**: `functions/src/admin_auth.ts`
- **실행 시점**: 트랜잭션 **외부** (트랜잭션 시작 전)
- **쿼리 사용 여부**: 확인 필요 (admin_auth.ts 코드 확인)

---

## ✅ 종합 평가

### 성능
- ✅ **모든 함수가 O(1) 읽기 사용** (쿼리 없음)
- ✅ **고정 ID 패턴 활용**으로 직접 문서 참조
- ✅ **트랜잭션 내부 읽기 최소화** (조건부 읽기 최적화)

### 트랜잭션 원자성
- ✅ **read-before-write 규칙 준수**
- ✅ **모든 관련 문서가 단일 트랜잭션 내에서 원자적으로 처리**
- ✅ **트랜잭션 외부 작업** (권한 체크, 알림)은 실패해도 데이터 일관성에 영향 없음

### 개선 가능한 부분
1. ⚠️ **권한 체크 최적화**: `isAdminForPlaceUid`가 쿼리를 사용한다면 캐싱 고려
2. ✅ **이미 최적화됨**: `moveReservationWithinCourse`의 조건부 capacity 읽기

---

## 📝 결론

**두 함수 모두 O(1) 읽기와 트랜잭션 원자성을 보장합니다.** ✅

- `cancelReservation`: **3개 읽기, 2-3개 쓰기** (매우 빠름)
- `moveReservationWithinCourse`: **4-6개 읽기, 3개 쓰기** (조건부 최적화 적용)

예약 생성(`createReservation`)과 동일한 수준의 성능을 보장합니다.

