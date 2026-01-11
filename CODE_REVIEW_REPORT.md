# 코드 논리 점검 보고서

## 📋 개요
테스트 시나리오를 기반으로 전체 코드를 논리적으로 분석한 결과입니다.

---

## 🔴 Critical Issues (즉시 수정 필요)

### 1. 예약 취소 시 크레딧 복구 최대값 검증 누락

**위치**: `functions/src/index.ts:1687-1690`

**문제점**:
```typescript
const remaining = Number(((enrollmentDoc.data() as any)?.remainingReservations ?? 0) as any);
tx.update(enrollmentDoc.ref, { remainingReservations: remaining + 1 });
```

**문제**:
- `remainingReservations`가 `totalReservations`를 초과할 수 있음
- 예약 취소 시 크레딧이 무한정 증가할 수 있는 버그

**시나리오**:
- 사용자가 모든 크레딧을 사용한 후 (remainingReservations = 0)
- 예약 취소 시 remainingReservations가 증가
- 하지만 이미 사용한 크레딧보다 더 많이 복구될 수 있음

**수정 방안**:
```typescript
const enrollmentData = enrollmentDoc.data() as any;
const remaining = Number((enrollmentData?.remainingReservations ?? 0) as any);
const total = Number((enrollmentData?.totalReservations ?? 0) as any);
const newRemaining = Math.min(total, remaining + 1);
tx.update(enrollmentDoc.ref, { remainingReservations: newRemaining });
```

**우선순위**: 🔴 Critical

---

### 2. 유효기간 경계값 처리 불일치

**위치**: `functions/src/index.ts:1447-1448`

**문제점**:
```typescript
const enrollmentCanReserve =
    seoulNow >= validFrom && seoulNow <= validUntil && remainingReservations > 0;
```

**문제**:
- `validUntil` 포함 여부가 명확하지 않음
- `validUntil`이 오늘 자정이라면, 오늘 예약 가능한지 불명확
- 클라이언트와 서버 로직이 다를 수 있음

**시나리오**:
- validUntil = 2024-01-07 23:59:59
- 현재 시간 = 2024-01-07 10:00:00
- `seoulNow <= validUntil`이 true이지만, 날짜만 비교하면 문제 발생 가능

**수정 방안**:
```typescript
// 날짜만 비교 (시간 무시)
const today = new Date(seoulNow.getFullYear(), seoulNow.getMonth(), seoulNow.getDate());
const validFromDate = new Date(validFrom.getFullYear(), validFrom.getMonth(), validFrom.getDate());
const validUntilDate = new Date(validUntil.getFullYear(), validUntil.getMonth(), validUntil.getDate());

const enrollmentCanReserve =
    today >= validFromDate && today <= validUntilDate && remainingReservations > 0;
```

**우선순위**: 🔴 Critical

---

### 3. 코스 삭제 시 활성 예약 처리 누락

**위치**: `lib/services/firestore_service.dart:210-245`

**문제점**:
- 코스 삭제 시 활성 예약(미래 날짜)에 대한 처리가 없음
- 사용자가 삭제된 코스의 예약을 조회할 수 있음
- 예약 취소 시 코스 정보를 찾을 수 없어 에러 발생 가능

**시나리오**:
1. 사용자 A가 코스 X에 예약 (2024-01-10)
2. 관리자가 코스 X 삭제
3. 사용자 A가 예약 목록 조회 시 코스 정보 없음 → 에러
4. 사용자 A가 예약 취소 시도 → 코스 정보 없음 → 에러

**수정 방안**:
```dart
Future<void> deleteCourse(String placeId, String courseId) async {
  // 1. 활성 예약 확인
  final activeReservations = await _firestore
      .collection('places')
      .doc(placeId)
      .collection('reservations')
      .where('courseId', isEqualTo: courseId)
      .where('reservedDate', isGreaterThan: Timestamp.now())
      .get();
  
  if (activeReservations.docs.isNotEmpty) {
    throw Exception('활성 예약이 있는 코스는 삭제할 수 없습니다. 먼저 예약을 취소해주세요.');
  }
  
  // 2. 코스 삭제
  // ... 기존 로직
}
```

**우선순위**: 🔴 Critical

---

### 4. 정원 오버라이드 0 설정 시 처리 누락

