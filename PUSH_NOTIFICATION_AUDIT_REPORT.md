# 푸시 알림 시스템 전체 점검 보고서

## 📋 개요

푸시 알림 시스템의 현재 구현 상태를 점검하고, 미구현된 부분을 파악하여 보고합니다.

---

## ✅ 구현 완료된 부분

### 1. FCM 인프라 및 기본 기능

#### 1.1 FCM 서비스 (`lib/services/fcm_service.dart`)
- ✅ FCM 토큰 관리 (저장, 갱신, 삭제)
- ✅ 포그라운드 메시지 핸들러 설정
- ✅ 백그라운드 메시지 핸들러 설정
- ✅ 알림 클릭 처리
- ✅ 포그라운드 알림 UI 표시 (`PushNotificationOverlay`)

#### 1.2 Cloud Functions FCM 전송 (`functions/src/index.ts`)
- ✅ `sendPushNotification` 헬퍼 함수 구현 (1848-1917줄)
  - 사용자 FCM 토큰 조회
  - 알림 설정 확인 (`notificationsEnabled`)
  - FCM 메시지 구성 (Android/iOS 설정 포함)
  - 에러 처리

- ✅ `onNotificationCreated` 트리거 구현 (1922-1942줄)
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

## ❌ 미구현된 부분

### 1. 예약 관련 알림 전송

#### 1.1 예약 생성 성공 알림
**위치**: `functions/src/index.ts` - `createReservation` 함수 (1299-1507줄)

**현재 상태**: 
- 예약 생성 로직은 완료됨
- **알림 생성 로직 없음**

**필요한 구현**:
```typescript
// createReservation 함수의 return 직전에 추가
await admin.firestore().collection('notifications').add({
    userId: userId,
    type: 'reservation',
    title: '예약이 완료되었습니다',
    body: `${course.name} - ${reservedDateString} ${startTime}`,
    data: {
        reservationId: reservationRef.id,
        courseId: courseId,
        placeId: placeId,
    },
    isRead: false,
    isAdminNotification: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
});
```

**정책**: `NOTIFICATION_POLICY.md` 11-18줄 참조

---

#### 1.2 예약 취소 완료 알림
**위치**: `functions/src/index.ts` - `cancelReservation` 함수 (1509-1599줄)

**현재 상태**:
- 예약 취소 로직은 완료됨
- **알림 생성 로직 없음**

**필요한 구현**:
```typescript
// cancelReservation 함수의 return 직전에 추가
// 코스 정보 조회 필요
const placeDoc = await admin.firestore().collection('places').doc(placeId).get();
const place = placeDoc.data();
const course = findCourse(place, courseId);

await admin.firestore().collection('notifications').add({
    userId: userId,
    type: 'reservation',
    title: '예약이 취소되었습니다',
    body: `${course.name} - ${reservedDateString} ${startTime}`,
    data: {
        reservationId: reservationId,
        courseId: courseId,
        placeId: placeId,
    },
    isRead: false,
    isAdminNotification: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
});
```

**정책**: `NOTIFICATION_POLICY.md` 20-27줄 참조

---

#### 1.3 예약 변경 알림 (관리자)
**위치**: `functions/src/index.ts` - `moveReservationWithinCourse` 함수 (1612-1839줄)

**현재 상태**:
- 예약 이동 로직은 완료됨
- **알림 생성 로직 부분 구현됨 (1823-1838줄)**
- 하지만 코스 정보 조회 및 메시지 포맷이 불완전함

**현재 코드** (1823-1838줄):
```typescript
try {
    await admin.firestore().collection('notifications').add({
        userId: result.userId,
        type: 'reservation',
        title: '예약이 변경되었습니다',
        body: `예약이 변경되었습니다: ${oldReservedDateString} ${oldStartTime} → ${newReservedDateString} ${newStartTime}`,
        data: {
            reservationId: reservationId,
            courseId: courseId,
            placeId: placeId,
        },
        isRead: false,
        isAdminNotification: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(`[moveReservationWithinCourse] Created notification for user ${result.userId}, reservation ${reservationId}`);
} catch (error) {
    console.error(`[moveReservationWithinCourse] Error creating notification:`, error);
}
```

**개선 필요**:
- 코스명을 포함한 메시지로 변경
- 정책에 맞는 메시지 포맷 적용

**정책**: `NOTIFICATION_POLICY.md` 29-36줄 참조

---

#### 1.4 세션 취소 알림 (관리자)
**위치**: 미구현

**필요한 구현**:
- 관리자가 세션을 취소하는 Cloud Function 필요
- 해당 세션에 예약한 모든 사용자에게 알림 전송
- 배치 알림 전송 로직 필요

**정책**: `NOTIFICATION_POLICY.md` 38-45줄 참조

---

#### 1.5 방문일 알림 (세션 시작 2시간 전)
**위치**: 미구현

