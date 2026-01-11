# 예약 기능 논리적 테스트 점검 보고서

## 📋 점검 일자
2024년 (현재)

## 🎯 점검 범위
- 예약 생성 (createReservation)
- 예약 취소 (cancelReservation)
- 예약 이동/조정 (moveReservationWithinCourse)
- 세션 취소 (cancelSession)

---

## ✅ 예약 생성 (createReservation)

### 검증 항목

#### 1. **트랜잭션 안전성** ✅
- 모든 작업이 단일 트랜잭션 내에서 수행됨
- 원자성 보장

#### 2. **중복 예약 방지** ✅
```typescript:1494:1507:functions/src/index.ts
// 6) 중복 예약(유저가 이미 같은 세션/날짜 예약) - 플레이스 서브컬렉션에서 조회
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
- 트랜잭션 내에서 중복 체크 수행
- 동시성 문제 방지

#### 3. **정원 체크** ✅
```typescript:1510:1542:functions/src/index.ts
// 7) 중앙 정책 엔진(서버 버전)으로 최종 검증
const eligibility = evaluateReservation({
    now,
    policy,
    sessionDateString: reservedDateString,
    startTime,
    capacity,
    reservedCount: currentReservedCount,
    enrollmentCanReserve,
});

if (!eligibility.canReserve) {
    // ... 에러 처리
    case ReservationLockReason.full:
        throw new functions.https.HttpsError('resource-exhausted', '예약 가능한 인원이 없습니다.');
}
```
- 트랜잭션 내에서 정원 체크
- 정원 초과 방지

#### 4. **Enrollment 검증** ✅
```typescript:1426:1453:functions/src/index.ts
// 1) enrollment 검증
const enrollmentQuery = db
    .collection('enrollments')
    .where('userId', '==', userId)
    .where('courseId', '==', courseId)
    .limit(1);

const enrollmentSnap = await tx.get(enrollmentQuery as any);
if (enrollmentSnap.empty) {
    throw new functions.https.HttpsError('failed-precondition', '등록된 코스가 아닙니다.');
}
// ... 유효기간 및 남은 횟수 검증
const enrollmentCanReserve =
    today >= validFromDate && today <= validUntilDate && remainingReservations > 0;
```
- 등록 여부 확인
- 유효기간 검증
- 남은 예약 횟수 확인

#### 5. **정책 검증** ✅
- `evaluateReservation` 함수로 통합 검증
- 과거 날짜 방지
- 오픈 정책 적용
- 마감 시간 전 체크

#### 6. **데이터 일관성** ✅
```typescript:1562:1586:functions/src/index.ts
// 9) sessionReservations upsert + reservedCount++
const srDocId = `${sessionId}_${reservedDateString}`;
if (!srDoc.exists) {
    tx.set(srRef, {
        // ... 새 문서 생성
        reservedCount: 1,
    });
} else {
    tx.update(srRef, {
        reservedCount: currentReservedCount + 1,
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
    });
}

// 10) enrollment remainingReservations--
tx.update(enrollmentDoc.ref, { remainingReservations: remainingReservations - 1 });
```
- sessionReservations와 enrollment를 동시에 업데이트
- 트랜잭션으로 일관성 보장

### 결론
**✅ 예약 생성 로직은 안전하게 구현되어 있습니다.**

---

## ✅ 예약 취소 (cancelReservation)

### 검증 항목

#### 1. **트랜잭션 안전성** ✅
- 모든 작업이 단일 트랜잭션 내에서 수행됨

#### 2. **권한 검증** ✅
```typescript:1658:1661:functions/src/index.ts
const reservation = reservationDoc.data()!;
if (reservation.userId !== userId) {
    throw new functions.https.HttpsError('permission-denied', '본인의 예약만 취소할 수 있습니다.');
}
```
- 본인 예약만 취소 가능

#### 3. **취소 시간 제한** ✅
```typescript:1672:1683:functions/src/index.ts
// 취소 가능 여부 검증 (세션 시작 1시간 전까지 취소 가능)
const seoulNow = getSeoulDateTime();
const { y, mo, d } = parseYYYYMMDD(reservedDateString);
const { h, m } = parseHHmm(startTime);
const sessionStart = makeSeoulDateTime(y, mo, d, h, m);
const closeAt = new Date(sessionStart.getTime() - 60 * 60_000); // 1시간 전
if (seoulNow.getTime() >= closeAt.getTime()) {
    throw new functions.https.HttpsError(
        'failed-precondition',
        '세션 시작 1시간 전까지만 취소 가능합니다.'
    );
}
```
- 세션 시작 1시간 전까지만 취소 가능
- 과거 세션 취소 방지

#### 4. **크레딧 복구** ✅
```typescript:1685:1700:functions/src/index.ts
// enrollment remainingReservations++
const enrollmentQuery = db
    .collection('enrollments')
    .where('userId', '==', userId)
    .where('courseId', '==', courseId)
    .limit(1);
