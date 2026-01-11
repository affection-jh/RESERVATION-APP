# 코스 삭제 시 Enrollment 처리 전략

## 📊 현재 상황 분석

### 현재 구조
- `places/{placeId}/courses[]` - 코스 배열 (삭제 시 여기서만 제거)
- `enrollments/{enrollmentId}` - 등록 정보 (courseId 포함)
- `reservations/{reservationId}` - 예약 정보 (courseId 포함)

### 문제점
1. 코스 삭제 시 `enrollments`에 해당 `courseId`를 가진 문서들이 남아있음
2. 일반 사용자가 로그인 시 삭제된 코스의 enrollment를 조회하면 혼란 발생
3. UI에서 코스를 찾을 수 없어 에러 발생 가능

---

## 🎯 옵션 비교

### 옵션 1: 완전 삭제 (권장) ⭐
**구현**: 코스 삭제 시 해당 `courseId`의 모든 `enrollments` 삭제

**장점:**
- ✅ 사용자 혼란 완전 방지
- ✅ 깔끔한 데이터 구조
- ✅ 쿼리 성능 향상 (불필요한 데이터 제거)
- ✅ 구현 간단

**단점:**
- ❌ 히스토리 손실 (하지만 코스가 삭제되면 의미 없는 데이터)

**구현 위치:**
- `FirestoreService.deleteCourse()` 메서드에서 enrollments 삭제 추가
- 또는 Cloud Function으로 자동화

---

### 옵션 2: Soft Delete
**구현**: enrollment에 `courseDeleted: true` 플래그 추가, 조회 시 필터링

**장점:**
- ✅ 히스토리 보존 (관리자용 통계 가능)

**단점:**
- ❌ 복잡도 증가
- ❌ 모든 조회 쿼리에 필터 추가 필요
- ❌ 사용자에게는 여전히 보이지 않게 해야 함
- ❌ 데이터 정합성 관리 어려움

---

### 옵션 3: 하이브리드
**구현**: 
- 활성 enrollment (validUntil > now) → 삭제
- 만료된 enrollment → 유지 (히스토리용)

**장점:**
- ✅ 활성 사용자 혼란 방지
- ✅ 히스토리 일부 보존

**단점:**
- ❌ 복잡한 로직
- ❌ 일관성 문제 (일부는 삭제, 일부는 유지)

---

## 💡 최적의 구현: 완전 삭제 + Cloud Function

### 추천 이유
1. **사용자 경험 우선**: 삭제된 코스의 enrollment는 사용자에게 의미 없음
2. **데이터 일관성**: 코스가 없으면 enrollment도 없어야 함
3. **성능**: 불필요한 데이터 제거로 쿼리 성능 향상
4. **구현 단순**: 한 번에 처리

### 구현 방법

#### 방법 1: 클라이언트에서 직접 삭제 (간단)
```dart
Future<void> deleteCourse(String placeId, String courseId) async {
  // 1. 코스 삭제
  await _deleteCourseFromPlace(placeId, courseId);
  
  // 2. 해당 코스의 모든 enrollments 삭제
  final enrollmentsQuery = _firestore
      .collection('enrollments')
      .where('courseId', isEqualTo: courseId)
      .where('placeId', isEqualTo: placeId);
  
  final snapshot = await enrollmentsQuery.get();
  final batch = _firestore.batch();
  
  for (var doc in snapshot.docs) {
    batch.delete(doc.reference);
  }
  
  await batch.commit();
}
```

#### 방법 2: Cloud Function으로 자동화 (권장)
```typescript
// 코스 삭제 시 enrollments 자동 삭제
export const onCourseDeleted = functions.firestore
  .document('places/{placeId}')
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();
    
    const beforeCourses = before.courses || [];
    const afterCourses = after.courses || [];
    
    // 삭제된 코스 찾기
    const deletedCourseIds = beforeCourses
      .map((c: any) => c.id)
      .filter((id: string) => 
        !afterCourses.some((c: any) => c.id === id)
      );
    
    // 각 삭제된 코스의 enrollments 삭제
    for (const courseId of deletedCourseIds) {
      const enrollmentsQuery = admin.firestore()
        .collection('enrollments')
        .where('courseId', '==', courseId)
        .where('placeId', '==', context.params.placeId);
      
      const snapshot = await enrollmentsQuery.get();
      const batch = admin.firestore().batch();
      
      snapshot.docs.forEach((doc) => {
        batch.delete(doc.ref);
      });
      
      await batch.commit();
    }
  });
```

---

## 🔄 추가 고려사항

### 1. 예약(Reservations) 처리
- 코스 삭제 시 해당 코스의 예약도 처리 필요
- 과거 예약은 유지할지, 삭제할지 결정 필요
- **권장**: 과거 예약은 유지 (통계용), 미래 예약만 삭제

### 2. pendingMembers 처리
- pendingMembers의 courseIds에서도 제거 필요
- 이미 `_removeCourseFromPendingMembers()` 로직 존재

### 3. courseMembers 처리
- enrollments 삭제 시 courseMembers도 자동 삭제됨 (이미 Cloud Function 존재)

---

## ✅ 최종 권장사항

**옵션 1 (완전 삭제) + 방법 1 (클라이언트 직접 삭제)**

이유:
1. 구현이 간단하고 즉시 적용 가능
2. 사용자 혼란 완전 방지
3. 데이터 일관성 유지
4. 나중에 Cloud Function으로 마이그레이션 가능

**구현 순서:**
1. `FirestoreService.deleteCourse()` 수정
2. 배치 삭제로 enrollments 제거
3. (선택) Cloud Function으로 자동화



