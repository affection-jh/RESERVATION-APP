# 알림 정책

## 개요

시스템에서 사용자에게 전송되는 알림의 종류, 조건, 우선순위를 정의합니다.

## 알림 타입

### 1. 예약 관련 알림 (NotificationType.reservation)

#### 1.1 예약 생성 성공
- **트리거**: 예약이 성공적으로 생성됨
- **대상**: 예약한 사용자
- **내용**: 
  - 제목: "예약이 완료되었습니다"
  - 본문: "{코스명} - {날짜} {시간}"
- **우선순위**: 높음
- **즉시 전송**: ✅

#### 1.2 예약 취소 완료
- **트리거**: 사용자가 예약을 취소함
- **대상**: 취소한 사용자
- **내용**:
  - 제목: "예약이 취소되었습니다"
  - 본문: "{코스명} - {날짜} {시간}"
- **우선순위**: 중간
- **즉시 전송**: ✅

#### 1.3 예약 변경 (관리자)
- **트리거**: 관리자가 예약을 변경함 (시간/날짜 이동)
- **대상**: 예약한 사용자
- **내용**:
  - 제목: "예약이 변경되었습니다"
  - 본문: "{코스명} - {기존 날짜/시간} → {새 날짜/시간}"
- **우선순위**: 높음
- **즉시 전송**: ✅

#### 1.4 세션 취소 (관리자)
- **트리거**: 관리자가 세션을 취소함
- **대상**: 해당 세션에 예약한 모든 사용자
- **내용**:
  - 제목: "세션이 취소되었습니다"
  - 본문: "{코스명} - {날짜} {시간} 세션이 취소되었습니다"
- **우선순위**: 매우 높음
- **즉시 전송**: ✅

#### 1.5 방문일 알림
- **트리거**: 세션 시작 2시간 전
- **대상**: 예약한 사용자
- **내용**:
  - 제목: "곧 세션이 시작됩니다"
  - 본문: "{코스명} - {날짜} {시간} (2시간 전)"
- **우선순위**: 높음
- **즉시 전송**: ❌ (스케줄러로 전송)

### 2. 등록 관련 알림 (NotificationType.system)

#### 2.1 등록 승인
- **트리거**: 관리자가 플레이스 가입 요청을 승인함
- **대상**: 가입 요청한 사용자
- **내용**:
  - 제목: "가입이 승인되었습니다"
  - 본문: "{플레이스명} 가입이 승인되었습니다"
- **우선순위**: 높음
- **즉시 전송**: ✅

#### 2.2 등록 거절
- **트리거**: 관리자가 플레이스 가입 요청을 거절함
- **대상**: 가입 요청한 사용자
- **내용**:
  - 제목: "가입이 거절되었습니다"
  - 본문: "{플레이스명} 가입이 거절되었습니다"
- **우선순위**: 중간
- **즉시 전송**: ✅

#### 2.3 등록 기간 만료 임박
- **트리거**: 등록 유효 기간이 7일 이내로 남음
- **대상**: 등록한 사용자
- **내용**:
  - 제목: "등록 기간이 곧 만료됩니다"
  - 본문: "{코스명} 등록 기간이 {남은 일수}일 후 만료됩니다"
- **우선순위**: 중간
- **즉시 전송**: ❌ (스케줄러로 전송)

### 3. 콘텐츠 알림

#### 3.1 스토리 등록 알림 (선택)
- **트리거**: 관리자가 스토리를 등록할 때 "알림 전송"을 선택함
- **대상**: 해당 플레이스의 모든 멤버
- **내용**:
  - 제목: "새 소식이 있습니다"
  - 본문: "{스토리 제목}"
- **우선순위**: 낮음
- **즉시 전송**: ✅ (관리자 선택 시에만)

### 4. 관리자 알림 (isAdminNotification: true)

#### 4.1 가입 요청 알림
- **트리거**: 사용자가 플레이스 가입 요청을 생성함
- **대상**: 해당 플레이스의 모든 관리자
- **내용**:
  - 제목: "새 가입 요청"
  - 본문: "{사용자명}님이 가입을 요청했습니다"
