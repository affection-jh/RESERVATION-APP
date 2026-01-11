# 사용자 정보 업데이트 누락 이슈

## 🔴 문제점

### 1. 이름 변경 시 누락되는 업데이트

**위치**: `lib/widgets/name_edit_bottom_sheet.dart:73-124`

**현재 구현**:
```dart
// users/adminUsers만 업데이트
await userService.updateUser(updatedUser);
// 또는
await userService.updateAdmin(updatedAdmin);
```

**누락되는 업데이트**:
- ❌ `pendingMembers` 컬렉션의 `name` 필드
- ❌ `placeMemberships` 컬렉션 (이름 저장 여부 확인 필요)

**영향**:
- 관리자가 미리 등록한 `pendingMembers`의 이름이 사용자가 변경한 이름과 불일치
- 사용자가 이름을 변경해도 관리자 화면에는 이전 이름이 표시될 수 있음

---

### 2. 전화번호 변경 시 누락되는 업데이트

**위치**: `lib/services/user_service.dart:588-634`

**현재 구현**:
```dart
// 트랜잭션으로 업데이트
await _firestore.runTransaction((transaction) async {
  // users/adminUsers 업데이트 ✅
  // pendingMembers 업데이트 ✅
});
```

**누락되는 업데이트**:
- ❌ `placeMemberships` 컬렉션 (전화번호 저장 여부 확인 필요)
- ❌ `reservations` 컬렉션 (전화번호 저장 여부 확인 필요)

**참고**: `enrollments` 컬렉션은 `userId`만 저장하므로 업데이트 불필요 ✅

---

## 📊 데이터 구조 분석

### 저장되는 위치별 사용자 정보

| 컬렉션 | userId | name | phoneNumber | 업데이트 필요 |
|--------|--------|------|-------------|--------------|
| `users` | ✅ | ✅ | ✅ | ✅ |
| `adminUsers` | ✅ | ✅ | ✅ | ✅ |
| `enrollments` | ✅ | ❌ | ❌ | ❌ (userId만) |
| `reservations` | ✅ | ❌ | ❌ | ❌ (userId만) |
| `pendingMembers` | ❌ | ✅ | ✅ | ✅ |
| `placeMemberships` | ✅ | ❓ | ❓ | ❓ (확인 필요) |

---

## 🔧 수정 방안

### 방안 1: 이름 변경 시 pendingMembers도 업데이트 (권장)

**이유**:
- `pendingMembers.name`은 관리자가 입력한 이름이지만, 사용자가 실제 이름을 변경하면 동기화하는 것이 일관성 있음
- 또는 사용자 이름과 관리자 입력 이름을 구분하여 관리

**구현**:
```dart
// UserService.updateUser() 수정
Future<User> updateUser(User user) async {
  final docRef = _firestore.collection('users').doc(user.userId);
  
  // 트랜잭션으로 users + pendingMembers 업데이트
  await _firestore.runTransaction((transaction) async {
    // 1. users 업데이트
    transaction.update(docRef, {
      ...user.toJson(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    
    // 2. pendingMembers에서 해당 전화번호의 모든 항목 업데이트
    final pendingMembersQuery = _firestore
        .collection('pendingMembers')
        .where('phoneNumber', isEqualTo: user.phoneNumber);
    final pendingMembersSnapshot = await pendingMembersQuery.get();
    
    for (final doc in pendingMembersSnapshot.docs) {
      transaction.update(doc.reference, {
        'name': user.name,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  });
  
  // ... 나머지 로직
}
```

---

### 방안 2: 이름 변경 시 pendingMembers는 유지 (대안)

**이유**:
- `pendingMembers.name`은 관리자가 입력한 이름이므로 사용자가 변경해도 유지
- 사용자 이름(`users.name`)과 관리자 입력 이름(`pendingMembers.name`)을 구분

**구현**:
- 현재 상태 유지 (이름 변경 시 `users`만 업데이트)
- 관리자 화면에서 `pendingMembers.name` 우선 표시, 없으면 `users.name` 표시

---

## 🎯 권장 사항

### 즉시 수정 (Critical)

1. **이름 변경 시 pendingMembers 동기화**
   - 방안 1 또는 방안 2 중 선택
   - 트랜잭션으로 일관성 보장

2. **전화번호 변경 시 placeMemberships 확인**
   - `placeMemberships`에 전화번호가 저장되는지 확인
   - 저장된다면 트랜잭션에 추가

### 확인 필요

1. **placeMemberships 구조 확인**
   - `name` 또는 `phoneNumber` 필드 존재 여부
   - 존재한다면 업데이트 로직 추가

2. **reservations 구조 확인**
   - `name` 또는 `phoneNumber` 필드 존재 여부
   - 일반적으로 `userId`만 저장하므로 업데이트 불필요할 가능성 높음

---

## 📝 현재 상태 요약

| 항목 | 이름 변경 | 전화번호 변경 | 트랜잭션 |
|------|----------|--------------|---------|
| `users` | ✅ | ✅ | ❌ |
| `adminUsers` | ✅ | ✅ | ✅ |
| `pendingMembers` | ❌ | ✅ | ✅ |
| `placeMemberships` | ❓ | ❓ | - |
| `enrollments` | ❌ (불필요) | ❌ (불필요) | - |
| `reservations` | ❌ (불필요) | ❌ (불필요) | - |

**결론**: 이름 변경 시 `pendingMembers` 업데이트가 누락되어 있습니다.

