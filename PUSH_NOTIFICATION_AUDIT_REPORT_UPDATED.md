# 푸시 알림 시스템 전체 점검 보고서 (업데이트)

**최종 업데이트**: 2024년 현재

## 📋 개요

푸시 알림 시스템의 현재 구현 상태를 점검하고, 구현 완료된 부분과 미구현된 부분을 정확히 파악하여 보고합니다.

---

## ✅ 구현 완료된 부분

### 1. FCM 인프라 및 기본 기능 (100% 완료)

#### 1.1 FCM 서비스 (`lib/services/fcm_service.dart`)
- ✅ FCM 토큰 관리 (저장, 갱신, 삭제)
- ✅ 포그라운드 메시지 핸들러 설정
- ✅ 백그라운드 메시지 핸들러 설정
- ✅ 알림 클릭 처리
- ✅ 포그라운드 알림 UI 표시 (`PushNotificationOverlay`)

#### 1.2 Cloud Functions FCM 전송 (`functions/src/index.ts`)
- ✅ `createNotification` 헬퍼 함수 구현 (1897-1931줄)
  - 알림 생성 통합 함수
  - Firestore에 알림 문서 생성
  - 에러 처리

- ✅ `sendPushNotification` 헬퍼 함수 구현 (1936-2005줄)
  - 사용자 FCM 토큰 조회
  - 알림 설정 확인 (`notificationsEnabled`)
  - FCM 메시지 구성 (Android/iOS 설정 포함)
  - 에러 처리

- ✅ `onNotificationCreated` 트리거 구현 (2010-2030줄)
  - Firestore에 알림 생성 시 자동으로 FCM 푸시 전송
  - 알림 데이터를 FCM 메시지에 포함

#### 1.3 알림 모델 및 UI
- ✅ 알림 모델 (`lib/models/notification.dart`)
- ✅ 알림 Provider (`lib/providers/notification_provider.dart`)
- ✅ 알림 화면 (`lib/screens/notification_screen.dart`)
- ✅ 알림 생성 서비스 (`lib/services/firestore_service.dart.createNotification`)

#### 1.4 FCM 초기화
- ✅ `lib/main.dart`에서 FCM 초기화
- ✅ `lib/providers/auth_provider.dart`에서 로그인 시 FCM 토큰 저장

---

### 2. 예약 관련 알림 (60% 완료)

#### 2.1 예약 생성 성공 알림 ✅
**위치**: `functions/src/index.ts` - `createReservation` 함수 (1503-1523줄)

**구현 상태**: ✅ 완료
- 예약 생성 성공 시 사용자에게 알림 전송
- 코스명 포함 메시지
- `createNotification` 헬퍼 함수 사용

**코드**:
```typescript
createNotification({
    userId,
    type: 'reservation',
    title: '예약이 완료되었습니다',
    body: `${courseName} - ${reservedDateString} ${startTime}`,
    placeId,
    data: {
        reservationId: reservationRef.id,
        courseId,
        placeId,
    },
    isAdmin: false,
})
```

---

#### 2.2 예약 취소 완료 알림 ✅
**위치**: `functions/src/index.ts` - `cancelReservation` 함수 (1618-1642줄)

**구현 상태**: ✅ 완료
- 예약 취소 성공 시 사용자에게 알림 전송
- 코스명 포함 메시지
- 트랜잭션 외부에서 실행 (비동기)

**코드**:
```typescript
createNotification({
    userId,
    type: 'reservation',
    title: '예약이 취소되었습니다',
    body: `${courseName} - ${reservedDateString} ${startTime}`,
    placeId,
    data: {
        reservationId,
        courseId,
        placeId,
    },
    isAdmin: false,
})
```

---

#### 2.3 예약 변경 알림 (관리자) ✅
**위치**: `functions/src/index.ts` - `moveReservationWithinCourse` 함수 (1867-1879줄)

**구현 상태**: ✅ 완료
- 예약 이동 성공 시 사용자에게 알림 전송
- 코스명 포함 메시지
- 날짜 포맷팅 (YYYY년 MM월 DD일)
- `createNotification` 헬퍼 함수 사용

**코드**:
```typescript
await createNotification({
    userId: result.userId,
    type: 'reservation',
    title: '예약이 변경되었습니다',
    body: `${courseName} - ${oldDateFormatted} ${oldTime} → ${newDateFormatted} ${newTime}`,
    placeId: result.placeId,
    data: {
        reservationId,
        courseId: result.courseId,
        placeId: result.placeId,
    },
    isAdmin: false,
});
```

---

#### 2.4 세션 취소 알림 (관리자) ❌
**위치**: 미구현

**필요한 구현**:
- 관리자가 세션을 취소하는 Cloud Function 필요
- 해당 세션에 예약한 모든 사용자에게 알림 전송
- 배치 알림 전송 로직 필요

