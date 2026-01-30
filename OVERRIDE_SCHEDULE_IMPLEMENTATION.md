# 비정기 일정 시스템 구현 완료

## 개요
관리자가 특정 주에만 적용되는 비정기 일정을 관리할 수 있는 시스템을 구현했습니다.

## 주요 기능

### 1. Functions 기반 서버 처리 (`functions/src/course_override.ts`)
- **`upsertCourseOverride`**: 비정기 일정 생성/수정/삭제
  - 추가: 정기 일정에 없는 새로운 세션 추가
  - 취소: 정기 일정을 해당 주에만 취소 (예약자 자동 처리)
  
- **자동 예약 처리**:
  - 취소 시: 예약 삭제, 크레딧 복구, sessionReservations 업데이트
  - 예약자에게 자동 알림 전송
  
- **알림 설정** (관리자 제어):
  - 추가 시: `notifyOnOverrideAdd` 플레이스 설정 확인 후 알림
  - 해당 코스에 등록된 멤버에게만 선택적 알림

### 2. 선택된 코스 및 주차만 관리 (`WeeklyOverrideScheduleScreen`)
- `selectedCourseId` 파라미터로 특정 코스만 필터링
- 해당 주차(`weekStartDate`)의 일정만 로드 및 수정
- admin_home_screen에서 선택된 코스 전달

### 3. 정기 일정 탭으로 취소 가능
- DragCalendarEditor에서 정기 일정(회색 배경)을 탭하면 취소/복원 토글
- `_cancelledSessions` 맵으로 취소 상태 관리
- 저장 시 Functions로 전달하여 서버에서 예약자 처리

### 4. CompactCalendarWidget 길게 누르기 취소
- 관리자 홈 모드(`CompactCalendarUsage.adminNavigate`)에서 활성화
- `onLongPress` 제스처로 세션 취소 다이얼로그 표시
- Functions 호출하여 즉시 처리

### 5. 실시간 구독 (`CourseProvider`)
- `streamCourseOverrides`: Firestore 변경사항 실시간 구독
- `subscribeToOverrides`: 최대 3주치 동시 구독
- `_overridesByWeek` 맵으로 주별 데이터 관리
- 변경 시 자동 `notifyListeners()` 호출

## 데이터 구조

### CourseOverride 모델
```dart
{
  id: String,                  // "${courseId}_${date}_${startTime}_${add|cancel}"
  courseId: String,
  placeId: String,
  date: String,                // "YYYY-MM-DD"
  dayOfWeek: int,             // 1-7
  startTime: String?,         // null이면 취소
  endTime: String?,
  capacity: int?,
  isCancelled: bool,          // true면 정기 일정 취소
  weekStartDate: String,      // 월요일 "YYYY-MM-DD"
  createdAt: Timestamp,
  updatedAt: Timestamp?,
}
```

## Firestore Security Rules

```javascript
match /courseOverrides/{overrideId} {
  allow read: if isAdmin();
  allow create, update, delete: if isAdmin();
}
```

## 사용 흐름

### 관리자 비정기 일정 추가/취소
1. admin_home_screen에서 주차 선택 후 `+` 버튼
2. WeeklyOverrideScheduleScreen 열림 (선택된 코스만)
3. 드래그하여 새 세션 추가 OR 정기 일정 탭하여 취소
4. "저장" 버튼 클릭
5. Functions로 처리:
   - 기존 override 삭제
   - 새 세션 추가 → 코스 등록자에게 알림
   - 정기 세션 취소 → 예약자 크레딧 복구 + 알림

### 관리자 길게 누르기 취소
1. CompactCalendarWidget(관리자 홈 모드)에서 세션 길게 누르기
2. 취소 확인 다이얼로그
3. Functions 호출 → 즉시 처리

### 일반 사용자 실시간 반영
1. CourseProvider가 streamCourseOverrides 구독
2. 비정기 일정 변경 감지
3. notifyListeners() → UI 자동 업데이트
4. CompactCalendarWidget 등에서 자동 반영

## 배포 방법

### 1. Functions 배포
```bash
cd functions
npm run build
firebase deploy --only functions:upsertCourseOverride
```

### 2. Security Rules 배포
```bash
firebase deploy --only firestore:rules
```

### 3. Flutter 앱 빌드
```bash
flutter build ios
# 또는
flutter build apk
```

## 테스트 시나리오

### TC1: 비정기 세션 추가
1. 관리자 홈에서 특정 주 선택
2. `+` 버튼 → 비정기 일정 화면
3. 빈 시간대에 드래그하여 세션 생성
4. 저장 → 등록 멤버에게 알림 전송 확인

### TC2: 정기 세션 취소 (예약자 있음)
1. 예약이 있는 정기 세션 탭하여 취소
2. 저장 → 예약자 크레딧 복구 및 알림 확인
3. sessionReservations.isCancelled = true 확인

### TC3: 길게 누르기 취소
1. 관리자 홈 캘린더에서 세션 길게 누르기
2. 취소 확인 → 즉시 처리
3. 예약자에게 알림 전송 확인

### TC4: 실시간 반영
1. 사용자 A: 홈 화면에서 주차 보기
2. 관리자 B: 해당 주에 비정기 세션 추가
3. 사용자 A: 새로고침 없이 자동으로 세션 표시 확인

## 주의 사항

1. **알림 설정**: `places` 문서에 `notifyOnOverrideAdd: boolean` 필드 추가 필요
2. **구독 최적화**: 최대 3주치만 구독하여 성능 유지
3. **트랜잭션**: 예약 취소는 트랜잭션으로 처리되어 데이터 일관성 보장
4. **코스 선택**: `WeeklyOverrideScheduleScreen`은 항상 `selectedCourseId` 전달 필요

## 향후 개선 사항

1. 일괄 등록 미리보기 기능
2. 여러 코스 동시 관리
3. 비정기 일정 템플릿 기능
4. 알림 발송 이력 확인

## 관련 파일

### Functions
- `functions/src/course_override.ts`
- `functions/src/index.ts`

### Flutter
- `lib/models/course_override.dart`
- `lib/services/firestore_service.dart` (upsertCourseOverride, streamCourseOverrides)
- `lib/providers/course_provider.dart` (subscribeToOverrides)
- `lib/screens/admin/widgets/weekly_override_schedule_screen.dart`
- `lib/screens/admin/admin_home_screen.dart`
- `lib/widgets/compact_calendar_widget.dart`

### Security
- `firestore.rules` (courseOverrides 규칙)

