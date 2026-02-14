# FCM / 알림 디버깅 흐름 및 로그 위치

## 전체 흐름

1. **백엔드**: 어떤 액션(예약 생성, 세션 취소 등) → `createNotification()` → Firestore `notifications` 문서 생성
2. **백엔드**: Firestore 트리거 `onNotificationCreated` → `sendPushNotification()` → FCM으로 푸시 전송
3. **앱**: FCM 수신 (포그라운드: `onMessage`, 백그라운드: `firebaseMessagingBackgroundHandler`) → `_addNotificationToProvider(notificationId)` → `NotificationProvider.addNotificationFromId()` → 목록 갱신

알림 목록 **실시간** 반영은 FCM 수신 시에만 이루어짐. Firestore `notifications` 컬렉션 실시간 구독(`watchUserNotifications`)은 현재 미사용.

---

## 로그 검색 키워드 (Flutter – 터미널/디버그 콘솔)

| 단계 | 검색 키워드 | 의미 |
|------|-------------|------|
| FCM 초기화 | `[AuthProvider] _initializeFcm` | 로그인 후 FCM 초기화 시도 |
| FCM 초기화 | `[FcmService] initialize` | 권한/토큰/핸들러 설정 |
| 토큰 저장 | `[FcmService] _saveTokenToFirestore` | Firestore에 fcmToken 저장 성공/실패 |
| 토큰 없음 | `FCM 토큰을 가져올 수 없습니다` | getToken() null → 푸시 불가 원인 후보 |
| 포그라운드 수신 | `[FCM Foreground] messageId=` | 앱 사용 중 푸시 수신 (이 로그가 있으면 수신된 것) |
| 플랫폼/APNS | `[FcmService] platform=` | iOS/Android 구분 |
| 플랫폼/APNS | `[FcmService] APNS 토큰:` | iOS에서 APNS 토큰 있음/없음 (수신 가능 여부 참고) |
| Provider 반영 | `[FcmService] _addNotificationToProvider` | notificationId, context 유무 |
| Provider 반영 | `[NotificationProvider] addNotificationFromId` | Firestore 조회/검증/추가 여부 |
| 알림 로드 | `[NotificationProvider] loadNotifications` | 앱/알림 화면 진입 시 일회성 로드 |

---

## 로그 검색 키워드 (Functions – Firebase Console > Functions > 로그)

| 단계 | 검색 키워드 | 의미 |
|------|-------------|------|
| 알림 문서 생성 | `[createNotification] Firestore 알림 문서 생성됨` | notificationId, userId, type |
| 트리거 실행 | `[onNotificationCreated] 트리거 실행` | Firestore 쓰기 직후 FCM 전송 시도 |
| FCM 전송 시도 | `[sendPushNotification] called` | userId, title |
| 토큰 없음 | `No FCM token for user` | users/{userId}.fcmToken 없음 → 푸시 불가 |
| FCM 성공 | `[sendPushNotification] FCM 전송 성공` | messageId 확인 |
| FCM 실패 | `[sendPushNotification] FCM 전송 실패` | error 메시지/코드 확인 |

---

## 발송 vs 수신 구분

- **발송 여부**: Firebase Console > Functions 로그에서 `[sendPushNotification] FCM 전송 성공` 이 나오면 **서버는 해당 기기로 푸시를 보낸 것**이다. 실패면 `FCM 전송 실패` + 에러 코드 확인.
- **수신 여부**: 앱 포그라운드일 때 Flutter 로그에 `[FCM Foreground] messageId=...` 가 찍히면 **앱이 메시지를 받은 것**이다. 발송은 성공인데 이 로그가 없으면 **수신 측(앱/APNS)** 문제.

## iOS 포그라운드 수신이 안 될 때 (APNS 점검)

- **Info.plist** 에 `FirebaseAppDelegateProxyEnabled` = false 이면, **AppDelegate에서 APNS 디바이스 토큰을 FCM에 수동 전달**해야 한다. `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` 에서 `Messaging.messaging().apnsToken = deviceToken` 설정 여부 확인.
- **Firebase Console** > 프로젝트 설정 > Cloud Messaging > **APNs 인증 키** (.p8) 업로드 여부. 없으면 iOS 푸시 자체가 실패할 수 있음.
- **실기기**에서 테스트할 것. iOS 시뮬레이터는 APNS 미지원.
- 앱 로그에서 `[FcmService] platform=iOS` / `APNS 토큰: 있음` 인지 확인. `APNS 토큰: 없음` 이면 시뮬레이터이거나 Firebase에 APNs 키가 없거나, AppDelegate에서 토큰 전달이 안 된 상태.

## 자주 나오는 원인

- **FCM이 안 옴**
  - Flutter: `FCM 토큰을 가져올 수 없습니다` → 권한/APNS( iOS )/실기기 여부 확인
  - Functions: `No FCM token for user` → 해당 사용자 로그인 후 앱에서 토큰이 한 번이라도 저장됐는지 확인 (users 문서에 fcmToken 존재 여부)
  - Functions: `FCM 전송 실패` → 에러 메시지/코드로 FCM 설정(키, 앱 번들 등) 점검

- **실시간으로 접수 안 됨**
  - 앱이 **포그라운드**일 때: `onMessage` 수신 후 `_addNotificationToProvider` → `addNotificationFromId` 로그가 나오는지 확인. context null이면 Provider 갱신 스킵됨.
  - **백그라운드**일 때: `firebaseMessagingBackgroundHandler`만 실행되고, 앱이 깨어난 뒤에는 **새 알림 목록을 자동으로 다시 안 가져옴**. 알림 탭 진입 시 `loadNotifications()`로 다시 조회됨.
  - Firestore `notifications` 실시간 구독을 쓰지 않으므로, FCM이 오지 않으면 “실시간 접수”는 불가능함.

---

## 실시간 접수 개선 제안

- `NotificationProvider`에서 `loadNotifications()` 대신(또는 병행) `FirestoreService.watchUserNotifications()`를 구독하면, Firestore에 알림 문서가 생길 때마다 앱 목록이 자동 갱신됨. (FCM과 무관하게 “실시간” 반영 가능)