const enrollmentSnap = await tx.get(enrollmentQuery as any);
if (!enrollmentSnap.empty) {
    const enrollmentDoc = enrollmentSnap.docs[0];
    const enrollmentData = enrollmentDoc.data() as any;
    const remaining = Number((enrollmentData?.remainingReservations ?? 0) as any);
    const total = Number((enrollmentData?.totalReservations ?? 0) as any);
    // 최대값을 초과하지 않도록 제한
    const newRemaining = Math.min(total, remaining + 1);
    tx.update(enrollmentDoc.ref, { remainingReservations: newRemaining });
}
```
- 크레딧 복구 시 최대값 초과 방지 (`Math.min` 사용)
- 안전한 크레딧 관리

#### 5. **sessionReservations 업데이트** ✅
```typescript:1702:1712:functions/src/index.ts
// sessionReservations reservedCount--
const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
const srRef = db.collection('sessionReservations').doc(`${sessionId}_${reservedDateString}`);
const srDoc = await tx.get(srRef);
if (srDoc.exists) {
    const current = Number(srDoc.data()?.reservedCount ?? 0);
    tx.update(srRef, {
        reservedCount: Math.max(0, current - 1),
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
    });
}
```
- 음수 방지 (`Math.max(0, ...)`)
- ⚠️ **경미한 이슈**: sessionReservations가 없을 때는 아무것도 하지 않음
  - 예약은 삭제되므로 큰 문제는 아니지만, 데이터 불일치 가능성 존재

### 결론
**✅ 예약 취소 로직은 안전하게 구현되어 있습니다.**
**⚠️ 경미한 이슈**: sessionReservations 문서가 없을 때 처리 개선 권장

---

## ✅ 예약 이동/조정 (moveReservationWithinCourse)

### 검증 항목

#### 1. **관리자 권한** ✅
```typescript:1772:1772:functions/src/index.ts
await assertAdminUid(context.auth.uid);
```
- 관리자만 이동 가능

#### 2. **과거 날짜 이동 방지** ✅
```typescript:1788:1791:functions/src/index.ts
const todayString = `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`;
if (seoulDateOnly(newReservedDateString).getTime() < seoulDateOnly(todayString).getTime()) {
    throw new functions.https.HttpsError('failed-precondition', '과거 날짜로는 이동할 수 없습니다.');
}
```
- 과거 날짜로 이동 불가

#### 3. **정원 체크** ✅
```typescript:1850:1856:functions/src/index.ts
const newSrDoc = await tx.get(newSrRef);
const currentNewCount = newSrDoc.exists ? Number(newSrDoc.data()?.reservedCount ?? 0) : 0;
if (currentNewCount >= capacity) {
    throw new functions.https.HttpsError('resource-exhausted', '이동할 세션의 예약 가능한 인원이 없습니다.');
}
```
- 이동할 세션의 정원 체크

#### 4. **정책 검증** ✅
```typescript:1858:1889:functions/src/index.ts
// 정책 적용: allowAdminForceMoveWithinCourse가 OFF면 오픈/마감 정책도 강제
if (!policy.allowAdminForceMoveWithinCourse) {
    const eligibility = evaluateReservation({
        // ... 정책 검증
    });
    if (!eligibility.canReserve) {
        // ... 에러 처리
    }
}
```
- 정책에 따라 오픈/마감 시간 체크

#### 5. **데이터 일관성** ⚠️
```typescript:1899:1910:functions/src/index.ts
// old-- / new++
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
- ⚠️ **중요 이슈**: old sessionReservations가 없을 때 경고만 하고 계속 진행
  - 예약은 이동되지만, old sessionReservations의 reservedCount는 감소하지 않음
  - 데이터 불일치 발생 가능

