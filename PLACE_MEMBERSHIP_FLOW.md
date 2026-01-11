# 플레이스 멤버십 확인 프로세스 설계

## 🎯 요구사항

1. 사용자가 특정 플레이스의 멤버인지 확인
2. 초대 코드 기반 가입
3. 관리자 승인 전 Pending 상태 관리
4. 전화번호 기반 인증

---

## 📋 제안하는 플로우

### 시나리오 1: 신규 사용자 (회원가입)

```
1. 전화번호 입력
   ↓
2. SMS 인증 코드 발송
   ↓
3. 인증 코드 확인
   ↓
4. 사용자 정보 입력 (이름, 이메일 등)
   ↓
5. User 생성 (placeIds: [])
   ↓
6. 초대 코드 입력 화면
   ↓
7. 초대 코드 검증
   ↓
8. 플레이스 찾기
   ↓
9. PlaceMembership 생성 (status: "pending")
   ↓
10. 관리자 승인 대기 화면
```

### 시나리오 2: 기존 사용자 (로그인)

```
1. 전화번호 입력
   ↓
2. SMS 인증 코드 발송
   ↓
3. 인증 코드 확인
   ↓
4. User 조회
   ↓
5. 플레이스 멤버십 확인
   ↓
6-1. 승인된 플레이스 있음 → 해당 플레이스로 이동
6-2. Pending만 있음 → 승인 대기 화면
6-3. 플레이스 없음 → 초대 코드 입력 화면
```

### 시나리오 3: 추가 플레이스 가입

```
1. 설정 → 플레이스 추가
   ↓
2. 초대 코드 입력
   ↓
3. PlaceMembership 생성 (status: "pending")
   ↓
4. 관리자 승인 대기
```

---

## 🗄️ 데이터베이스 구조

### 1. **placeMemberships** 컬렉션 추가

```
placeMemberships/{membershipId}
├── id: string
├── userId: string
├── placeId: string
├── status: "pending" | "approved" | "rejected"
├── inviteCode: string?  // 초대 코드 (가입 시 사용)
├── requestedAt: timestamp  // 가입 요청 시간
├── approvedAt: timestamp?  // 승인 시간
├── rejectedAt: timestamp?  // 거부 시간
├── rejectedReason: string?  // 거부 사유
└── invitedBy: string?  // 초대한 관리자 ID
```

**인덱스:**
- `userId`, `status` (복합)
- `placeId`, `status` (복합)
- `inviteCode` (단일, 유니크)

### 2. **inviteCodes** 컬렉션 추가

```
inviteCodes/{code}
├── code: string  // 초대 코드 (예: "ABC123")
├── placeId: string
├── createdBy: string  // 생성한 관리자 ID
├── createdAt: timestamp
├── expiresAt: timestamp?  // 만료 시간 (선택적)
├── maxUses: number?  // 최대 사용 횟수
├── usedCount: number  // 사용된 횟수
├── isActive: boolean  // 활성화 여부
└── description: string?  // 설명
```

**인덱스:**
- `code` (단일, 유니크)
- `placeId`, `isActive` (복합)

### 3. **users** 컬렉션 업데이트

```
users/{userId}
├── ... (기존 필드)
├── phoneNumber: string  // 인증된 전화번호
├── phoneVerified: boolean  // 전화번호 인증 여부
└── placeIds: string[]  // 승인된 플레이스만 (자동 동기화)
```

**주의:** `placeIds`는 `placeMemberships`에서 자동으로 동기화됨

---

## 🔄 자동 동기화 로직

### placeMemberships → users.placeIds 동기화

