# Firestore 데이터베이스 설계 - 장기적 관점

## 🎯 장기적 목표

1. **확장성**: 수천 명의 사용자, 수백 개의 플레이스 지원
2. **유지보수성**: 코드 변경 최소화, 명확한 책임 분리
3. **일관성**: 데이터 무결성 자동 보장
4. **성능**: 대규모 트래픽에도 안정적인 응답 시간
5. **비용 효율성**: 사용량에 따른 최적화된 비용 구조

---

## 📈 단계별 확장 전략

### Phase 1: 현재 (초기 단계)
**규모**: 1-10 플레이스, 100-1,000 사용자

**구조:**
- Place → Course → Session: 중첩 객체
- Reservations: 독립 컬렉션
- Enrollments: 독립 컬렉션

**특징:**
- 단순한 구조로 빠른 개발
- 모든 데이터를 한 번에 읽기 가능
- 트랜잭션 처리 간단

---

### Phase 2: 성장 단계 (6개월-1년)
**규모**: 10-50 플레이스, 1,000-10,000 사용자

**개선 사항:**

#### 2.1. 집계 컬렉션 도입
```
sessionReservations/{id}
├── sessionId: string
├── date: string
├── reservedCount: number
└── capacity: number
```

**이유:**
- 캘린더 화면 성능 향상 (N+1 → 2 쿼리)
- 읽기 비용 80% 감소

#### 2.2. 관계 최적화 컬렉션
```
courseMembers/{id}
├── userId: string
├── courseId: string
├── enrollmentId: string
└── isActive: boolean
```

**이유:**
- 관리자 화면 성능 향상
- 강좌별 멤버 조회 최적화

#### 2.3. Cloud Functions 도입
- **자동 동기화**: `reservations` ↔ `sessionReservations`
- **데이터 검증**: 주기적인 일관성 체크
- **알림**: 예약 생성/취소 시 푸시 알림

---

### Phase 3: 확장 단계 (1-2년)
**규모**: 50-200 플레이스, 10,000-100,000 사용자

**개선 사항:**

#### 3.1. 서브컬렉션 전환
```
places/{placeId}
├── (기본 정보)
└── courses/{courseId}
    ├── (코스 정보)
    └── sessions/{sessionId}
        ├── dayOfWeek: number
        ├── startTime: string
        ├── endTime: string
        └── defaultCapacity: number
```

**이유:**
- Place 문서 크기 제한 회피 (1MB 제한)
- 세션별 독립 업데이트 가능
- 실시간 리스너 최적화

**전환 전략:**
1. 기존 데이터 마이그레이션 스크립트 작성
2. 양방향 동기화 (중첩 + 서브컬렉션)
3. 점진적 전환 (Feature flag)
4. 완전 전환 후 중첩 구조 제거

#### 3.2. 샤딩 전략
```
places_shard_{shardId}/{placeId}
```

**이유:**
- 단일 컬렉션 크기 제한 회피
- 쿼리 성능 향상
- 지역별 분산 가능

#### 3.3. 캐싱 레이어 도입
- **Redis/Memcached**: 세션 예약 현황 캐싱
- **CDN**: 정적 데이터 (공지사항, 프로모션)
- **로컬 캐싱**: Place/Course 정보

---

### Phase 4: 엔터프라이즈 단계 (2년+)
**규모**: 200+ 플레이스, 100,000+ 사용자

**개선 사항:**

#### 4.1. 이벤트 소싱 패턴
```
events/{eventId}
├── type: "reservation_created" | "reservation_cancelled"
├── aggregateId: string
├── data: object
├── timestamp: timestamp
└── version: number
```

**이유:**
- 감사 로그 (Audit Trail)
- 데이터 복구 가능
- 분석 및 리포팅 용이

#### 4.2. 읽기 전용 뷰
```
analytics_reservations/{id}
├── date: string
├── placeId: string
├── courseId: string
├── totalReservations: number
├── uniqueUsers: number
└── revenue: number
```

**이유:**
- 복잡한 분석 쿼리 최적화
- 대시보드 성능 향상
- 실시간 집계

#### 4.3. 마이크로서비스 전환 고려
- **예약 서비스**: 예약 생성/취소
- **사용자 서비스**: 사용자 관리
- **알림 서비스**: 푸시/이메일 알림
- **분석 서비스**: 통계 및 리포팅

