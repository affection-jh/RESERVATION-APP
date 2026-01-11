# Firestore 데이터베이스 설계 개선안

## 🔍 발견된 주요 문제점

### 1. **세션별 예약 집계 비효율성**
- **현재 문제**: 캘린더 화면에서 각 세션의 남은 좌석을 표시할 때마다 `reservations` 컬렉션을 쿼리해야 함
- **영향**: N+1 쿼리 문제 (세션 10개 = 10번의 쿼리)
- **사용 패턴**: `session.getRemainingCapacityForDate(date)` 호출 시마다 예약 수를 계산

### 2. **날짜별 수용인원 오버라이드 관리 어려움**
- **현재 문제**: `Map<DateTime, int>` 구조로 Firestore에 저장되어 쿼리/업데이트가 복잡
- **영향**: 특정 날짜의 수용인원 변경 시 전체 Place 문서를 업데이트해야 함

### 3. **강좌별 멤버 조회 비효율성**
- **현재 문제**: 관리자 화면에서 강좌별 멤버를 보려면 모든 `enrollments`를 읽어야 함
- **영향**: 플레이스에 멤버가 많을수록 성능 저하

### 4. **실시간 업데이트 비효율성**
- **현재 문제**: 예약이 하나 추가되어도 전체 Place 문서를 다시 읽어야 세션 정보를 얻을 수 있음
- **영향**: 불필요한 데이터 전송 및 읽기 비용 증가

---

## ✅ 개선된 데이터베이스 구조

### 1. **sessionReservations** 컬렉션 추가 (집계 최적화)

```
sessionReservations/{sessionReservationId}
├── sessionId: string  // "courseId_dayOfWeek_startTime"
├── courseId: string
├── placeId: string
├── dayOfWeek: number
├── startTime: string
├── date: string  // "YYYY-MM-DD"
├── capacity: number  // 해당 날짜의 수용인원
├── reservedCount: number  // 예약된 인원 수 (집계)
├── lastUpdated: timestamp
└── reservationIds: string[]  // 예약 ID 목록 (선택적, 상세 조회용)
```

**장점:**
- 특정 날짜의 세션 예약 현황을 한 번의 쿼리로 조회 가능
- `reservedCount`를 실시간으로 업데이트하여 집계 비용 절감
- 날짜별 수용인원(`capacity`)을 별도로 관리 가능

**인덱스:**
- `sessionId`, `date` (복합)
- `courseId`, `date` (복합)
- `placeId`, `date` (복합)

### 2. **dateCapacityOverrides** 컬렉션 추가

```
dateCapacityOverrides/{overrideId}
├── sessionId: string  // "courseId_dayOfWeek_startTime"
├── date: string  // "YYYY-MM-DD"
├── capacity: number
└── createdAt: timestamp
```

**장점:**
- 날짜별 수용인원 오버라이드를 독립적으로 관리
- 특정 날짜의 수용인원만 업데이트 가능 (Place 전체 업데이트 불필요)
- 히스토리 관리 가능

**인덱스:**
- `sessionId`, `date` (복합, 유니크)

### 3. **courseMembers** 컬렉션 추가 (관계 최적화)

```
courseMembers/{memberId}
├── userId: string
├── courseId: string
├── placeId: string
├── enrollmentId: string  // enrollments 컬렉션 참조
├── enrolledAt: timestamp
└── isActive: boolean  // 유효한 등록인지
```

**장점:**
- 강좌별 멤버 조회가 매우 빠름 (단일 쿼리)
- 관리자 화면의 "강좌별" 탭 성능 향상
- enrollments와 중복이지만 읽기 최적화를 위한 전략적 중복

**인덱스:**
- `courseId`, `isActive` (복합)
- `placeId`, `courseId` (복합)
- `userId`, `courseId` (복합)

### 4. **sessions** 서브컬렉션 (선택적 개선)

```
places/{placeId}/courses/{courseId}/sessions/{sessionId}
├── dayOfWeek: number
├── startTime: string
├── endTime: string
├── defaultCapacity: number
└── createdAt: timestamp
```

**장점:**
- 세션 정보만 독립적으로 업데이트 가능
- Place 전체를 읽지 않고도 세션 정보 조회 가능
- 실시간 업데이트 효율성 향상

**단점:**
- 구조가 복잡해짐
- 기존 중첩 구조와의 호환성 문제

**권장사항:** 초기에는 중첩 구조 유지, 규모가 커지면 서브컬렉션으로 전환

---

## 📊 개선된 컬렉션 구조 요약

### 핵심 컬렉션