```typescript
// Cloud Functions
export const onPlaceMembershipUpdated = functions.firestore
  .document('placeMemberships/{membershipId}')
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();
    
    // status가 "approved"로 변경된 경우
    if (before.status !== 'approved' && after.status === 'approved') {
      // users.placeIds에 추가
      const userRef = admin.firestore().collection('users').doc(after.userId);
      await userRef.update({
        placeIds: admin.firestore.FieldValue.arrayUnion(after.placeId),
      });
    }
    
    // status가 "approved"에서 다른 상태로 변경된 경우
    if (before.status === 'approved' && after.status !== 'approved') {
      // users.placeIds에서 제거
      const userRef = admin.firestore().collection('users').doc(after.userId);
      await userRef.update({
        placeIds: admin.firestore.FieldValue.arrayRemove(after.placeId),
      });
    }
  });
```

---

## 📱 앱 시작 시 플로우

### 1. 인증 상태 확인

```dart
class AuthService {
  // 현재 로그인한 사용자 확인
  Future<User?> getCurrentUser() async {
    // Firebase Auth에서 현재 사용자 확인
    // 또는 로컬 저장소에서 확인
  }
  
  // 사용자 역할 확인
  Future<UserRole> getUserRole(String userId) async {
    // adminUsers 컬렉션 확인
    final admin = await FirestoreService().getAdmin(userId);
    if (admin != null) {
      return UserRole.admin;
    }
    return UserRole.member;
  }
}
```

### 2. 플레이스 멤버십 확인

```dart
class PlaceMembershipService {
  // 사용자의 승인된 플레이스 목록
  Future<List<Place>> getApprovedPlaces(String userId) async {
    final memberships = await firestore
        .collection('placeMemberships')
        .where('userId', isEqualTo: userId)
        .where('status', isEqualTo: 'approved')
        .get();
    
    // placeIds 추출
    final placeIds = memberships.docs
        .map((doc) => doc.data()['placeId'] as String)
        .toList();
    
    // Place 정보 가져오기
    final places = await Future.wait(
      placeIds.map((id) => FirestoreService().getPlace(id))
    );
    
    return places.whereType<Place>().toList();
  }
  
  // Pending 상태 플레이스
  Future<List<PlaceMembership>> getPendingMemberships(String userId) async {
    // ...
  }
}
```

### 3. 앱 시작 로직

```dart
class AppStartupService {
  Future<void> initializeApp() async {
    // 1. 인증 상태 확인
    final user = await AuthService().getCurrentUser();
    
    if (user == null) {
      // 로그인 화면으로
      return '/login';
    }
    
    // 2. 역할 확인
    final role = await AuthService().getUserRole(user.userId);
    
    if (role == UserRole.admin) {
      // 관리자 화면으로
      return '/admin';
    }
    
    // 3. 플레이스 멤버십 확인
    final approvedPlaces = await PlaceMembershipService()
        .getApprovedPlaces(user.userId);
    final pendingMemberships = await PlaceMembershipService()
        .getPendingMemberships(user.userId);
    
    if (approvedPlaces.isEmpty && pendingMemberships.isEmpty) {
      // 초대 코드 입력 화면
      return '/invite-code';
    }
    
    if (approvedPlaces.isEmpty && pendingMemberships.isNotEmpty) {
      // 승인 대기 화면
      return '/pending-approval';
    }
    
    // 4. 기본 플레이스 선택 (또는 선택 화면)
    final defaultPlace = approvedPlaces.first;
    await PlaceService().setCurrentPlace(defaultPlace);
    
    // 멤버 화면으로
    return '/main';
  }
}
```

---

## 🔐 초대 코드 시스템

### 1. 초대 코드 생성 (관리자)

```dart
Future<InviteCode> createInviteCode({
  required String placeId,
  required String adminId,
  int? maxUses,
  DateTime? expiresAt,
}) async {
  // 랜덤 코드 생성 (6자리)
  final code = _generateRandomCode(6);
  
  final inviteCode = InviteCode(
    code: code,
    placeId: placeId,
    createdBy: adminId,
    createdAt: DateTime.now(),
    expiresAt: expiresAt,
    maxUses: maxUses,
    usedCount: 0,
    isActive: true,
  );
  
  await firestore.collection('inviteCodes').doc(code).set({
    ...inviteCode.toJson(),
    'createdAt': _dateTimeToTimestamp(inviteCode.createdAt),
    'expiresAt': expiresAt != null 
        ? _dateTimeToTimestamp(expiresAt) 
        : null,
  });
  
  return inviteCode;
}

String _generateRandomCode(int length) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final random = Random();
  return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
}
```