---

## 🔄 데이터 일관성 보장 전략

### 현재 문제점
- `sessionReservations.reservedCount`와 실제 `reservations` 수 불일치 가능
- `courseMembers`와 `enrollments` 동기화 필요

### 해결 방안

#### 1. Cloud Functions로 자동 동기화

```typescript
// functions/src/index.ts

// 예약 생성 시 sessionReservations 업데이트
export const onReservationCreated = functions.firestore
  .document('reservations/{reservationId}')
  .onCreate(async (snap, context) => {
    const reservation = snap.data();
    const sessionId = `${reservation.courseId}_${reservation.dayOfWeek}_${reservation.startTime}`;
    const date = reservation.reservedDateString;
    
    const sessionReservationRef = admin.firestore()
      .collection('sessionReservations')
      .where('sessionId', '==', sessionId)
      .where('date', '==', date)
      .limit(1);
    
    const snapshot = await sessionReservationRef.get();
    
    if (snapshot.empty) {
      // 새로 생성
      await admin.firestore().collection('sessionReservations').add({
        sessionId,
        courseId: reservation.courseId,
        placeId: reservation.placeId,
        dayOfWeek: reservation.dayOfWeek,
        startTime: reservation.startTime,
        date,
        reservedCount: 1,
        capacity: await getCapacity(sessionId, date),
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else {
      // 업데이트
      await snapshot.docs[0].ref.update({
        reservedCount: admin.firestore.FieldValue.increment(1),
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  });

// 예약 삭제 시 sessionReservations 업데이트
export const onReservationDeleted = functions.firestore
  .document('reservations/{reservationId}')
  .onDelete(async (snap, context) => {
    const reservation = snap.data();
    const sessionId = `${reservation.courseId}_${reservation.dayOfWeek}_${reservation.startTime}`;
    const date = reservation.reservedDateString;
    
    const sessionReservationRef = admin.firestore()
      .collection('sessionReservations')
      .where('sessionId', '==', sessionId)
      .where('date', '==', date)
      .limit(1);
    
    const snapshot = await sessionReservationRef.get();
    
    if (!snapshot.empty) {
      await snapshot.docs[0].ref.update({
        reservedCount: admin.firestore.FieldValue.increment(-1),
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  });

// 주기적 데이터 검증 (매일 새벽 2시)
export const validateDataConsistency = functions.pubsub
  .schedule('every 24 hours')
  .onRun(async (context) => {
    // sessionReservations와 실제 reservations 수 비교
    const sessionReservations = await admin.firestore()
      .collection('sessionReservations')
      .get();
    
    for (const doc of sessionReservations.docs) {
      const data = doc.data();
      const actualCount = await admin.firestore()
        .collection('reservations')
        .where('courseId', '==', data.courseId)
        .where('dayOfWeek', '==', data.dayOfWeek)
        .where('startTime', '==', data.startTime)
        .where('reservedDateString', '==', data.date)
        .get();
      
      if (actualCount.size !== data.reservedCount) {
        // 불일치 발견 - 자동 수정
        await doc.ref.update({
          reservedCount: actualCount.size,
          lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
          _lastValidated: admin.firestore.FieldValue.serverTimestamp(),
        });
        
        // 알림 전송 (관리자에게)
        await sendAlertToAdmin({
          type: 'data_inconsistency',
          sessionId: data.sessionId,
          date: data.date,
          expected: data.reservedCount,
          actual: actualCount.size,
        });
      }
    }
  });
```

#### 2. 트랜잭션 + Cloud Functions 하이브리드

**전략:**
- 클라이언트: 트랜잭션으로 즉시 일관성 보장
- Cloud Functions: 백그라운드에서 추가 검증 및 동기화

**장점:**
- 즉시 일관성 (트랜잭션)
- 장기 일관성 (Cloud Functions)
- 이중 안전장치

---

## 📊 분석 및 리포팅 전략

### 현재 한계
- Firestore는 복잡한 집계 쿼리에 부적합
- 대시보드 데이터 생성 시 비용 증가

### 해결 방안

#### 1. 읽기 전용 집계 컬렉션