1. **users** - 사용자 정보 (변경 없음)
2. **adminUsers** - 관리자 정보 (변경 없음)
3. **places** - 장소 정보 (변경 없음, Course/Session은 중첩 유지)
4. **reservations** - 예약 상세 정보 (변경 없음)
5. **enrollments** - 코스 등록 정보 (변경 없음)

### 신규 컬렉션

6. **sessionReservations** ⭐ - 세션별 예약 집계 (핵심)
7. **dateCapacityOverrides** - 날짜별 수용인원 오버라이드
8. **courseMembers** - 강좌-멤버 관계 (읽기 최적화)

---

## 🔄 트랜잭션 및 업데이트 전략

### 예약 생성 시 (개선된 플로우)

```dart
Future<Reservation> createReservation(Reservation reservation) async {
  return await firestore.runTransaction((transaction) async {
    // 1. 사용자 등록 정보 확인 (기존과 동일)
    final enrollmentQuery = ...;
    final enrollment = ...;
    
    // 2. 세션 예약 현황 조회 (신규)
    final sessionId = '${reservation.courseId}_${reservation.dayOfWeek}_${reservation.startTime}';
    final dateString = _formatDate(reservation.reservedDate);
    
    final sessionReservationRef = firestore
        .collection('sessionReservations')
        .where('sessionId', isEqualTo: sessionId)
        .where('date', isEqualTo: dateString)
        .limit(1);
    
    final sessionReservationSnapshot = await transaction.get(sessionReservationRef);
    
    SessionReservation sessionReservation;
    if (sessionReservationSnapshot.docs.isEmpty) {
      // 첫 예약인 경우, sessionReservation 생성
      final place = await getPlace(reservation.placeId);
      final course = place.findCourse(reservation.courseId);
      final session = course.findSession(reservation.dayOfWeek, reservation.startTime);
      
      // 날짜별 수용인원 확인
      final capacityOverride = await getCapacityOverride(sessionId, dateString);
      final capacity = capacityOverride ?? session.capacity;
      
      sessionReservation = SessionReservation(
        sessionId: sessionId,
        courseId: reservation.courseId,
        placeId: reservation.placeId,
        dayOfWeek: reservation.dayOfWeek,
        startTime: reservation.startTime,
        date: dateString,
        capacity: capacity,
        reservedCount: 0,
      );
      
      final newRef = firestore.collection('sessionReservations').doc();
      transaction.set(newRef, sessionReservation.toJson());
      sessionReservation = sessionReservation.copyWith(id: newRef.id);
    } else {
      sessionReservation = SessionReservation.fromJson(
        sessionReservationSnapshot.docs.first.data()
      );
    }
    
    // 3. 수용인원 확인
    if (sessionReservation.reservedCount >= sessionReservation.capacity) {
      throw Exception('예약 가능한 인원이 없습니다.');
    }
    
    // 4. 예약 생성
    final reservationRef = firestore.collection('reservations').doc();
    transaction.set(reservationRef, {
      ...reservation.toJson(),
      'id': reservationRef.id,
      'placeId': reservation.placeId,
      'reservedDateString': dateString,
    });
    
    // 5. 세션 예약 집계 업데이트 (신규)
    transaction.update(
      sessionReservationSnapshot.docs.first.reference,
      {
        'reservedCount': sessionReservation.reservedCount + 1,
        'lastUpdated': FieldValue.serverTimestamp(),
      }
    );
    
    // 6. 등록 정보 업데이트 (기존과 동일)
    transaction.update(enrollmentSnapshot.docs.first.reference, {
      'remainingReservations': enrollment.remainingReservations - 1,
    });
    
    return reservation.copyWith(id: reservationRef.id);
  });
}
```

### 예약 삭제 시

```dart
Future<void> deleteReservation(String reservationId) async {
  return await firestore.runTransaction((transaction) async {
    // 1. 예약 정보 조회
    final reservationRef = firestore.collection('reservations').doc(reservationId);
    final reservationDoc = await transaction.get(reservationRef);
    final reservation = Reservation.fromJson(reservationDoc.data()!);
    
    // 2. 세션 예약 집계 업데이트 (신규)
    final sessionId = '${reservation.courseId}_${reservation.dayOfWeek}_${reservation.startTime}';
    final dateString = _formatDate(reservation.reservedDate);
    
    final sessionReservationQuery = firestore
        .collection('sessionReservations')
        .where('sessionId', isEqualTo: sessionId)
        .where('date', isEqualTo: dateString)
        .limit(1);
    
    final sessionReservationSnapshot = await transaction.get(sessionReservationQuery);
    if (sessionReservationSnapshot.docs.isNotEmpty) {
      final current = SessionReservation.fromJson(
        sessionReservationSnapshot.docs.first.data()
      );
      transaction.update(sessionReservationSnapshot.docs.first.reference, {
        'reservedCount': (current.reservedCount - 1).clamp(0, double.infinity),
        'lastUpdated': FieldValue.serverTimestamp(),
      });
    }
    
    // 3. 등록 정보 업데이트 (기존과 동일)
    // ...
    
    // 4. 예약 삭제
    transaction.delete(reservationRef);
  });
}
```