### 2. 초대 코드 검증 및 사용

```dart
Future<PlaceMembership> useInviteCode({
  required String userId,
  required String code,
}) async {
  // 1. 초대 코드 확인
  final inviteCodeDoc = await firestore
      .collection('inviteCodes')
      .doc(code)
      .get();
  
  if (!inviteCodeDoc.exists) {
    throw Exception('유효하지 않은 초대 코드입니다.');
  }
  
  final inviteCode = InviteCode.fromJson(inviteCodeDoc.data()!);
  
  // 2. 유효성 검증
  if (!inviteCode.isActive) {
    throw Exception('비활성화된 초대 코드입니다.');
  }
  
  if (inviteCode.expiresAt != null && 
      DateTime.now().isAfter(inviteCode.expiresAt!)) {
    throw Exception('만료된 초대 코드입니다.');
  }
  
  if (inviteCode.maxUses != null && 
      inviteCode.usedCount >= inviteCode.maxUses!) {
    throw Exception('사용 횟수를 초과한 초대 코드입니다.');
  }
  
  // 3. 이미 가입했는지 확인
  final existingMembership = await firestore
      .collection('placeMemberships')
      .where('userId', isEqualTo: userId)
      .where('placeId', isEqualTo: inviteCode.placeId)
      .limit(1)
      .get();
  
  if (existingMembership.docs.isNotEmpty) {
    throw Exception('이미 가입한 플레이스입니다.');
  }
  
  // 4. PlaceMembership 생성
  final membershipRef = firestore.collection('placeMemberships').doc();
  final membership = PlaceMembership(
    id: membershipRef.id,
    userId: userId,
    placeId: inviteCode.placeId,
    status: PlaceMembershipStatus.pending,
    inviteCode: code,
    requestedAt: DateTime.now(),
  );
  
  await membershipRef.set({
    ...membership.toJson(),
    'requestedAt': _dateTimeToTimestamp(membership.requestedAt),
  });
  
  // 5. 초대 코드 사용 횟수 증가
  await inviteCodeDoc.reference.update({
    'usedCount': admin.firestore.FieldValue.increment(1),
  });
  
  return membership;
}
```

---

## 👤 관리자 승인 프로세스

### 1. Pending 멤버 목록 조회

```dart
Future<List<PlaceMembershipWithUser>> getPendingMemberships(
  String placeId,
) async {
  final memberships = await firestore
      .collection('placeMemberships')
      .where('placeId', isEqualTo: placeId)
      .where('status', isEqualTo: 'pending')
      .orderBy('requestedAt', descending: false)
      .get();
  
  // 사용자 정보와 함께 반환
  final result = await Future.wait(
    memberships.docs.map((doc) async {
      final membership = PlaceMembership.fromJson(doc.data());
      final user = await FirestoreService().getUser(membership.userId);
      return PlaceMembershipWithUser(
        membership: membership,
        user: user,
      );
    })
  );
  
  return result;
}
```

### 2. 승인/거부

```dart
Future<void> approveMembership(String membershipId) async {
  await firestore.runTransaction((transaction) async {
    final membershipRef = firestore
        .collection('placeMemberships')
        .doc(membershipId);
    
    final membershipDoc = await transaction.get(membershipRef);
    if (!membershipDoc.exists) {
      throw Exception('멤버십을 찾을 수 없습니다.');
    }
    
    final membership = PlaceMembership.fromJson(membershipDoc.data()!);
    
    if (membership.status != PlaceMembershipStatus.pending) {
      throw Exception('승인 대기 상태가 아닙니다.');
    }
    
    // 멤버십 승인
    transaction.update(membershipRef, {
      'status': 'approved',
      'approvedAt': _dateTimeToTimestamp(DateTime.now()),
    });
    
    // users.placeIds에 추가 (Cloud Functions가 자동으로 처리하지만, 즉시 반영을 위해)
    final userRef = firestore.collection('users').doc(membership.userId);
    transaction.update(userRef, {
      'placeIds': admin.firestore.FieldValue.arrayUnion(membership.placeId),
    });
  });
}

Future<void> rejectMembership(
  String membershipId,
  String reason,
) async {
  // ...
}
```