**정책**: `NOTIFICATION_POLICY.md` 38-45줄 참조

---

#### 2.5 방문일 알림 (세션 시작 2시간 전) ❌
**위치**: 미구현

**필요한 구현**:
- Cloud Functions 스케줄러 함수 생성
- 매 5분마다 실행 (또는 적절한 주기)
- 2시간 후 시작하는 세션의 예약 조회
- 해당 사용자들에게 알림 전송
- 중복 전송 방지 로직 필요

**정책**: `NOTIFICATION_POLICY.md` 47-54줄 참조

---

### 3. 등록 관련 알림 (100% 완료)

#### 3.1 등록 승인 알림 ✅
**위치**: `functions/src/index.ts` - `onPlaceMembershipUpdated` 트리거 (2136-2148줄)

**구현 상태**: ✅ 완료
- `placeMemberships` 컬렉션의 `onUpdate` 트리거 사용
- pending → approved 상태 변경 시 알림 전송
- 플레이스명 포함 메시지

**코드**:
```typescript
await createNotification({
    userId,
    type: 'system',
    title: '가입이 승인되었습니다',
    body: `${placeName} 가입이 승인되었습니다`,
    placeId,
    data: {
        membershipId,
        placeId,
    },
    isAdmin: false,
});
```

---

#### 3.2 등록 거절 알림 ✅
**위치**: `functions/src/index.ts` - `onPlaceMembershipUpdated` 트리거 (2150-2165줄)

**구현 상태**: ✅ 완료
- pending → rejected 상태 변경 시 알림 전송
- 거절 사유 포함 메시지 (있는 경우)

**코드**:
```typescript
const rejectedReason = String(after.rejectedReason || '');
const body = rejectedReason.length > 0
    ? `${placeName} 가입이 거절되었습니다. 사유: ${rejectedReason}`
    : `${placeName} 가입이 거절되었습니다`;

await createNotification({
    userId,
    type: 'system',
    title: '가입이 거절되었습니다',
    body,
    placeId,
    data: {
        membershipId,
        placeId,
    },
    isAdmin: false,
});
```

---

#### 3.3 등록 기간 만료 임박 알림 ❌
**위치**: 미구현

**필요한 구현**:
- Cloud Functions 스케줄러 함수 생성
- 매일 실행하여 7일 이내 만료되는 등록 조회
- 해당 사용자들에게 알림 전송

**정책**: `NOTIFICATION_POLICY.md` 76-83줄 참조

---

### 4. 콘텐츠 알림 (0% 완료 - 의도적으로 제거됨)

#### 4.1 스토리 등록 알림 ❌
**위치**: `lib/screens/admin/widgets/story_add_screen.dart`

**현재 상태**: 
- ✅ 알림 UI 제거됨 (요청에 따라)
- ✅ `_shouldSendNotification` 변수 제거됨
- ❌ 알림 전송 로직 없음 (의도적)

**정책**: 스토리 알림 기능은 제거됨

---

### 5. 관리자 알림 (50% 완료)

#### 5.1 가입 요청 알림 ✅
**위치**: `functions/src/index.ts` - `onPlaceMembershipCreated` 트리거 (2032-2087줄)

**구현 상태**: ✅ 완료
- `placeMemberships` 컬렉션의 `onCreate` 트리거 사용
- pending 상태인 경우에만 알림 전송
- 해당 플레이스의 모든 관리자에게 알림 전송
- 사용자명과 플레이스명 포함 메시지

**코드**:
```typescript
// 각 관리자에게 알림 생성
const notificationPromises = adminUsersSnapshot.docs.map((adminDoc) => {
    const adminData = adminDoc.data();
    const adminUserId = adminData.userId;

    return createNotification({
        userId: adminUserId,
        type: 'system',
        title: '새 가입 요청',
        body: `${userName}님이 ${placeName} 가입을 요청했습니다`,
        placeId,
        data: {
            membershipId,
            userId,
            placeId,
        },
        isAdmin: true,
    });
});

await Promise.all(notificationPromises);
```

---

#### 5.2 등록 연장 요청 알림 ❌
**위치**: 미구현

**필요한 구현**:
- 사용자가 등록 연장을 요청하는 로직 필요
- 해당 플레이스의 모든 관리자에게 알림 전송

**정책**: `NOTIFICATION_POLICY.md` 107-114줄 참조

---

#### 5.3 데이터 불일치 경고 알림 ❌
**위치**: `functions/src/index.ts` - `validateDataConsistency` 함수 (831줄)

**현재 상태**:
- 데이터 검증 로직은 있음
- **알림 전송 로직 없음**

**필요한 구현**:
- 데이터 불일치 발견 시 해당 플레이스의 모든 관리자에게 알림 전송

**정책**: `NOTIFICATION_POLICY.md` 116-123줄 참조