---

## 🚀 성능 개선 효과

### Before (기존 구조)
- 캘린더 화면 로드: Place 1회 + 각 세션별 예약 조회 N회 = **N+1 쿼리**
- 강좌별 멤버 조회: 모든 enrollments 읽기 = **O(n) 읽기**
- 날짜별 수용인원 변경: Place 전체 업데이트 = **큰 문서 업데이트**

### After (개선된 구조)
- 캘린더 화면 로드: Place 1회 + sessionReservations 1회 = **2회 쿼리**
- 강좌별 멤버 조회: courseMembers 필터링 = **1회 쿼리**
- 날짜별 수용인원 변경: dateCapacityOverrides만 업데이트 = **작은 문서 업데이트**

**예상 성능 향상:**
- 캘린더 화면 로드: **80-90% 감소** (10개 세션 기준)
- 강좌별 멤버 조회: **95% 감소** (100명 기준)
- 수용인원 변경: **90% 감소** (문서 크기 기준)

---

## 📝 마이그레이션 전략

### Phase 1: 신규 컬렉션 추가
1. `sessionReservations` 컬렉션 생성
2. `dateCapacityOverrides` 컬렉션 생성
3. `courseMembers` 컬렉션 생성

### Phase 2: 데이터 동기화
1. 기존 `reservations` 데이터를 기반으로 `sessionReservations` 집계
2. 기존 `enrollments` 데이터를 기반으로 `courseMembers` 생성
3. 기존 `dateCapacityOverrides` 데이터를 새 컬렉션으로 마이그레이션

### Phase 3: 코드 업데이트
1. 예약 생성/삭제 시 `sessionReservations` 업데이트 로직 추가
2. 캘린더 화면에서 `sessionReservations` 사용하도록 변경
3. 관리자 화면에서 `courseMembers` 사용하도록 변경

### Phase 4: 검증 및 최적화
1. 데이터 일관성 검증
2. 성능 모니터링
3. 필요시 추가 최적화

---

## ⚠️ 주의사항

### 1. 데이터 일관성
- `sessionReservations.reservedCount`와 실제 `reservations` 수가 일치해야 함
- **해결책**: 주기적인 검증 작업 또는 Cloud Functions로 자동 동기화

### 2. 중복 데이터 관리
- `courseMembers`는 `enrollments`와 중복
- **해결책**: `enrollments` 업데이트 시 `courseMembers`도 함께 업데이트

### 3. 트랜잭션 제한
- Firestore 트랜잭션은 최대 500개 문서 제한
- **해결책**: 배치 처리 또는 Cloud Functions 활용

---

## 🎯 최종 권장사항

### 즉시 적용 (High Priority)
1. ✅ **sessionReservations 컬렉션 추가** - 가장 큰 성능 향상
2. ✅ **dateCapacityOverrides 컬렉션 추가** - 관리 편의성 향상

### 단기 적용 (Medium Priority)
3. ✅ **courseMembers 컬렉션 추가** - 관리자 화면 성능 향상

### 장기 검토 (Low Priority)
4. ⚠️ **sessions 서브컬렉션 전환** - 규모가 커지면 검토
5. ⚠️ **Cloud Functions로 자동 동기화** - 데이터 일관성 보장

---

## 📊 비용 분석

### 읽기 비용 (월간 예상)
- **기존**: Place 읽기 10,000회 + 예약 조회 100,000회 = **110,000회**
- **개선**: Place 읽기 10,000회 + sessionReservations 조회 10,000회 = **20,000회**
- **절감**: **82% 감소** (월 $5.50 → $1.00, 약 $4.50 절감)

### 쓰기 비용 (월간 예상)
- **기존**: 예약 생성 5,000회 = **5,000회**
- **개선**: 예약 생성 5,000회 + sessionReservations 업데이트 5,000회 = **10,000회**
- **증가**: **100% 증가** (월 $0.18 → $0.36, 약 $0.18 증가)

### 순 비용 절감
- **월간**: 약 **$4.32 절감** (읽기 절감 > 쓰기 증가)
- **연간**: 약 **$52 절감**

**결론**: 읽기 비용 절감이 쓰기 비용 증가보다 훨씬 크므로, 전반적으로 비용 절감 효과가 큼