**필요한 구현**:
- Cloud Functions 스케줄러 함수 생성
- 매 5분마다 실행 (또는 적절한 주기)
- 2시간 후 시작하는 세션의 예약 조회
- 해당 사용자들에게 알림 전송

**예시 코드**:
```typescript
export const sendUpcomingSessionNotifications = functions.pubsub
    .schedule('every 5 minutes')
    .timeZone('Asia/Seoul')
    .onRun(async () => {
        const now = getSeoulDateTime();
        const inTwoHours = new Date(now.getTime() + 2 * 60 * 60 * 1000);
        const targetDateString = formatDate(inTwoHours); // "YYYY-MM-DD"
        const targetHHmm = formatHHmm(inTwoHours); // "HH:mm"
        
        // 2시간 후 세션이 있는 예약 조회
        const reservations = await admin.firestore()
            .collection('places')
            .doc(placeId)
            .collection('reservations')
            .where('reservedDateString', '==', targetDateString)
            .where('startTime', '==', targetHHmm)
            .get();
        
        for (const doc of reservations.docs) {
            const reservation = doc.data();
            // 알림 생성 (onNotificationCreated 트리거가 자동으로 FCM 전송)
            await admin.firestore().collection('notifications').add({
                userId: reservation.userId,
                type: 'reservation',
                title: '곧 세션이 시작됩니다',
                body: `${course.name} - ${targetDateString} ${targetHHmm} (2시간 전)`,
                data: {
                    reservationId: doc.id,
                    courseId: reservation.courseId,
                    placeId: reservation.placeId,
                },
                isRead: false,
                isAdminNotification: false,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }
    });
```

**정책**: `NOTIFICATION_POLICY.md` 47-54줄 참조

---

### 2. 등록 관련 알림

#### 2.1 등록 승인 알림
**위치**: 미구현

**필요한 구현**:
- 관리자가 플레이스 가입 요청을 승인하는 로직에서 알림 생성
- `lib/services/admin_service.dart` 또는 Cloud Function에서 처리

**정책**: `NOTIFICATION_POLICY.md` 58-65줄 참조

---

#### 2.2 등록 거절 알림
**위치**: 미구현

**필요한 구현**:
- 관리자가 플레이스 가입 요청을 거절하는 로직에서 알림 생성

**정책**: `NOTIFICATION_POLICY.md` 67-74줄 참조

---

#### 2.3 등록 기간 만료 임박 알림
**위치**: 미구현

**필요한 구현**:
- Cloud Functions 스케줄러 함수 생성
- 매일 실행하여 7일 이내 만료되는 등록 조회
- 해당 사용자들에게 알림 전송

**정책**: `NOTIFICATION_POLICY.md` 76-83줄 참조

---

### 3. 콘텐츠 알림

#### 3.1 스토리 등록 알림 (선택)
**위치**: `lib/screens/admin/widgets/story_add_screen.dart` - `_handleSave` 함수

**현재 상태**:
- ✅ 알림 전송 여부 선택 UI 구현됨 (`_shouldSendNotification` 플래그)
- ✅ 스토리 저장 로직 구현됨
- ❌ **알림 전송 로직 없음**

**필요한 구현**:
```dart
// _handleSave 함수에서 스토리 저장 후
if (_shouldSendNotification) {
    // 해당 플레이스의 모든 멤버 조회
    final members = await _firestoreService.getPlaceMembers(placeId);
    
    // 각 멤버에게 알림 생성
    for (final member in members) {
        await _firestoreService.createNotification(
            AppNotification(
                id: _generateNotificationId(),
                userId: member.userId,
                placeId: placeId,
                type: NotificationType.story,
                title: '새 소식이 있습니다',
                body: title,
                createdAt: DateTime.now(),
                data: {
                    'storyId': story.id,
                    'placeId': placeId,
                },
            ),
        );
    }
}
```

**주의사항**:
- `getPlaceMembers` 메서드가 필요 (플레이스 멤버 조회)
- 배치 알림 생성 시 성능 고려 필요

**정책**: `NOTIFICATION_POLICY.md` 87-94줄 참조

---

### 4. 관리자 알림

#### 4.1 가입 요청 알림
**위치**: `lib/services/auth_service.dart` - `requestPlaceMembership` 함수 (1269-1301줄)

**현재 상태**:
- 가입 요청 생성 로직 완료
- **TODO 주석만 있음 (1298줄): `// TODO: 관리자에게 알림 (Cloud Functions)`**

**필요한 구현**:
```dart
// requestPlaceMembership 함수에서 가입 요청 생성 후
// 해당 플레이스의 모든 관리자 조회
final admins = await _firestoreService.getPlaceAdmins(placeId);

// 사용자 정보 조회
final user = await getUser(userId);

// 각 관리자에게 알림 생성
for (final admin in admins) {
    await _firestoreService.createNotification(
        AppNotification(
            id: _generateNotificationId(),
            userId: admin.userId,
            placeId: placeId,
            type: NotificationType.system,
            title: '새 가입 요청',
            body: '${user.name}님이 가입을 요청했습니다',
            createdAt: DateTime.now(),
            isAdminNotification: true,
            data: {
                'membershipId': membership.id,
                'userId': userId,
                'placeId': placeId,
            },
        ),
    );
}
```

