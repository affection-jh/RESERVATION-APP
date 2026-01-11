# Firestore 데이터베이스 설계

## 📋 컬렉션 구조

### 1. **users** (사용자 컬렉션)
```
users/{userId}
├── userId: string
├── name: string
├── phoneNumber: string
├── email: string?
├── placeIds: string[]  // 속한 플레이스 ID 목록
├── createdAt: timestamp
└── updatedAt: timestamp?
```

### 2. **adminUsers** (관리자 컬렉션)
```
adminUsers/{userId}
├── userId: string
├── name: string
├── phoneNumber: string
├── email: string?
├── placeIds: string[]  // 관리하는 플레이스 ID 목록
├── createdAt: timestamp
└── updatedAt: timestamp?
```

### 3. **places** (장소/시설 컬렉션)
```
places/{placeId}
├── id: string
├── name: string
├── adminId: string  // 관리자 ID
├── description: string?
├── location: string?
└── courses: Course[]  // 중첩 배열 (자주 조회되므로)
```

**Course 구조 (중첩 객체):**
```typescript
{
  id: string
  name: string
  color: number  // ARGB hex
  imageUrl: string?  // 코스 이미지 URL (선택)
  sessions: CourseSession[]  // 중첩 배열
}
```

**CourseSession 구조 (중첩 객체):**
```typescript
{
  dayOfWeek: number  // 1=월요일, 7=일요일
  startTime: string  // "13:00"
  endTime: string
  capacity: number
  dateCapacityOverrides: {  // Map<string, number>
    "2024-01-15": 20,
    "2024-01-22": 50
  }
}
```

### 4. **reservations** (예약 컬렉션) ⭐ 핵심
```
reservations/{reservationId}
├── id: string
├── userId: string
├── courseId: string
├── placeId: string  // 빠른 필터링을 위한 중복
├── dayOfWeek: number
├── startTime: string
├── reservedAt: timestamp  // 예약한 시간
├── reservedDate: timestamp  // 예약 대상 날짜 (날짜만, 시간은 00:00)
├── reservedDateString: string  // "2024-01-15" (쿼리 최적화)
└── note: string?
```

**중복 필드 이유:**
- `placeId`: 플레이스별 예약 조회 최적화
- `reservedDateString`: 날짜 범위 쿼리 최적화 (timestamp는 복잡함)

### 5. **enrollments** (코스 등록 컬렉션)
```
enrollments/{enrollmentId}
├── id: string
├── userId: string
├── courseId: string
├── placeId: string
├── enrolledAt: timestamp
├── validFrom: timestamp
├── validUntil: timestamp
├── totalReservations: number
├── remainingReservations: number
└── extensionRequest: ExtensionRequest?  // 중첩 객체
```

**ExtensionRequest 구조 (중첩 객체):**
```typescript
{
  id: string
  requestedAt: timestamp
  reason: string
  status: "pending" | "approved" | "rejected"
  approvedAt: timestamp?
  rejectedAt: timestamp?
  rejectionReason: string?
}
```

---

## 🔍 주요 쿼리 패턴 및 인덱스

### 1. **사용자별 예약 조회**
```dart
firestore
  .collection('reservations')
  .where('userId', isEqualTo: userId)
  .orderBy('reservedDate', descending: false)
```

**인덱스:** `userId` (단일 필드)

### 2. **코스별 예약 조회**
```dart
firestore
  .collection('reservations')
  .where('courseId', isEqualTo: courseId)
  .where('reservedDateString', isGreaterThanOrEqualTo: startDate)
  .where('reservedDateString', isLessThanOrEqualTo: endDate)
```

**인덱스:** `courseId`, `reservedDateString` (복합)

### 3. **특정 세션의 예약 조회 (날짜별)**
```dart
firestore
  .collection('reservations')
  .where('courseId', isEqualTo: courseId)
  .where('dayOfWeek', isEqualTo: dayOfWeek)
  .where('startTime', isEqualTo: startTime)
  .where('reservedDateString', isEqualTo: dateString)
```

**인덱스:** `courseId`, `dayOfWeek`, `startTime`, `reservedDateString` (복합)

