# 세 가지 문제 원인 분석

## 1. 알림 로드 실패: Firestore 인덱스 필요

### 원인
- `notifications` 컬렉션에서 다음 필드들로 복합 쿼리를 실행:
  - `userId` (where)
  - `isAdminNotification` (where)
  - `createdAt` (orderBy)
- Firestore는 복합 쿼리에 대해 인덱스가 필요함

### 해결 방법
1. **즉시 해결**: Firebase 콘솔에서 제공된 URL로 인덱스 생성
   ```
   https://console.firebase.google.com/v1/r/project/reservation-f1b95/firestore/indexes?create_composite=...
   ```
2. **대안**: 쿼리 로직 변경
   - `orderBy`를 제거하고 클라이언트에서 정렬
   - 또는 인덱스 없이 사용 가능한 쿼리로 변경

### 관련 코드
- `lib/services/firestore_service.dart:919-936` - `getUserNotifications`
- `lib/services/firestore_service.dart:940-961` - `watchUserNotifications`

---

## 2. FCM 토큰 저장 실패: APNS 토큰 미설정

### 원인
- iOS에서 FCM 토큰을 가져오려면 APNS(Apple Push Notification Service) 토큰이 먼저 설정되어야 함
- `getToken()` 호출 시 APNS 토큰이 없으면 오류 발생
- iOS 시뮬레이터에서는 APNS 토큰을 받을 수 없음 (실제 기기에서만 가능)

### 해결 방법
1. **iOS에서 APNS 토큰 먼저 요청**
   ```dart
   // iOS에서만 APNS 토큰 먼저 요청
   if (Platform.isIOS) {
     await _messaging.getAPNSToken();
   }
   // 그 다음 FCM 토큰 요청
   final fcmToken = await _messaging.getToken();
   ```

2. **에러 처리 개선**
   - APNS 토큰 오류는 조용히 처리 (iOS 시뮬레이터에서는 정상)
   - 실제 기기에서만 FCM 토큰 저장 시도

### 관련 코드
- `lib/services/fcm_service.dart:108-138` - `_saveTokenToFirestore`

---

## 3. SessionReservations 구독 오류: 권한 거부

### 원인
- `watchCourseSessionReservations`가 쿼리로 실행될 때 Firestore 보안 규칙에서 권한 체크 실패
- Firestore 규칙 135-147줄:
  ```javascript
  match /sessionReservations/{docId} {
    allow read: if signedIn() && (
      // 일반 사용자: 자신의 placeIds에 포함된 경우
      (hasUserDoc() && userDoc().data.placeIds != null && 
       resource.data.placeId != null && 
       resource.data.placeId in userDoc().data.placeIds)
      ||
      // 관리자: adminUsers 문서가 있고 placeIds에 포함된 경우
      (resource.data.placeId != null && isAdminForPlace(resource.data.placeId))
    );
  }
  ```
- **문제점**: 쿼리 컨텍스트에서 `resource.data.placeId`를 사용할 수 없음
- 쿼리 시에는 각 문서의 데이터에 접근할 수 없고, 쿼리 조건만 확인 가능

### 해결 방법
1. **쿼리 조건 기반 권한 체크로 변경**
   - 쿼리에 `placeId` 필터가 포함되어 있으면, 해당 `placeId`로 권한 체크
   - 쿼리 파라미터를 활용한 권한 검증

2. **Firestore 규칙 수정**
   ```javascript
   match /sessionReservations/{docId} {
     // 쿼리 시: placeId 쿼리 파라미터로 권한 체크
     // 단일 문서 읽기 시: resource.data.placeId로 권한 체크
     allow read: if signedIn() && (
       // 쿼리 컨텍스트: request.query.limit가 있으면 쿼리
       (request.query.limit != null && 
        request.query.where('placeId') != null &&
        isAdminForPlace(request.query.where('placeId').value))
       ||
       // 단일 문서 읽기: resource.data 사용
       (resource.data.placeId != null && isAdminForPlace(resource.data.placeId))
     );
   }
   ```
   **주의**: Firestore 규칙에서 쿼리 파라미터 직접 접근은 제한적

3. **권장 해결책**: 관리자 권한을 더 넓게 허용
   ```javascript
   match /sessionReservations/{docId} {
     allow read: if signedIn() && (
       // 일반 사용자: 자신의 placeIds에 포함된 경우
       (hasUserDoc() && userDoc().data.placeIds != null && 
        resource.data.placeId != null && 
        resource.data.placeId in userDoc().data.placeIds)
       ||
       // 관리자: 모든 sessionReservations 읽기 가능 (placeId 필터는 쿼리에서 처리)
       isAdmin()
     );
   }
   ```

### 관련 코드
- `lib/services/firestore_service.dart:622-642` - `watchCourseSessionReservations`
- `lib/screens/admin/widgets/calendar_screen.dart:161-223` - `_subscribeWeekSessionReservations`
- `firestore.rules:135-147` - `sessionReservations` 권한 규칙

---

## 요약

1. **알림 인덱스**: Firebase 콘솔에서 인덱스 생성 필요
2. **FCM APNS**: iOS에서 `getAPNSToken()` 먼저 호출 후 `getToken()` 호출
3. **SessionReservations 권한**: Firestore 규칙에서 관리자 권한을 더 넓게 허용하거나, 쿼리 기반 권한 체크 로직 개선

