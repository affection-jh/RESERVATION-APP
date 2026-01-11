# Cloud Functions 자동 동기화 함수 요구사항

## ✅ 이미 구현된 함수

### 1. 예약 관련 자동 동기화

#### `onReservationCreated`
- **트리거**: `reservations/{reservationId}` 문서 생성
- **기능**:
  - `sessionReservations` 컬렉션에서 해당 세션 찾기 또는 생성
  - `reservedCount` 1 증가
  - 예약 가능 여부 검증 (세션 시작 1시간 전까지)
  - 날짜별 수용인원 확인 (`dateCapacityOverrides` 확인)
- **상태**: ✅ 구현 완료

#### `onReservationDeleted`
- **트리거**: `reservations/{reservationId}` 문서 삭제
- **기능**:
  - `sessionReservations` 컬렉션에서 해당 세션 찾기
  - `reservedCount` 1 감소
  - 30일 이상 지난 빈 `sessionReservations` 자동 삭제
- **상태**: ✅ 구현 완료

### 2. 등록 관련 자동 동기화

#### `onEnrollmentCreated`
- **트리거**: `enrollments/{enrollmentId}` 문서 생성
- **기능**:
  - `courseMembers` 컬렉션에 새 문서 생성
  - `isActive: true`로 설정
- **상태**: ✅ 구현 완료

#### `onEnrollmentUpdated`
- **트리거**: `enrollments/{enrollmentId}` 문서 업데이트
- **기능**:
  - `courseMembers` 컬렉션의 `isActive` 상태 업데이트
  - 유효 기간 및 남은 예약 횟수 확인
- **상태**: ✅ 구현 완료

### 3. 데이터 일관성 검증

#### `validateDataConsistency`
- **트리거**: 매일 새벽 2시 (스케줄)
- **기능**:
  - `sessionReservations.reservedCount`와 실제 `reservations` 수 비교
  - 불일치 발견 시 자동 수정
  - 최근 7일간 업데이트된 데이터만 검증
- **상태**: ✅ 구현 완료

---

## ⚠️ 추가로 필요한 함수

### 1. 등록 삭제 시 동기화

#### `onEnrollmentDeleted` ✅ **완료**
- **트리거**: `enrollments/{enrollmentId}` 문서 삭제
- **기능**:
  - `courseMembers` 컬렉션에서 해당 `enrollmentId` 문서 삭제
  - 사용자의 해당 코스 등록 정보 정리
- **상태**: ✅ 구현 완료
- **우선순위**: 높음

### 2. 코스/세션 변경 시 동기화

#### `onCourseUpdated` ⚠️ **권장**
- **트리거**: `places/{placeId}` 문서 업데이트 (코스 변경 감지)
- **기능**:
  - 코스가 삭제되면 관련 `sessionReservations` 정리
  - 세션 정보 변경 시 관련 `sessionReservations` 업데이트
  - 세션 capacity 변경 시 미래 날짜의 `sessionReservations` 업데이트
- **상태**: ❌ 미구현
- **우선순위**: 중간

#### `onSessionCapacityChanged` ⚠️ **권장**
- **트리거**: 세션의 기본 capacity 변경
- **기능**:
  - 미래 날짜의 모든 `sessionReservations`의 `capacity` 업데이트
  - `dateCapacityOverrides`가 없는 경우만 업데이트
- **상태**: ❌ 미구현
- **우선순위**: 중간

### 3. 날짜별 수용인원 오버라이드 동기화

#### `onCapacityOverrideCreated` ⚠️ **권장**
- **트리거**: `dateCapacityOverrides/{overrideId}` 문서 생성
- **기능**:
  - 해당 날짜의 `sessionReservations`가 있으면 `capacity` 업데이트
  - `reservedCount`가 새 `capacity`를 초과하면 경고
- **상태**: ❌ 미구현
- **우선순위**: 낮음

#### `onCapacityOverrideDeleted` ⚠️ **권장**
- **트리거**: `dateCapacityOverrides/{overrideId}` 문서 삭제
- **기능**:
  - 해당 날짜의 `sessionReservations`의 `capacity`를 기본값으로 복원
- **상태**: ❌ 미구현
- **우선순위**: 낮음