- **우선순위**: 높음
- **즉시 전송**: ✅

#### 4.2 등록 연장 요청
- **트리거**: 사용자가 등록 연장을 요청함
- **대상**: 해당 플레이스의 모든 관리자
- **내용**:
  - 제목: "등록 연장 요청"
  - 본문: "{사용자명}님이 {코스명} 등록 연장을 요청했습니다"
- **우선순위**: 중간
- **즉시 전송**: ✅

#### 4.3 데이터 불일치 경고
- **트리거**: 데이터 검증에서 불일치 발견
- **대상**: 해당 플레이스의 모든 관리자
- **내용**:
  - 제목: "데이터 불일치 감지"
  - 본문: "{세션ID}의 예약 수가 일치하지 않습니다"
- **우선순위**: 높음
- **즉시 전송**: ✅

## 알림 전송 규칙

### 즉시 전송
- 사용자 액션에 대한 즉각적인 피드백이 필요한 경우
- 예: 예약 생성, 취소, 승인/거절

### 스케줄러 전송
- 특정 시점에 전송해야 하는 경우
- 예: 세션 시작 2시간 전 알림(방문일 알림), 등록 기간 만료 임박 알림

### 배치 전송
- 여러 사용자에게 동일한 알림을 보내는 경우
- 예: (현재 정책에서는 사용하지 않음)

## 알림 우선순위

1. **매우 높음**: 세션 취소, 데이터 불일치
2. **높음**: 예약 생성/변경, 가입 승인/거절, 가입 요청
3. **중간**: 예약 취소, 등록 기간 만료 임박, 등록 연장 요청
4. **낮음**: 스토리 등록 알림(관리자 선택 시)

## 알림 설정

### 사용자 알림 설정
- 예약 관련 알림: 기본 ON
- 콘텐츠 알림: 기본 ON (사용자가 설정 가능)
- 시스템 알림: 기본 ON

### 관리자 알림 설정
- 가입 요청: 기본 ON
- 등록 연장 요청: 기본 ON
- 데이터 불일치: 기본 ON

## 구현 상태

### ✅ 구현 완료
- 알림 모델 (`lib/models/notification.dart`)
- 알림 Provider (`lib/providers/notification_provider.dart`)
- 알림 화면 (`lib/screens/notification_screen.dart`)
- Firestore 알림 컬렉션 구조

### ⚠️ 구현 필요
- 예약 생성/취소/변경 시 알림 전송 로직
- 스케줄러 기반 알림 (세션 시작 2시간 전 등)
- 스토리 등록 시 알림 전송 여부 선택 UI + 연동
- 관리자 알림 전송 로직

## 알림 전송 구현 가이드

### 즉시 알림 전송 예시

```typescript
// functions/src/index.ts
async function sendNotification({
    userId,
    type,
    title,
    body,
    data,
    isAdmin = false,
}: {
    userId: string;
    type: NotificationType;
    title: string;
    body: string;
    data?: Record<string, any>;
    isAdmin?: boolean;
}) {
    await admin.firestore().collection('notifications').add({
        userId,
        type: type.name,
        title,
        body,
        data,
        isAdminNotification: isAdmin,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
}

// 예약 생성 시
export const createReservation = functions.https.onCall(async (data, context) => {
    // ... 예약 생성 로직 ...
    
    // 알림 전송
    await sendNotification({
        userId,
        type: NotificationType.reservation,
        title: '예약이 완료되었습니다',
        body: `${course.name} - ${reservedDateString} ${startTime}`,
        data: { reservationId: reservationRef.id },
    });
});
```

### 스케줄러 알림 예시 (방문일 알림: 2시간 전)