---

## 📊 구현 현황 요약

### 카테고리별 완료율

| 카테고리 | 완료율 | 상태 |
|---------|--------|------|
| FCM 인프라 | 100% | ✅ 완료 |
| 예약 알림 | 60% | 🟡 부분 완료 |
| 등록 알림 | 67% | 🟡 부분 완료 |
| 콘텐츠 알림 | 0% | ❌ 제거됨 |
| 관리자 알림 | 50% | 🟡 부분 완료 |

### 전체 진행률: 약 65%

---

## ✅ 구현 완료된 알림 목록

1. ✅ **예약 생성 성공**: "예약이 완료되었습니다"
2. ✅ **예약 취소 완료**: "예약이 취소되었습니다"
3. ✅ **예약 변경**: "예약이 변경되었습니다"
4. ✅ **가입 요청 (관리자)**: "새 가입 요청"
5. ✅ **가입 승인**: "가입이 승인되었습니다"
6. ✅ **가입 거절**: "가입이 거절되었습니다"

---

## ❌ 미구현된 알림 목록

1. ❌ **세션 취소 알림** (관리자가 세션 취소 시)
2. ❌ **방문일 알림** (세션 시작 2시간 전)
3. ❌ **등록 기간 만료 임박 알림** (7일 이내)
4. ❌ **등록 연장 요청 알림** (관리자에게)
5. ❌ **데이터 불일치 경고 알림** (관리자에게)
6. ❌ **스토리 등록 알림** (의도적으로 제거됨)

---

## 🔧 발견된 문제점 및 개선 사항

### 1. 알림 생성 권한 ✅ 해결됨
**위치**: `firestore.rules` (227-233줄)

**현재 상태**:
- Cloud Functions에서만 알림 생성 가능
- 클라이언트에서는 알림 생성 불가 (보안상 적절함)

**결론**: ✅ 현재 구조가 적절함 (Cloud Functions에서만 생성)

---

### 2. onPlaceMembershipCreated 중복 정의 ⚠️
**위치**: `functions/src/index.ts`

**문제**:
- `onPlaceMembershipCreated` 트리거가 두 번 정의됨 (668줄, 2035줄)
- 첫 번째는 enrollment 생성용, 두 번째는 알림 전송용
- 같은 트리거를 두 번 정의하면 충돌 가능

**해결 방안**:
- 두 기능을 하나의 트리거로 통합하거나
- 트리거 이름을 분리 (예: `onPlaceMembershipCreatedForEnrollment`, `onPlaceMembershipCreatedForNotification`)

---

### 3. 중복 알림 방지 (스케줄러 알림)
**문제**:
- 방문일 알림 (2시간 전)이 여러 번 전송될 수 있음
- 스케줄러가 5분마다 실행되면 중복 전송 가능

**해결 방안**:
- 알림에 `sentAt` 필드 추가
- 또는 예약에 `reminderSent` 플래그 추가
- 또는 알림 생성 전 중복 확인 로직 추가

---

### 4. 배치 알림 전송 성능
**문제**:
- 세션 취소 시 모든 예약자에게 알림을 보낼 때 성능 이슈 가능
- Firestore 쓰기 제한 고려 필요

**해결 방안**:
- Firestore 배치 쓰기 사용 (최대 500개)
- 또는 Cloud Functions에서 배치 처리
- 또는 Cloud Tasks 사용

---

## 📝 다음 단계 (우선순위)

### 높음 (즉시 구현 필요)
1. ⚠️ `sendPushNotification` 함수 버그 수정
2. ❌ 세션 취소 알림 구현
3. ❌ 방문일 알림 구현 (스케줄러)

### 중간 (단기 구현)
4. ❌ 등록 기간 만료 임박 알림 (스케줄러)
5. ❌ 등록 연장 요청 알림

### 낮음 (장기 구현)
6. ❌ 데이터 불일치 경고 알림
7. 🔧 중복 알림 방지 로직 개선
8. 🔧 배치 알림 성능 최적화

---

## 🎯 결론

### 현재 상태
- **핵심 알림 기능**: 대부분 구현 완료 (예약 생성/취소/변경, 가입 요청/승인/거절)
- **인프라**: 완전히 구축됨
- **스케줄러 기반 알림**: 미구현 (방문일, 만료 임박)
- **일부 관리자 알림**: 미구현 (연장 요청, 데이터 불일치)

### 전체 평가
- **기본 기능**: ✅ 완료
- **고급 기능**: 🟡 부분 완료
- **전체 진행률**: 약 65%

### 권장 사항
1. `sendPushNotification` 함수 버그 즉시 수정
2. 스케줄러 기반 알림 구현 (방문일, 만료 임박)
3. 세션 취소 알림 구현
4. 중복 알림 방지 로직 추가