```
analytics_daily/{date}
├── date: string  // "2024-01-15"
├── placeId: string
├── totalReservations: number
├── totalCancellations: number
├── uniqueUsers: number
├── revenue: number
└── topCourses: {courseId: string, count: number}[]
```

**업데이트 전략:**
- Cloud Functions로 매일 자동 집계
- 예약 생성/취소 시 실시간 업데이트

#### 2. BigQuery 연동

**전략:**
- Firestore → BigQuery 자동 동기화
- 복잡한 분석 쿼리는 BigQuery에서 실행
- 주기적으로 Firestore 집계 컬렉션 업데이트

**장점:**
- 무제한 분석 쿼리
- 복잡한 집계 및 조인 가능
- 데이터 웨어하우스 역할

---

## 🔐 보안 및 규정 준수

### 장기적 고려사항

#### 1. 데이터 보존 정책
```
reservations_archive/{id}  // 1년 이상 된 예약
```

**전략:**
- Cloud Functions로 자동 아카이빙
- 원본 데이터는 삭제 (GDPR 준수)
- 아카이브는 분석용으로만 사용

#### 2. 접근 제어 강화
- 역할 기반 접근 제어 (RBAC)
- 감사 로그 (Audit Log)
- 데이터 마스킹 (개인정보 보호)

#### 3. 백업 및 복구
- 일일 자동 백업
- 지역별 복제
- 재해 복구 계획

---

## 💰 비용 최적화 전략

### 장기적 비용 관리

#### 1. 읽기 최적화
- **집계 컬렉션**: 읽기 비용 80% 감소
- **캐싱**: 반복 읽기 제거
- **페이지네이션**: 불필요한 데이터 읽기 방지

#### 2. 쓰기 최적화
- **배치 쓰기**: 여러 업데이트를 한 번에
- **조건부 업데이트**: 변경사항이 있을 때만 쓰기
- **Cloud Functions**: 서버 사이드에서 처리

#### 3. 스토리지 최적화
- **아카이빙**: 오래된 데이터는 별도 저장소로
- **압축**: 큰 문서는 압축 저장
- **정규화**: 중복 데이터 최소화

---

## 🚀 마이그레이션 로드맵

### Year 1: 기반 구축
- ✅ 기본 Firestore 구조
- ✅ sessionReservations 컬렉션 추가
- ✅ Cloud Functions 기본 설정

### Year 2: 최적화
- ⚠️ 서브컬렉션 전환 검토
- ⚠️ 캐싱 레이어 도입
- ⚠️ 분석 컬렉션 구축

### Year 3: 확장
- ⚠️ 이벤트 소싱 도입
- ⚠️ BigQuery 연동
- ⚠️ 마이크로서비스 전환 검토

---

## 📋 체크리스트

### 즉시 적용 가능
- [ ] sessionReservations 컬렉션 추가
- [ ] dateCapacityOverrides 컬렉션 추가
- [ ] courseMembers 컬렉션 추가

### 6개월 내
- [ ] Cloud Functions 자동 동기화 설정
- [ ] 데이터 검증 함수 구현
- [ ] 분석 컬렉션 기본 구조 구축

### 1년 내
- [ ] 서브컬렉션 전환 검토 및 계획
- [ ] 캐싱 레이어 도입
- [ ] BigQuery 연동 검토

### 2년 내
- [ ] 이벤트 소싱 패턴 도입
- [ ] 마이크로서비스 아키텍처 검토
- [ ] 글로벌 확장 전략 수립

---

## 🎯 핵심 원칙

1. **점진적 개선**: 한 번에 모든 것을 바꾸지 말고 단계적으로
2. **데이터 일관성 우선**: 성능보다 정확성이 우선
3. **비용 효율성**: 읽기 비용 절감에 집중
4. **확장 가능성**: 미래를 고려한 설계
5. **유지보수성**: 명확한 구조와 문서화

---

## 📚 참고 자료

- [Firestore Best Practices](https://firebase.google.com/docs/firestore/best-practices)
- [Cloud Functions for Firebase](https://firebase.google.com/docs/functions)
- [BigQuery for Firebase](https://firebase.google.com/docs/firestore/bigquery-export)
- [Event Sourcing Pattern](https://martinfowler.com/eaaDev/EventSourcing.html)