**위치**: `functions/src/index.ts:1478-1481`

**문제점**:
```typescript
const overrideCap = !overrideSnap.empty
    ? Number(((overrideSnap.docs[0].data() as any)?.capacity ?? 0) as any)
    : undefined;
const capacity = Number.isFinite(overrideCap) ? (overrideCap as number) : Number(session.capacity ?? 0);
```

**문제**:
- `overrideCap`가 0일 때도 유효한 값으로 처리됨
- 관리자가 특정 날짜 정원을 0으로 설정하면 예약 불가해야 함
- 하지만 `Number.isFinite(0)`은 true이므로 기본 capacity로 대체되지 않음

**시나리오**:
- 관리자가 특정 날짜 정원을 0으로 설정 (세션 취소)
- 사용자가 해당 날짜 예약 시도
- `capacity = 0`이지만, `reservedCount >= capacity` 검증에서 차단됨
- 하지만 에러 메시지가 명확하지 않음

**수정 방안**:
```typescript
const overrideCap = !overrideSnap.empty
    ? Number(((overrideSnap.docs[0].data() as any)?.capacity ?? null) as any)
    : undefined;
const capacity = (overrideCap !== undefined && overrideCap !== null)
    ? overrideCap
    : Number(session.capacity ?? 0);
```

**우선순위**: 🟡 Medium

---

## 🟡 Medium Issues (개선 권장)

### 5. 예약 취소 시간 검증 경계값 처리

**위치**: `functions/src/index.ts:1672-1678`

**문제점**:
```typescript
const closeAt = new Date(sessionStart.getTime() - 60 * 60_000); // 1시간 전
if (seoulNow.getTime() >= closeAt.getTime()) {
    throw new functions.https.HttpsError(
        'failed-precondition',
        '세션 시작 1시간 전까지만 취소 가능합니다.'
    );
}
```

**문제**:
- `>=` 사용으로 정확히 1시간 전에는 취소 가능
- 하지만 테스트 시나리오에서는 "1시간 전까지"라고 명시
- 경계값 처리 일관성 필요

**수정 방안**:
```typescript
// 정확히 1시간 전에는 취소 가능 (>= 대신 > 사용)
if (seoulNow.getTime() > closeAt.getTime()) {
    throw new functions.https.HttpsError(
        'failed-precondition',
        '세션 시작 1시간 전까지만 취소 가능합니다.'
    );
}
```

**우선순위**: 🟡 Medium

---

### 6. 중복 예약 방지 로직의 Race Condition 가능성

**위치**: `lib/providers/reservation_provider.dart:100-128`

**문제점**:
```dart
final key = _reservationKey(reservation);
if (_createInFlightKeys.contains(key)) {
  throw Exception('예약 처리 중입니다. 잠시만 기다려주세요.');
}
_createInFlightKeys.add(key);
```

**문제**:
- 클라이언트 측 중복 방지는 좋지만, 서버 측에서도 중복 검증 필요
- 네트워크 지연으로 인해 같은 예약이 두 번 생성될 수 있음
- 서버 측 중복 검증은 이미 있지만, 클라이언트와 서버 간 타이밍 이슈 가능

**현재 서버 측 검증**:
```typescript
// functions/src/index.ts:1488-1502
const dupQuery = db
    .collection('places')
    .doc(placeId)
    .collection('reservations')
    .where('userId', '==', userId)
    .where('courseId', '==', courseId)
    .where('dayOfWeek', '==', dayOfWeek)
    .where('startTime', '==', startTime)
    .where('reservedDateString', '==', reservedDateString)
    .limit(1);
const dupSnap = await tx.get(dupQuery as any);
if (!dupSnap.empty) {
    throw new functions.https.HttpsError('already-exists', '이미 예약된 세션입니다.');
}
```

**분석**:
- 서버 측 중복 검증은 트랜잭션 내에서 수행되므로 안전함
- 하지만 클라이언트 측 `_createInFlightKeys`는 메모리 기반이므로 앱 재시작 시 초기화됨

**우선순위**: 🟡 Medium (현재는 안전하지만 개선 가능)

---

### 7. 예약 이동 시 enrollment 검증 누락

**위치**: `functions/src/index.ts:1755-1920`