### 4. **플레이스별 예약 조회**
```dart
firestore
  .collection('reservations')
  .where('placeId', isEqualTo: placeId)
  .where('reservedDateString', isGreaterThanOrEqualTo: today)
  .orderBy('reservedDateString')
```

**인덱스:** `placeId`, `reservedDateString` (복합)

### 5. **사용자별 등록 조회**
```dart
firestore
  .collection('enrollments')
  .where('userId', isEqualTo: userId)
  .where('validUntil', isGreaterThan: now)
```

**인덱스:** `userId`, `validUntil` (복합)

### 6. **연장 요청 조회 (관리자)**
```dart
firestore
  .collection('enrollments')
  .where('placeId', isEqualTo: placeId)
  .where('extensionRequest.status', isEqualTo: 'pending')
```

**인덱스:** `placeId`, `extensionRequest.status` (복합)

---

## 🔐 Firestore 보안 규칙 예시

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    
    // Helper functions
    function isAuthenticated() {
      return request.auth != null;
    }
    
    function isOwner(userId) {
      return isAuthenticated() && request.auth.uid == userId;
    }
    
    function isAdmin() {
      return isAuthenticated() && 
             exists(/databases/$(database)/documents/adminUsers/$(request.auth.uid));
    }
    
    function managesPlace(placeId) {
      return isAdmin() && 
             get(/databases/$(database)/documents/adminUsers/$(request.auth.uid)).data.placeIds.hasAny([placeId]);
    }
    
    // Users collection
    match /users/{userId} {
      allow read: if isOwner(userId) || isAdmin();
      allow create: if isAuthenticated() && request.auth.uid == userId;
      allow update: if isOwner(userId) || managesPlace(resource.data.placeIds[0]);
      allow delete: if isAdmin();
    }
    
    // AdminUsers collection
    match /adminUsers/{userId} {
      allow read: if isAdmin();
      allow create: if isAdmin();  // 기존 관리자만 생성 가능
      allow update: if isOwner(userId) || isAdmin();
      allow delete: if false;  // 삭제 불가
    }
    
    // Places collection
    match /places/{placeId} {
      allow read: if isAuthenticated();
      allow create: if isAdmin();
      allow update: if managesPlace(placeId);
      allow delete: if false;  // 삭제는 비활성화로 처리
    }
    
    // Reservations collection
    match /reservations/{reservationId} {
      allow read: if isAuthenticated();
      allow create: if isAuthenticated() && 
                      request.resource.data.userId == request.auth.uid;
      allow update: if isOwner(resource.data.userId) || 
                      managesPlace(resource.data.placeId);
      allow delete: if isOwner(resource.data.userId) || 
                      managesPlace(resource.data.placeId);
    }
    
    // Enrollments collection
    match /enrollments/{enrollmentId} {
      allow read: if isAuthenticated();
      allow create: if isAdmin();  // 관리자만 등록 생성
      allow update: if isAdmin() || 
                      (isOwner(resource.data.userId) && 
                       // 연장 요청만 사용자가 수정 가능
                       request.resource.data.diff(resource.data).affectedKeys().hasOnly(['extensionRequest']));
      allow delete: if isAdmin();
    }
  }
}
```

---

## 📊 데이터 구조 선택 이유

### ✅ 중첩 객체 vs 서브컬렉션

**Place → Course → Session: 중첩 객체 선택**
- 이유:
  - Place와 Course는 자주 함께 조회됨
  - Course 수가 많지 않음 (보통 10-20개)
  - 한 번의 읽기로 모든 정보 획득 가능
  - 실시간 업데이트 시 효율적

**Reservation: 독립 컬렉션 선택**
- 이유:
  - 다양한 방식으로 쿼리됨 (userId, courseId, date 등)
  - 예약 수가 많아질 수 있음
  - 실시간 리스너 최적화
  - 트랜잭션 처리 필요

**Enrollment: 독립 컬렉션 선택**
- 이유:
  - 연장 요청 관리가 복잡함
  - 사용자별, 플레이스별 조회 필요
  - ExtensionRequest는 중첩 객체로 충분

---

## 🚀 성능 최적화 전략

### 1. **읽기 최적화**
- `reservedDateString` 필드 추가로 날짜 쿼리 간소화
- `placeId` 중복 저장으로 플레이스별 조회 최적화
- 필요한 필드만 조회 (select)

### 2. **쓰기 최적화**
- 예약 생성 시 트랜잭션 사용 (동시성 제어)
- 배치 쓰기 활용 (여러 예약 동시 생성 시)

### 3. **실시간 리스너 최적화**
- 특정 쿼리로 필터링하여 불필요한 업데이트 방지
- 리스너 해제 관리 (메모리 누수 방지)

### 4. **캐싱 전략**
- Place 데이터는 자주 변경되지 않으므로 캐싱
- Course 정보도 캐싱 가능

---

## 🔄 트랜잭션 예시 (예약 생성)

```dart
Future<Reservation> createReservation(Reservation reservation) async {
  return await firestore.runTransaction((transaction) async {
    // 1. 사용자 등록 정보 확인
    final enrollmentRef = firestore
        .collection('enrollments')
        .where('userId', isEqualTo: reservation.userId)
        .where('courseId', isEqualTo: reservation.courseId)
        .limit(1);
    
    final enrollmentSnapshot = await transaction.get(enrollmentRef);
    if (enrollmentSnapshot.docs.isEmpty) {
      throw Exception('등록된 코스가 아닙니다.');
    }
    
    final enrollment = CourseEnrollment.fromJson(
      enrollmentSnapshot.docs.first.data()
    );
    
    if (!enrollment.canReserve) {
      throw Exception('예약 가능한 횟수가 없습니다.');
    }
    
    // 2. 세션 수용인원 확인
    final placeRef = firestore.doc('places/${reservation.placeId}');
    final placeDoc = await transaction.get(placeRef);
    final place = Place.fromJson(placeDoc.data()!);
    
    final course = place.findCourse(reservation.courseId);
    if (course == null) throw Exception('코스를 찾을 수 없습니다.');
    
    final session = course.findSession(
      reservation.dayOfWeek,
      reservation.startTime
    );
    if (session == null) throw Exception('세션을 찾을 수 없습니다.');
    
    // 해당 날짜의 예약 수 확인
    final existingReservations = await transaction.get(
      firestore
          .collection('reservations')
          .where('courseId', isEqualTo: reservation.courseId)
          .where('dayOfWeek', isEqualTo: reservation.dayOfWeek)
          .where('startTime', isEqualTo: reservation.startTime)
          .where('reservedDateString', isEqualTo: 
                 _formatDate(reservation.reservedDate))
    );
    
    final dateCapacity = session.getCapacityForDate(reservation.reservedDate);
    if (existingReservations.docs.length >= dateCapacity) {
      throw Exception('예약 가능한 인원이 없습니다.');
    }
    
    // 3. 예약 생성
    final reservationRef = firestore.collection('reservations').doc();
    transaction.set(reservationRef, {
      ...reservation.toJson(),
      'id': reservationRef.id,
      'placeId': reservation.placeId,
      'reservedDateString': _formatDate(reservation.reservedDate),
    });
    
    // 4. 등록 정보 업데이트 (남은 횟수 차감)
    transaction.update(enrollmentSnapshot.docs.first.reference, {
      'remainingReservations': enrollment.remainingReservations - 1,
    });
    
    return reservation.copyWith(id: reservationRef.id);
  });
}
```

---

## 📝 필수 인덱스 목록

Firestore Console에서 다음 인덱스를 생성해야 합니다:

1. **reservations**
   - `userId` (단일)
   - `courseId`, `reservedDateString` (복합, 오름차순)
   - `courseId`, `dayOfWeek`, `startTime`, `reservedDateString` (복합)
   - `placeId`, `reservedDateString` (복합, 오름차순)

2. **enrollments**
   - `userId`, `validUntil` (복합, 오름차순)
   - `placeId`, `extensionRequest.status` (복합)
   - `userId`, `courseId` (복합)

3. **users**
   - `placeIds` (배열 포함 쿼리용)

---

## 🎯 마이그레이션 전략

1. **기존 MockData → Firestore**
   - Place 데이터 먼저 마이그레이션
   - 사용자 데이터 마이그레이션
   - 등록 정보 마이그레이션
   - 예약 데이터 마이그레이션

2. **점진적 전환**
   - 기존 서비스 레이어 유지
   - Firestore 구현 추가
   - Feature flag로 전환 제어