---

## 📱 화면 플로우

### 1. 로그인 화면
```
- 전화번호 입력
- SMS 인증
- 인증 완료
```

### 2. 초대 코드 입력 화면
```
- 초대 코드 입력
- 검증
- 플레이스 정보 표시
- 가입 요청
```

### 3. 승인 대기 화면
```
- 대기 중인 플레이스 목록
- 요청 시간 표시
- 취소 버튼
```

### 4. 플레이스 선택 화면 (여러 플레이스인 경우)
```
- 승인된 플레이스 목록
- 선택하여 이동
```

---

## 🎯 권장 플로우

### 최종 권장안

```
[앱 시작]
    ↓
[인증 확인]
    ↓
[없음] → 로그인 화면
    ↓
[있음] → 역할 확인
    ↓
[관리자] → 관리자 화면
    ↓
[멤버] → 플레이스 멤버십 확인
    ↓
[승인된 플레이스 있음] → 플레이스 선택/기본 플레이스로 이동
    ↓
[Pending만 있음] → 승인 대기 화면
    ↓
[플레이스 없음] → 초대 코드 입력 화면
```

---

## 💡 추가 고려사항

### 1. 전화번호 기반 자동 매칭 (선택적)

관리자가 미리 전화번호를 등록한 경우:

```dart
// 관리자가 멤버 추가 시 전화번호로 등록
await firestore.collection('pendingMembers').add({
  'placeId': placeId,
  'phoneNumber': phoneNumber,
  'name': name,
  'createdBy': adminId,
  'createdAt': timestamp,
});

// 사용자 로그인 시 자동 매칭
final pendingMember = await firestore
    .collection('pendingMembers')
    .where('placeId', isEqualTo: placeId)
    .where('phoneNumber', isEqualTo: phoneNumber)
    .limit(1)
    .get();

if (pendingMember.docs.isNotEmpty) {
  // 자동으로 PlaceMembership 생성 (status: pending 또는 approved)
}
```

### 2. QR 코드 스캔 (선택적)

```dart
// QR 코드에 초대 코드 포함
// 스캔 시 자동으로 초대 코드 입력
```

### 3. 링크 공유 (선택적)

```
https://app.example.com/invite/ABC123
// 링크 클릭 시 자동으로 초대 코드 입력
```

---

## ✅ 구현 우선순위

### Phase 1: 기본 플로우
1. ✅ placeMemberships 컬렉션 추가
2. ✅ inviteCodes 컬렉션 추가
3. ✅ 초대 코드 생성/검증
4. ✅ PlaceMembership 생성
5. ✅ 관리자 승인/거부

### Phase 2: 앱 시작 로직
6. ✅ 인증 상태 확인
7. ✅ 역할 확인
8. ✅ 플레이스 멤버십 확인
9. ✅ 자동 라우팅

### Phase 3: UX 개선
10. ⚠️ 승인 대기 화면
11. ⚠️ 플레이스 선택 화면
12. ⚠️ 초대 코드 입력 화면

---

## 🔄 데이터 일관성

### users.placeIds 자동 동기화

Cloud Functions로 자동 동기화:
- `placeMemberships.status`가 "approved"로 변경 → `users.placeIds`에 추가
- `placeMemberships.status`가 "approved"에서 변경 → `users.placeIds`에서 제거

**장점:**
- 항상 최신 상태 유지
- 수동 동기화 불필요

