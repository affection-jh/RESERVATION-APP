# 데이터 정합성 분석 리포트

## 📊 전체 플로우 분석

### 1. 멤버 등록 플로우 (registerMember)

**위치**: `lib/services/member_service.dart:registerMember()`

**동작**:
1. PendingMember 생성/업데이트 (`pendingMembers/{placeId}_{phoneNumber}`)
   - `courseIds`: 코스 ID 목록
   - `courseEnrollments`: 코스별 상세 등록 정보 (totalReservations, validFrom, validUntil)
2. 기존 User가 있으면 enrollments 컬렉션에 직접 생성
   - 중복 체크: `existingEnrollmentIds`로 이미 존재하는 enrollment 확인
   - 중복이면 스킵

**문제점**: 
- ✅ 중복 체크 있음
- ⚠️ 하지만 타이밍 이슈로 중복 생성 가능성 있음 (트랜잭션 외부에서 조회)

---

### 2. 사용자 로그인 플로우 (onPlaceMembershipCreated)

**위치**: `functions/src/index.ts:onPlaceMembershipCreated()`

**동작**:
1. `placeMemberships` 생성 시 트리거
2. `pendingMembers`에서 `courseIds` 읽기
3. 기존 enrollments 확인 (중복 방지)
4. enrollments 생성
5. `pendingMembers` 삭제

**문제점**:
- ✅ 중복 체크 있음 (`existingCourseIds`)
- ⚠️ `auth_service`에서 이미 `pendingMembers`를 삭제하면 Cloud Function에서 찾을 수 없음

---

### 3. auth_service에서 pendingMembers 삭제

**위치**: `lib/services/auth_service.dart:createPlaceMembershipsFromPendingMembers()`

**동작**:
- `placeMemberships` 생성 시 `pendingMembers` 삭제
- 주석: "Cloud Function에서 enrollments 생성 후 삭제하지만, 여기서도 삭제하여 중복 방지"

**문제점**:
- ❌ **중복 삭제**: `auth_service`에서 먼저 삭제하면 Cloud Function에서 `pendingMembers`를 찾을 수 없음
- ❌ **enrollments 생성 실패 가능**: Cloud Function이 `pendingMembers`를 찾지 못하면 enrollments 생성 실패

---

### 4. 코스 삭제 플로우 (deleteCourse)

**위치**: `lib/services/firestore_service.dart:deleteCourse()`

**동작**:
1. `places/{placeId}/courses` 배열에서 코스 제거
2. `enrollments` 컬렉션에서 해당 `courseId`의 모든 문서 삭제 (페이지네이션)
3. `pendingMembers`에서 해당 `courseId` 제거
   - `courseIds` 배열에서 제거
   - `courseEnrollments` 배열에서 제거
   - `courseIds`가 비어있으면 `pendingMembers` 삭제

**정합성**: ✅ 정상

---

## 🔴 발견된 문제점

### 문제 1: pendingMembers 삭제 중복 및 타이밍 이슈

**현재 상황**:
- `auth_service`에서 `placeMemberships` 생성 시 `pendingMembers` 삭제
- Cloud Function에서 `enrollments` 생성 후 `pendingMembers` 삭제

**문제**:
- `auth_service`에서 먼저 삭제하면 Cloud Function에서 `pendingMembers`를 찾을 수 없음
- 결과: enrollments 생성 실패

**해결 방안**:
- `auth_service`에서 `pendingMembers` 삭제 제거
- Cloud Function에서만 `pendingMembers` 삭제 (enrollments 생성 완료 후)

---

### 문제 2: enrollments 중복 생성 가능성

**현재 상황**:
- `registerMember`: 기존 User가 있으면 enrollments 생성 (중복 체크 있음)
- `onPlaceMembershipCreated`: enrollments 생성 (중복 체크 있음)

**문제**:
- 둘 다 중복 체크를 하지만, 트랜잭션 외부에서 조회하므로 타이밍 이슈로 중복 생성 가능

**해결 방안**:
- `registerMember`에서 기존 User가 있어도 enrollments 생성하지 않기
- `onPlaceMembershipCreated`에서만 enrollments 생성 (일관성 유지)

---

### 문제 3: User 모델의 enrollments 필드 불필요

**현재 상황**:
- `users` 컬렉션에 `enrollments` 배열이 embedded로 저장됨
- 하지만 실제로는 `enrollments` 컬렉션에서 별도로 조회

**문제**:
- 데이터 중복
- 일관성 문제 (users 컬렉션의 enrollments는 업데이트되지 않을 수 있음)

**해결 방안**:
- `users` 컬렉션에 `enrollments` 저장하지 않기
- `User` 모델의 `enrollments` 필드는 메모리상에서만 사용 (로드 시 `enrollments` 컬렉션에서 조회)

---

## ✅ 정상 동작하는 부분

1. **코스 삭제**: enrollments와 pendingMembers에서 모두 제거됨
2. **중복 체크**: registerMember와 onPlaceMembershipCreated 모두 중복 체크 있음
3. **pendingMembers 업데이트**: 코스 추가/제거 시 정상 업데이트

---

## 📝 권장 수정 사항

### 1. auth_service에서 pendingMembers 삭제 제거

```dart
// lib/services/auth_service.dart
// 주석 처리 또는 제거
// transaction.delete(doc.reference); // ❌ 제거
```

### 2. registerMember에서 enrollments 생성 제거

```dart
// lib/services/member_service.dart
// 기존 User가 있어도 enrollments 생성하지 않기
// onPlaceMembershipCreated에서만 생성하도록 통일
```

### 3. User 모델의 enrollments 필드 처리

- `toJson()`에서 `enrollments` 제외
- `fromJson()`에서 `enrollments` 빈 배열로 설정
- 실제 데이터는 `enrollments` 컬렉션에서만 조회

---

## 🎯 최종 권장사항

1. **enrollments 생성**: `onPlaceMembershipCreated` Cloud Function에서만 수행
2. **pendingMembers 삭제**: Cloud Function에서만 수행 (enrollments 생성 완료 후)
3. **User 모델**: `enrollments` 필드는 메모리상에서만 사용, Firestore에는 저장하지 않음



