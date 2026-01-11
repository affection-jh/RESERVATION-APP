# 전체 플로우 점검 보고서

## 📋 접속 시 플로우

### 1. AppStartupScreen
- ✅ **자동 로그인 확인**
  - `requireManualEntrySelection` 플래그 확인 → true면 PlaceWaitingScreen으로 고정
  - 관리자 자동 로그인 확인 (우선순위)
  - 일반 사용자 자동 로그인 확인
  - 실패 시 전화번호 입력 화면

- ✅ **플레이스 설정**
  - 마지막 접속 플레이스 우선 사용
  - PlaceProvider에 플레이스 설정
  - AuthService에 마지막 접속 플레이스 저장

### 2. PlaceWaitingScreen
- ✅ **플레이스 선택**
  - 승인된 멤버십만 표시
  - 플레이스 이미지 프리로드 (`precacheImage`)
  - 플레이스 선택 시 `setCurrentPlace` 호출
  - 명시적 진입 선택 완료 → 플래그 해제

### 3. MainScreen 초기 데이터 로드
- ✅ **병렬 로드** (Future.wait)
  - `courseProvider.loadCourses(placeId)`
  - `storyProvider.loadStories(placeId)`
  - `promotionProvider.loadPromotions(placeId)`
  - `reservationProvider.loadUserReservations(userId, placeId)` - **Stream 구독**
  - `enrollmentProvider.loadUserEnrollments(userId, placeId)` - **Stream 구독**

- ✅ **실시간 업데이트**
  - ReservationProvider: Stream 구독으로 예약 변경 실시간 반영
  - EnrollmentProvider: Stream 구독으로 enrollment 변경 실시간 반영

---

## 🏠 HomeScreen 데이터 표시

### 1. 데이터 로드
- ✅ **필요 시 로드** (`_loadDataIfNeeded`)
  - MainScreen에서 로드하지 않은 경우에만 로드
  - enrollment 로드 추가됨

### 2. 예약 카드 (최근 이용 섹션)
- ✅ **EnrollmentProvider 구독**
  - `enrollmentsByCourseId` Map으로 O(1) 조회
  - `reservation.courseId`로 enrollment 찾기

- ✅ **남은 횟수 표시**
  - enrollment가 있고 유효할 때만 게이지바와 횟수 표시
  - `remainingCount / totalCount` 계산
  - progress 값 clamp (0.0 ~ 1.0)

- ✅ **데이터 정합성**
  - null 체크 및 fallback 처리
  - enrollment 없으면 표시하지 않음

---

## 📅 ReservationScreen

### 1. 데이터 로드
- ✅ **필요 시 로드** (`_loadDataIfNeeded`)
  - 코스 로드
  - enrollment 로드 (정책 엔진 기반 잠금/탭 가능에 사용)

### 2. 예약 가능 여부 확인
- ✅ **AbstractCalendarWidget**
  - EnrollmentProvider 구독하여 `enrollmentsByCourseId` 전달
  - 정책 엔진으로 예약 가능 여부 확인

---

## 📝 예약 생성 플로우

### 1. CalendarScreen - 세션 탭
- ✅ **예약 가능 여부 확인**
  - `ReservationPolicyEngine.evaluateReservation()` 호출
  - `enrollmentCanReserve` 파라미터 전달 (enrollment.isValid && remainingReservations > 0)
  - 정책 엔진 결과에 따라 잠금/탭 가능 결정

- ✅ **예약 생성**
  - `ReservationProvider.createReservation()` 호출
  - Cloud Function `createReservation` 호출
  - Cloud Function이 트랜잭션으로 처리:
    - enrollment.remainingReservations-- (차감)
    - sessionReservations.reservedCount++ (증가)
    - reservation 생성

- ✅ **자동 업데이트**
  - EnrollmentProvider: Stream 구독으로 자동 업데이트 (remainingReservations 감소)
  - ReservationProvider: Stream 구독으로 자동 업데이트 (새 예약 추가)

---

## ❌ 예약 취소 플로우

### 1. UserReservationManageBottomSheet
- ✅ **예약 취소**
  - `ReservationProvider.deleteReservation()` 호출
  - Cloud Function `cancelReservation` 호출
  - Cloud Function이 트랜잭션으로 처리:
    - enrollment.remainingReservations++ (복구)
    - sessionReservations.reservedCount-- (감소)
    - reservation 삭제

- ✅ **자동 업데이트**
  - EnrollmentProvider: Stream 구독으로 자동 업데이트 (remainingReservations 증가)
  - ReservationProvider: Stream 구독으로 자동 업데이트 (예약 제거)

