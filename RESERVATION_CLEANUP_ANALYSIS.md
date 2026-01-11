# 예약 세션 주기적 정리 분석 보고서

## 📋 현재 상태

### ❌ 문제점 발견

**예약 세션이 주기적으로 정리되지 않습니다.**

1. **자동 정리 메커니즘 없음**
   - 과거 예약이 자동으로 삭제되지 않음
   - 만료된 sessionReservations가 자동으로 정리되지 않음
   - 주기적인 데이터 정리 스케줄 함수 없음

2. **비활성화된 정리 로직**
   - `onReservationDeleted` 트리거: **DISABLED** (30일 이상 지난 빈 sessionReservations 삭제 로직 포함)
   - `validateDataConsistency` 스케줄: **DISABLED** (데이터 일관성 검증 및 수정)

---

## 🔍 현재 구현 상태

### 1. onReservationDeleted (비활성화됨)

```typescript:492:559:functions/src/index.ts
export const onReservationDeleted = functions.firestore
    .document('places/{placeId}/reservations/{reservationId}')
    .onDelete(async (snap: QueryDocumentSnapshot, context: EventContext) => {
        console.log('[onReservationDeleted] DISABLED (server callable transaction is the source of truth).');
        return;
        // ... 30일 이상 지난 빈 sessionReservations 삭제 로직
    });
```

**비활성화 이유**: 
- Callable 트랜잭션이 source of truth이므로 트리거가 중복 처리됨
- 하지만 정리 로직은 여전히 필요함

### 2. validateDataConsistency (비활성화됨)

```typescript:887:1001:functions/src/index.ts
export const validateDataConsistency = functions.pubsub
    .schedule('every 24 hours')
    .timeZone('Asia/Seoul')
    .onRun(async (context: EventContext) => {
        console.log('[validateDataConsistency] DISABLED (server callable transaction is the source of truth).');
        return;
        // ... 데이터 일관성 검증 및 수정 로직
    });
```

**비활성화 이유**: 
- Callable 트랜잭션이 source of truth이므로 검증이 중복됨
- 하지만 주기적 정리는 여전히 필요함

---

## ⚠️ 잠재적 문제점

### 1. 데이터 누적
- 과거 예약들이 계속 남아있어 데이터베이스 크기 증가
- sessionReservations 문서가 계속 누적됨
- 오래된 예약 데이터로 인한 쿼리 성능 저하 가능

### 2. 데이터 불일치 가능성
- 수동 삭제나 예외 상황에서 sessionReservations와 실제 예약 수가 불일치할 수 있음
- 검증 메커니즘이 없어 불일치를 자동으로 감지/수정할 수 없음

### 3. 비용 증가
- Firestore 읽기/쓰기 비용 증가
- 저장 공간 비용 증가

---

## ✅ 현재 구조의 장점

### 1. 트랜잭션 기반 일관성
- 모든 예약 생성/취소/이동이 트랜잭션으로 처리됨
- sessionReservations가 트랜잭션 내에서 직접 업데이트됨
- 실시간 데이터 일관성 보장

### 2. 안전성
- 트리거가 비활성화되어 있어 중복 처리 위험 없음
- Callable 함수가 단일 진실 소스로 작동

---

## 🔧 개선 방안

### 방안 1: 주기적 정리 스케줄 함수 추가 (권장)

**새로운 스케줄 함수 생성**:
- 매일 새벽 2시 실행
- 30일 이상 지난 과거 예약 조회
- 30일 이상 지난 빈 sessionReservations 삭제
- 데이터 일관성 검증 및 수정

**장점**:
- 기존 트랜잭션 로직과 충돌 없음
- 주기적 정리로 데이터베이스 유지보수
- 비용 절감

**구현 예시**:
```typescript
export const cleanupOldReservations = functions.pubsub
    .schedule('0 2 * * *') // 매일 새벽 2시
    .timeZone('Asia/Seoul')
    .onRun(async (context) => {
        const seoulNow = getSeoulDateTime();
        const thirtyDaysAgo = new Date(seoulNow.getTime() - 30 * 24 * 60 * 60 * 1000);
        const thirtyDaysAgoString = formatDate(thirtyDaysAgo);
        
        // 1. 30일 이상 지난 빈 sessionReservations 삭제
        const emptySessionReservations = await admin.firestore()
            .collection('sessionReservations')
            .where('reservedCount', '==', 0)
            .where('date', '<', thirtyDaysAgoString)
            .get();
        
        for (const doc of emptySessionReservations.docs) {
            await doc.ref.delete();
        }
        
        // 2. 데이터 일관성 검증 (선택적)
        // sessionReservations와 실제 예약 수 비교
    });
```

### 방안 2: onReservationDeleted 트리거 재활성화 (비권장)

**문제점**:
- Callable 트랜잭션과 중복 처리 위험
- 트랜잭션 내에서 이미 sessionReservations 업데이트 수행 중
- 데이터 불일치 가능성

### 방안 3: 수동 정리 (임시 방안)

**단점**:
- 관리자가 직접 정리해야 함
- 자동화되지 않음
- 실수 가능성

---

## 📊 권장 사항

### 즉시 구현 권장
1. **주기적 정리 스케줄 함수 추가** (방안 1)
   - 30일 이상 지난 빈 sessionReservations 삭제
   - 데이터 일관성 검증 (선택적)

### 장기적 고려사항
1. **과거 예약 보관 정책 결정**
   - 예약 기록을 얼마나 보관할지 결정
   - 보관 기간에 따른 자동 삭제 또는 아카이빙

2. **모니터링 추가**
   - sessionReservations 문서 수 모니터링
   - 예약 데이터 크기 모니터링
   - 비용 추적

---

## ✅ 결론

**현재 상태**: 
- ❌ 주기적 정리 메커니즘이 없음
- ✅ 트랜잭션 기반 일관성은 잘 유지됨
- ⚠️ 장기적으로 데이터 누적 문제 발생 가능

**권장 조치**:
- 주기적 정리 스케줄 함수 추가 (매일 새벽 2시)
- 30일 이상 지난 빈 sessionReservations 자동 삭제
- 데이터 일관성 검증 추가 (선택적)

**우선순위**: 중간 (장기적으로 필요하지만 즉시 치명적이지는 않음)