**문제점**:
- 예약 이동 시 `enrollmentCanReserve: true`로 하드코딩됨
- 하지만 이동 후에도 enrollment가 유효한지 확인하지 않음

**코드**:
```typescript
const eligibility = evaluateReservation({
    now,
    policy,
    sessionDateString: newReservedDateString,
    startTime: newStartTime,
    capacity,
    reservedCount: currentNewCount,
    enrollmentCanReserve: true, // 이동은 크레딧/유효기간에 영향 없음
});
```

**문제**:
- 관리자가 강제 이동 시 enrollment가 만료되었을 수 있음
- 하지만 검증하지 않고 이동 허용

**수정 방안**:
```typescript
// enrollment 검증 추가
const enrollmentQuery = db
    .collection('enrollments')
    .where('userId', '==', userId)
    .where('courseId', '==', courseId)
    .limit(1);
const enrollmentSnap = await tx.get(enrollmentQuery as any);
if (!enrollmentSnap.empty) {
    const enrollmentData = enrollmentSnap.docs[0].data() as any;
    const remaining = Number((enrollmentData?.remainingReservations ?? 0) as any);
    const validFrom = (enrollmentData?.validFrom instanceof admin.firestore.Timestamp)
        ? enrollmentData.validFrom.toDate()
        : new Date(0);
    const validUntil = (enrollmentData?.validUntil instanceof admin.firestore.Timestamp)
        ? enrollmentData.validUntil.toDate()
        : new Date(0);
    const enrollmentCanReserve = now >= validFrom && now <= validUntil && remaining > 0;
    
    const eligibility = evaluateReservation({
        now,
        policy,
        sessionDateString: newReservedDateString,
        startTime: newStartTime,
        capacity,
        reservedCount: currentNewCount,
        enrollmentCanReserve, // 실제 enrollment 상태 사용
    });
}
```

**우선순위**: 🟡 Medium

---

### 8. sessionReservations 데이터 불일치 가능성

**위치**: `functions/src/index.ts:1891-1901`

**문제점**:
```typescript
const oldSrDoc = await tx.get(oldSrRef);
if (oldSrDoc.exists) {
    const currentOld = Number(oldSrDoc.data()?.reservedCount ?? 0);
    tx.update(oldSrRef, {
        reservedCount: Math.max(0, currentOld - 1),
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
    });
} else {
    // old sessionReservations가 존재하지 않는 경우 (데이터 불일치 가능성)
    logWarn('Old sessionReservation not found', { oldSessionId, oldReservedDateString });
}
```

**문제**:
- 예약 이동 시 old sessionReservations가 없으면 경고만 하고 계속 진행
- 데이터 불일치가 발생할 수 있음
- 하지만 예약 자체는 존재하므로 reservedCount는 1이어야 함

**수정 방안**:
```typescript
if (oldSrDoc.exists) {
    const currentOld = Number(oldSrDoc.data()?.reservedCount ?? 0);
    tx.update(oldSrRef, {
        reservedCount: Math.max(0, currentOld - 1),
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
    });
} else {
    // 예약은 존재하지만 sessionReservations가 없는 경우
    // 데이터 복구: sessionReservations 생성 (reservedCount = 0)
    tx.set(oldSrRef, {
        id: `${oldSessionId}_${oldReservedDateString}`,
        sessionId: oldSessionId,
        courseId,
        placeId,
        dayOfWeek: oldDayOfWeek,
        startTime: oldStartTime,
        date: oldReservedDateString,
        capacity: oldCapacity,
        reservedCount: 0, // 예약이 이동하므로 0
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    logWarn('Old sessionReservation not found, created with reservedCount=0', { oldSessionId, oldReservedDateString });
}
```

**우선순위**: 🟡 Medium

---

## 🟢 Low Issues (개선 고려)

### 9. 에러 메시지 일관성 부족

**문제점**:
- 클라이언트와 서버의 에러 메시지가 다를 수 있음
- 같은 상황에서 다른 메시지 표시 가능

**예시**:
- 서버: "예약 가능한 인원이 없습니다."
- 클라이언트: "정원이 마감되었습니다."

**우선순위**: 🟢 Low

---

### 10. 정원 오버라이드 삭제 시 처리