**정책**: `NOTIFICATION_POLICY.md` 98-105줄 참조

---

#### 4.2 등록 연장 요청 알림
**위치**: 미구현

**필요한 구현**:
- 사용자가 등록 연장을 요청하는 로직 필요
- 해당 플레이스의 모든 관리자에게 알림 전송

**정책**: `NOTIFICATION_POLICY.md` 107-114줄 참조

---

#### 4.3 데이터 불일치 경고
**위치**: `functions/src/index.ts` - `validateDataConsistency` 함수 (831줄)

**현재 상태**:
- 데이터 검증 로직은 있음
- **알림 전송 로직 없음**

**필요한 구현**:
- 데이터 불일치 발견 시 해당 플레이스의 모든 관리자에게 알림 전송

**정책**: `NOTIFICATION_POLICY.md` 116-123줄 참조

---

## 🔧 추가로 필요한 유틸리티 함수

### 1. 플레이스 멤버 조회
**위치**: `lib/services/firestore_service.dart`

**필요한 메서드**:
```dart
/// 플레이스의 모든 멤버 조회
Future<List<String>> getPlaceMemberIds(String placeId) async {
    // placeMemberships에서 approved 상태인 멤버 조회
    // 또는 users 컬렉션에서 placeIds에 해당 placeId가 포함된 사용자 조회
}
```

---

### 2. 플레이스 관리자 조회
**위치**: `lib/services/firestore_service.dart`

**필요한 메서드**:
```dart
/// 플레이스의 모든 관리자 조회
Future<List<String>> getPlaceAdminIds(String placeId) async {
    // adminUsers 컬렉션에서 해당 placeId의 관리자 조회
}
```

---

### 3. 알림 ID 생성
**위치**: `lib/services/firestore_service.dart` 또는 유틸리티

**필요한 메서드**:
```dart
String _generateNotificationId() {
    return 'notification_${DateTime.now().millisecondsSinceEpoch}';
}
```

---

## 📊 구현 우선순위

### 높음 (즉시 구현 필요)
1. ✅ 예약 생성 성공 알림
2. ✅ 예약 취소 완료 알림
3. ✅ 예약 변경 알림 개선 (코스명 포함)
4. ✅ 가입 요청 알림 (관리자)
5. ✅ 등록 승인/거절 알림

### 중간 (단기 구현)
6. ✅ 스토리 등록 알림 (선택)
7. ✅ 세션 취소 알림 (관리자)
8. ✅ 등록 연장 요청 알림

### 낮음 (장기 구현)
9. ✅ 방문일 알림 (2시간 전) - 스케줄러 필요
10. ✅ 등록 기간 만료 임박 알림 - 스케줄러 필요
11. ✅ 데이터 불일치 경고 알림

---

## 🐛 발견된 문제점

### 1. 알림 생성 권한
**위치**: `firestore.rules` (227-233줄)

**현재 규칙**:
```
match /notifications/{notificationId} {
    allow read: if signedIn() && resource.data.userId == request.auth.uid;
    allow create, delete: if isAdmin();
    allow update: if signedIn() && resource.data.userId == request.auth.uid;
}
```

**문제**:
- 클라이언트에서 알림을 생성할 수 없음 (관리자만 가능)
- Cloud Functions에서만 알림 생성 가능

**해결 방안**:
- Cloud Functions에서 알림 생성하도록 통일
- 또는 클라이언트에서도 알림 생성 가능하도록 규칙 수정 (보안 고려 필요)

---

### 2. 배치 알림 전송 성능
**문제**:
- 스토리 등록 시 모든 멤버에게 알림을 보낼 때 성능 이슈 가능
- Firestore 쓰기 제한 고려 필요

**해결 방안**:
- Cloud Functions에서 배치 처리
- 또는 Firestore 배치 쓰기 사용 (최대 500개)

---

### 3. 중복 알림 방지
**문제**:
- 방문일 알림 (2시간 전)이 여러 번 전송될 수 있음
- 스케줄러가 5분마다 실행되면 중복 전송 가능

**해결 방안**:
- 알림에 `sentAt` 필드 추가
- 또는 예약에 `reminderSent` 플래그 추가

---

## 📝 요약

### 구현 완료율
- **인프라**: 100% ✅
- **예약 알림**: 20% (예약 변경만 부분 구현)
- **등록 알림**: 0%
- **콘텐츠 알림**: 0% (UI만 구현)
- **관리자 알림**: 0%

### 전체 진행률: 약 30%

### 다음 단계
1. 예약 생성/취소 알림 구현 (Cloud Functions)
2. 가입 요청/승인/거절 알림 구현
3. 스토리 등록 알림 구현
4. 스케줄러 기반 알림 구현 (방문일, 만료 임박)