### 결론
**⚠️ 예약 이동 로직에 데이터 불일치 가능성이 있습니다.**
**개선 필요**: old sessionReservations가 없을 때 처리 로직 개선 권장

---

## ✅ 세션 취소 (cancelSession)

### 검증 항목

#### 1. **관리자 권한** ✅
- 관리자만 세션 취소 가능

#### 2. **모든 예약 취소** ✅
```typescript:2541:2571:functions/src/index.ts
// 트랜잭션으로 예약 취소 및 크레딧 복구
await db.runTransaction(async (tx) => {
    for (const reservationDoc of reservationsSnapshot.docs) {
        const reservation = reservationDoc.data();
        const reservationId = reservationDoc.id;
        const userId = reservation.userId as string;

        // 예약 삭제
        tx.delete(reservationRef);

        // enrollment remainingReservations++
        // ... 크레딧 복구

        // sessionReservations reservedCount--
        // ... 카운트 감소
    }
});
```
- 해당 세션의 모든 예약 취소
- 크레딧 복구
- sessionReservations 업데이트

### 결론
**✅ 세션 취소 로직은 안전하게 구현되어 있습니다.**

---

## 🚨 발견된 문제점 요약

### 치명적인 문제
**없음** ✅

### 경미한 문제

1. **예약 취소 시 sessionReservations 없음 처리**
   - 위치: `cancelReservation` 함수
   - 문제: sessionReservations 문서가 없을 때 아무것도 하지 않음
   - 영향: 데이터 불일치 가능성 (하지만 예약은 삭제되므로 큰 문제는 아님)
   - 우선순위: 낮음

2. **예약 이동 시 old sessionReservations 없음 처리**
   - 위치: `moveReservationWithinCourse` 함수
   - 문제: old sessionReservations가 없을 때 경고만 하고 계속 진행
   - 영향: 데이터 불일치 (old sessionReservations의 reservedCount가 감소하지 않음)
   - 우선순위: **중간** ⚠️

---

## 📊 전체 평가

### 안전성
- ✅ 트랜잭션 사용으로 원자성 보장
- ✅ 중복 예약 방지
- ✅ 정원 초과 방지
- ✅ 크레딧 관리 안전성

### 데이터 일관성
- ✅ 예약 생성: 완벽
- ✅ 예약 취소: 거의 완벽 (경미한 이슈 1개)
- ⚠️ 예약 이동: 개선 필요 (이슈 1개)
- ✅ 세션 취소: 완벽

### 권한 관리
- ✅ 사용자 예약 취소: 본인만 가능
- ✅ 예약 이동: 관리자만 가능
- ✅ 세션 취소: 관리자만 가능

---

## 🔧 개선 권장 사항

### 1. 예약 이동 시 old sessionReservations 처리 개선

**현재 코드:**
```typescript
if (oldSrDoc.exists) {
    // ... 업데이트
} else {
    logWarn('Old sessionReservation not found', { oldSessionId, oldReservedDateString });
}
```

**개선 방안:**
- 옵션 1: old sessionReservations가 없으면 에러 발생 (더 엄격)
- 옵션 2: old sessionReservations를 생성하고 reservedCount를 1로 설정 (데이터 복구)
- 옵션 3: 현재 상태 유지하되, 모니터링 강화

**권장:** 옵션 1 (에러 발생) - 데이터 불일치를 방지하기 위해

---

## ✅ 결론

**전체적으로 예약 시스템은 안전하게 구현되어 있습니다.**

- 치명적인 문제: **없음**
- 경미한 문제: **2개** (우선순위 낮음~중간)
- 권장 개선: 예약 이동 시 old sessionReservations 처리 로직 개선

**운영 가능 상태** ✅