```typescript
// 매 5분마다 실행(2시간 전 알림은 시간 단위 크론보다 촘촘하게)
export const sendUpcomingSessionNotifications = functions.pubsub
    .schedule('every 5 minutes')
    .timeZone('Asia/Seoul')
    .onRun(async () => {
        const now = new Date();
        const inTwoHours = new Date(now.getTime() + 2 * 60 * 60 * 1000);
        const targetDateString = formatDate(inTwoHours); // "YYYY-MM-DD"
        const targetHHmm = formatHHmm(inTwoHours); // "HH:mm"
        
        // 2시간 후 세션이 있는 예약 조회(날짜 + 시작시각)
        const reservations = await admin.firestore()
            .collection('reservations')
            .where('reservedDateString', '==', targetDateString)
            .where('startTime', '==', targetHHmm)
            .get();
        
        for (const doc of reservations.docs) {
            const reservation = doc.data();
            await sendNotification({
                userId: reservation.userId,
                type: NotificationType.reservation,
                title: '곧 세션이 시작됩니다',
                body: `${reservation.courseId} - ${reservation.reservedDateString} ${reservation.startTime} (2시간 전)`,
            });
        }
    });
```

## 알림 데이터 구조

```typescript
{
    id: string;
    userId: string;
    placeId?: string;
    type: 'reservation' | 'story' | 'promotion' | 'system';
    title: string;
    body: string;
    createdAt: Timestamp;
    isRead: boolean;
    isAdminNotification: boolean;
    data?: {
        reservationId?: string;
        courseId?: string;
        // 기타 관련 데이터
    };
}
```

## 알림 읽음 처리

- 사용자가 알림을 클릭하면 자동으로 읽음 처리
- 알림 화면에서 "모두 읽음" 버튼으로 일괄 처리 가능
- 읽지 않은 알림 개수는 실시간으로 업데이트

## 알림 삭제 정책

- 읽은 알림은 30일 후 자동 삭제 (선택적)
- 사용자가 수동으로 삭제 가능
- 관리자 알림은 90일 후 자동 삭제 (선택적)

## 구현 상태 업데이트

### ✅ 구현 완료
- 알림 모델 (`lib/models/notification.dart`)
- 알림 Provider (`lib/providers/notification_provider.dart`)
- 알림 화면 (`lib/screens/notification_screen.dart`)
- Firestore 알림 컬렉션 구조
- **Firebase Cloud Messaging (FCM) 푸시 알림 연동** ✅
  - FCM 토큰 관리 (`lib/services/fcm_service.dart`)
  - Cloud Functions에서 FCM 푸시 전송 (`functions/src/index.ts`)
  - 앱에서 FCM 메시지 수신 처리 (`lib/main.dart`, `lib/providers/auth_provider.dart`)

### ⚠️ 구현 필요
- 예약 생성/취소/변경 시 알림 전송 로직
- 스케줄러 기반 알림 (세션 시작 2시간 전 등)
- 스토리 등록 시 알림 전송 여부 선택 UI + 연동
- 관리자 알림 전송 로직

## FCM 푸시 알림 구현

### 동작 방식
1. 사용자 로그인 시 FCM 토큰을 Firestore에 저장
2. 알림이 Firestore에 생성되면 Cloud Functions 트리거가 자동으로 FCM 푸시 전송
3. 앱이 포그라운드/백그라운드/종료 상태에서 모두 푸시 알림 수신 가능

### FCM 토큰 관리
- 사용자 문서(`users/{userId}`)에 `fcmToken` 필드로 저장
- 토큰 갱신 시 자동 업데이트
- 로그아웃 시 토큰 삭제

### 알림 전송 흐름
```
알림 생성 (Firestore) 
  → onNotificationCreated 트리거 
  → 사용자 FCM 토큰 조회 
  → 알림 설정 확인 
  → FCM 푸시 전송
```

## 향후 개선 사항

1. **이메일 알림**: 중요 알림은 이메일로도 전송
2. **알림 그룹화**: 같은 타입의 알림을 그룹화하여 표시
3. **알림 필터링**: 사용자가 원하는 알림만 받기
4. **알림 템플릿**: 알림 메시지 템플릿 시스템
5. **포그라운드 알림 UI**: 앱이 열려있을 때도 알림 표시