---

## 👤 MyPageScreen

### 1. 데이터 로드
- ✅ **필요 시 로드** (`_loadData`)
  - 코스 로드
  - 예약 로드
  - enrollment 로드

### 2. 수강 중인 코스 섹션
- ✅ **EnrollmentProvider 구독**
  - `enrollments`에서 유효한 enrollment만 필터링 (`isValid && remainingReservations > 0`)
  - 코스 정보와 매칭하여 표시

- ✅ **데이터 정합성**
  - 코스 정보 없을 때 fallback 처리
  - enrollment 없으면 섹션 숨김

### 3. 예약 내역 표시
- ✅ **ReservationProvider 구독**
  - 실시간 예약 변경 반영
  - CompactCalendarWidget에 userReservations 전달

---

## ✅ 데이터 정합성 보장

### 1. Provider 구독
- ✅ **ReservationProvider**: Stream 구독 (실시간 업데이트)
- ✅ **EnrollmentProvider**: Stream 구독 (실시간 업데이트)
- ✅ **CourseProvider**: 필요 시 로드
- ✅ **PlaceProvider**: 현재 플레이스 관리

### 2. 데이터 동기화
- ✅ **예약 생성/취소 시**
  - Cloud Function이 enrollment.remainingReservations 업데이트
  - EnrollmentProvider Stream 구독으로 자동 반영
  - ReservationProvider Stream 구독으로 자동 반영

### 3. UI 정합성
- ✅ **null 체크 및 fallback 처리**
- ✅ **유효성 검증** (isValid, remainingReservations > 0)
- ✅ **progress 값 clamp** (0.0 ~ 1.0)
- ✅ **데이터 없을 때 UI 숨김 처리**

---

## 🔍 발견된 잠재적 이슈

### 1. ReservationProvider.createReservation()
- ⚠️ **로컬 상태 업데이트 (Optimistic Update)**
  - `_reservations = [..._reservations, created]` 로컬 업데이트
  - Stream 구독으로도 업데이트됨 (약간의 지연 가능)
  - **현재 상태**: 즉시 UI 업데이트를 위해 로컬 업데이트 유지 (합리적)
  - **개선 옵션**: Stream 업데이트 시 중복 체크 추가 가능

### 2. ReservationProvider.deleteReservation()
- ⚠️ **로컬 상태 업데이트 (Optimistic Update)**
  - `_reservations = _reservations.where(...).toList()` 로컬 업데이트
  - Stream 구독으로도 업데이트됨 (약간의 지연 가능)
  - **현재 상태**: 즉시 UI 업데이트를 위해 로컬 업데이트 유지 (합리적)
  - **개선 옵션**: Stream 업데이트 시 중복 체크 추가 가능

### 3. CalendarScreen 예약 생성 후
- ✅ **setState() 호출** - UI 갱신을 위해 필요
- ✅ **Stream 구독으로 자동 업데이트** - 데이터 정합성 보장

---

## 📊 최적화 상태

### 1. 데이터 호출 구조
- ✅ **병렬 로드**: MainScreen에서 Future.wait 사용
- ✅ **필요 시 로드**: 각 화면에서 중복 로드 방지
- ✅ **Stream 구독**: 실시간 업데이트로 불필요한 폴링 제거

### 2. 구독 최적화
- ✅ **ReservationProvider**: Stream 구독 (실시간 업데이트)
- ✅ **EnrollmentProvider**: Stream 구독 (실시간 업데이트)
- ✅ **구독 취소**: dispose 시 자동 정리

### 3. 조회 최적화
- ✅ **enrollmentsByCourseId**: Map으로 O(1) 조회
- ✅ **필터링**: 유효한 enrollment만 필터링

---

## 🎯 결론

전체 플로우가 **데이터 정합성을 보장**하며 **최적화된 구조**로 구현되어 있습니다.

### 강점
1. ✅ Stream 구독으로 실시간 업데이트
2. ✅ Cloud Function이 enrollment 업데이트 보장
3. ✅ 정책 엔진으로 예약 가능 여부 확인
4. ✅ 데이터 정합성 보장 (null 체크, fallback 처리)

### 개선 권장사항
1. ⚠️ ReservationProvider의 로컬 상태 업데이트 제거 (Stream 구독만으로 충분)
2. ✅ 현재 구조로도 충분히 동작하지만, 중복 업데이트 방지를 위해 개선 권장

