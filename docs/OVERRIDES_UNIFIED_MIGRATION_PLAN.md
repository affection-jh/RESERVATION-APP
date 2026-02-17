# courseOverrides + dateCapacityOverrides 통합 계획

## 1. 현재 구조의 문제

| 컬렉션 | 역할 | 문제점 |
|--------|------|--------|
| **courseOverrides** | 세션 취소, 추가 세션 | |
| **dateCapacityOverrides** | 날짜별 정원 변경 | |

**둘 다 같은 축을 건드림**: "특정 날짜의 특정 세션에 대한 예외 처리"

- 예약 생성 시 **두 컬렉션을 각각 조회**해야 함
- 인덱스·쿼리·로직이 중복
- 개념은 하나인데 기능별로 컬렉션이 분리됨

---

## 2. 통합 후 구조

### 2.1 단일 컬렉션: `courseOverrides`

```ts
// courseOverrides (글로벌 컬렉션)
{
  id: string,           // document id
  placeId: string,
  courseId: string,
  date: string,         // "YYYY-MM-DD"
  sessionId: string,    // "courseId_dayOfWeek_startTime" — type=cancel|capacity 필수, add는 추가 세션용
  weekStartDate?: string,  // "YYYY-MM-DD" — add/cancel에서 주차 그룹핑용 (기존 유지)

  type: "cancel" | "capacity" | "add",

  // type=cancel
  isCancelled?: true,   // type=cancel일 때만 true

  // type=capacity
  capacity?: number,    // 오버라이드된 정원

  // type=add (비정기 추가 세션)
  dayOfWeek?: number,
  startTime?: string,
  endTime?: string,
  capacity?: number,    // 추가 세션의 정원

  createdAt: Timestamp,
  updatedAt?: Timestamp
}
```

### 2.2 타입별 필드 매핑

| type | sessionId | 기타 필수 | 선택 |
|------|-----------|-----------|------|
| **cancel** | O (정기 세션 식별) | weekStartDate | - |
| **capacity** | O (정기 세션 식별) | capacity | - |
| **add** | O (추가 세션용: `courseId_dayOfWeek_startTime`) | dayOfWeek, startTime, endTime, capacity, weekStartDate | - |

### 2.3 문서 ID 전략

- **cancel**: `{courseId}_{date}_{startTime}_cancel`
- **capacity**: `{sessionId}_{date}_cap` 또는 `{courseId}_{date}_{startTime}_cap`
- **add**: `{courseId}_{date}_{startTime}_add` (기존과 동일)

---

## 3. 조회 단순화

### 3.1 예약 생성 시 (Functions `createReservation`)

**현재**: courseOverrides 조회 → 없으면 dateCapacityOverrides 조회

**통합 후**: **한 번의 쿼리**

```ts
const overridesSnap = await db.collection('courseOverrides')
  .where('placeId', '==', placeId)
  .where('courseId', '==', courseId)
  .where('date', '==', reservedDateString)
  .get();

// 결과에서:
// - type=add && startTime/dayOfWeek 일치 → 비정기 세션, capacity 사용
// - type=cancel && sessionId 일치 → 세션 취소됨 (에러)
// - type=capacity && sessionId 일치 → capacity 오버라이드
```

### 3.2 getCapacityForDate

**현재**: dateCapacityOverrides에서 sessionId+date로 조회

**통합 후**: courseOverrides에서 sessionId+date+type=capacity로 조회

### 3.3 캘린더/세션 상세 (날짜별 capacity)

**현재**: watchDateCapacityOverrides (placeId, courseId, date 범위)

**통합 후**: watchCourseOverridesByDateRange + type=capacity 필터

---

## 4. 구현 순서 (마이그레이션 없음)

1. **CourseOverride 모델** — type, sessionId 추가
2. **DateCapacityOverride 모델 제거** — CourseOverride로 통합
3. **FirestoreService** — get/set/delete capacity를 courseOverrides 기반으로 변경
4. **Functions** — getCapacityForDate, createReservation 등 courseOverrides만 사용
5. **인덱스** — placeId + courseId + date (dateCapacityOverrides 인덱스 제거)

---

## 5. 수정 대상 파일

### Flutter

- `lib/models/course_override.dart` — type, sessionId 추가, factory 정리
- `lib/models/date_capacity_override.dart` — 제거 또는 CourseOverride로 통합
- `lib/services/firestore_service.dart` — get/set/delete capacity → courseOverrides 기반으로 변경
- `lib/providers/course_provider.dart` — override 처리
- `lib/screens/admin/widgets/calendar_screen.dart` — capacity override 구독
- `lib/screens/admin/widgets/session_detail_screen.dart` — capacity override
- `lib/widgets/compact_calendar_widget.dart` — capacity override

### Functions

- `functions/src/index.ts` — getCapacityForDate, createReservation, batchCancel 등
- `functions/src/course_override.ts` — upsertCourseOverride (type, sessionId 반영)
- place/코스 삭제 시 dateCapacityOverrides 삭제 로직 제거

### Config

- `firestore.rules` — dateCapacityOverrides 규칙 제거
- `firestore.indexes.json` — dateCapacityOverrides 인덱스 제거, courseOverrides 인덱스 추가

---

## 6. 예상 효과

- 마이그레이션 없이 **새 구조만** 적용
- 예약 생성 시 override 조회 **1회**로 축소
- 한 날짜에 대한 cancel/capacity/add를 **한 번에** 조회
- 인덱스·규칙 단순화
- 데이터 일관성 향상