### 4. 사용자/플레이스 멤버십 동기화

#### `onPlaceMembershipApproved` ⚠️ **권장**
- **트리거**: `placeMemberships/{membershipId}` 문서 업데이트 (status 변경)
- **기능**:
  - `status`가 `approved`로 변경되면 `users` 컬렉션의 `placeIds` 배열 업데이트
  - 사용자가 해당 플레이스에 접근 가능하도록 설정
- **상태**: ❌ 미구현
- **우선순위**: 중간

#### `onPlaceMembershipRejected` ⚠️ **권장**
- **트리거**: `placeMemberships/{membershipId}` 문서 업데이트 (status 변경)
- **기능**:
  - `status`가 `rejected`로 변경되면 관련 데이터 정리
  - `pendingMembers` 컬렉션 업데이트 (있는 경우)
- **상태**: ❌ 미구현
- **우선순위**: 낮음

### 5. 사용자 삭제 시 정리

#### `onUserDeleted` ⚠️ **선택**
- **트리거**: `users/{userId}` 문서 삭제
- **기능**:
  - 관련 `reservations` 정리 (선택적)
  - 관련 `enrollments` 정리 (선택적)
  - 관련 `courseMembers` 정리
  - 관련 `placeMemberships` 정리
- **상태**: ❌ 미구현
- **우선순위**: 낮음 (사용자 삭제는 드물게 발생)

### 6. 플레이스 삭제 시 정리

#### `onPlaceDeleted` ⚠️ **선택**
- **트리거**: `places/{placeId}` 문서 삭제
- **기능**:
  - 관련 `sessionReservations` 정리
  - 관련 `dateCapacityOverrides` 정리
  - 관련 `courseMembers` 정리
  - 관련 `placeMemberships` 정리
- **상태**: ❌ 미구현
- **우선순위**: 낮음 (플레이스 삭제는 드물게 발생)

---

## 📋 구현 우선순위

### Phase 1: 필수 함수 (즉시 구현)
1. ✅ `onReservationCreated` - 이미 구현됨
2. ✅ `onReservationDeleted` - 이미 구현됨
3. ✅ `onEnrollmentCreated` - 이미 구현됨
4. ✅ `onEnrollmentUpdated` - 이미 구현됨
5. ✅ `validateDataConsistency` - 이미 구현됨
6. ⚠️ **`onEnrollmentDeleted`** - **추가 필요**

### Phase 2: 권장 함수 (단기 구현)
7. ⚠️ **`onCourseUpdated`** - 코스 변경 시 동기화
8. ⚠️ **`onPlaceMembershipApproved`** - 멤버십 승인 시 동기화

### Phase 3: 선택 함수 (장기 구현)
9. ⚠️ `onSessionCapacityChanged` - 세션 capacity 변경 시
10. ⚠️ `onCapacityOverrideCreated/Deleted` - 수용인원 오버라이드 동기화
11. ⚠️ `onUserDeleted` - 사용자 삭제 시 정리
12. ⚠️ `onPlaceDeleted` - 플레이스 삭제 시 정리

---

## 🔧 구현 가이드

### 함수 추가 시 고려사항

1. **에러 처리**
   - 모든 함수에 try-catch 추가
   - 에러 발생 시 로깅 및 알림

2. **트랜잭션 사용**
   - 데이터 일관성이 중요한 경우 트랜잭션 사용
   - Firestore 트랜잭션 제한 (최대 500개 문서) 고려

3. **성능 최적화**
   - 배치 처리 사용
   - 불필요한 읽기 최소화

4. **로깅**
   - 모든 중요한 작업에 로깅 추가
   - 디버깅을 위한 상세 로그

5. **테스트**
   - 각 함수에 대한 단위 테스트 작성
   - 통합 테스트로 전체 플로우 검증

---

## 📊 현재 구현 상태 요약

- **구현 완료**: 6개 함수 (필수 함수 모두 완료)
- **추가 필요 (권장)**: 2개 함수
- **추가 필요 (선택)**: 5개 함수

**다음 단계**: Phase 2 권장 함수 구현 (`onCourseUpdated`, `onPlaceMembershipApproved`)