**문제점**:
- 정원 오버라이드를 삭제하면 기본 capacity로 돌아감
- 하지만 이미 예약된 인원이 기본 capacity를 초과할 수 있음

**시나리오**:
- 기본 capacity = 5
- 특정 날짜 오버라이드 = 10
- 예약 8명
- 오버라이드 삭제
- 기본 capacity = 5이지만 예약은 8명 → 데이터 불일치

**우선순위**: 🟢 Low

---

### 11. 예약 생성 시 정책 로드 순서

**위치**: `functions/src/index.ts:1465-1468`

**문제점**:
```typescript
const policyDoc = await tx.get(policyRef);
const policyData = policyDoc.exists ? (policyDoc.data() as CoursePolicyDoc) : null;
const policy = selectEffectivePolicy(now, policyData, { courseId, placeId });
```

**분석**:
- 정책 로드가 트랜잭션 내에서 수행되므로 안전함
- 하지만 정책이 없을 때 기본 정책 사용은 적절함

**우선순위**: 🟢 Low (현재 구현은 적절함)

---

## ✅ 잘 구현된 부분

### 1. 트랜잭션 사용
- 모든 예약 생성/취소/이동이 트랜잭션으로 처리됨
- 데이터 정합성 보장

### 2. 중복 예약 방지
- 클라이언트와 서버 양쪽에서 중복 검증
- 트랜잭션 내에서 중복 확인

### 3. 정원 검증
- 트랜잭션 내에서 정원 확인
- 동시성 문제 방지

### 4. 정책 엔진
- 서버 측 정책 검증
- Rolling Window / Weekly Release 지원

### 5. 시간 검증
- 서울 시간대 기준 통일
- 경계값 처리 (일부 개선 필요)

---

## 📊 우선순위별 수정 계획

### Phase 1: Critical (즉시 수정)
1. ✅ 예약 취소 시 크레딧 복구 최대값 검증 추가
2. ✅ 유효기간 경계값 처리 일관성 확보
3. ✅ 코스 삭제 시 활성 예약 처리 추가

### Phase 2: Medium (1주일 내)
4. ✅ 예약 취소 시간 검증 경계값 처리
5. ✅ 예약 이동 시 enrollment 검증 추가
6. ✅ sessionReservations 데이터 불일치 복구 로직

### Phase 3: Low (1개월 내)
7. ✅ 에러 메시지 일관성 개선
8. ✅ 정원 오버라이드 삭제 시 처리 로직

---

## 🔍 추가 검증 필요 사항

### 1. 동시성 테스트
- 정원 경쟁 상황에서 정확히 하나만 성공하는지 확인
- 크레딧 경쟁 상황에서 정확히 하나만 성공하는지 확인

### 2. 데이터 정합성 검증
- `sessionReservations.reservedCount`와 실제 예약 수 일치 확인
- `enrollments.remainingReservations`와 실제 사용 크레딧 일치 확인

### 3. 에러 처리 테스트
- 네트워크 오류 시 재시도 로직
- 서버 오류 시 클라이언트 처리

### 4. 경계값 테스트
- 정확히 1시간 전 예약/취소
- validUntil 당일 예약
- 정원 0일 때 예약 시도

---

## 📝 결론

전체적으로 코드는 잘 구조화되어 있고, 트랜잭션을 적절히 사용하여 데이터 정합성을 보장하고 있습니다. 하지만 몇 가지 Critical 이슈가 있어 즉시 수정이 필요합니다:

1. **크레딧 복구 최대값 검증**: 가장 중요한 버그로, 즉시 수정 필요
2. **유효기간 경계값 처리**: 사용자 혼란 방지를 위해 수정 필요
3. **코스 삭제 시 활성 예약 처리**: 데이터 정합성을 위해 수정 필요

나머지 Medium/Low 이슈들은 점진적으로 개선하면 됩니다.

---

## 🔗 관련 파일

- `functions/src/index.ts`: 서버 측 예약 로직
- `lib/providers/reservation_provider.dart`: 클라이언트 예약 Provider
- `lib/services/firestore_service.dart`: Firestore 서비스
- `lib/utils/reservation_utils.dart`: 예약 유틸리티
- `lib/models/course_enrollment.dart`: 등록 모델

