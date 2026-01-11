# 구독 최적화 분석

## 현재 구조

### 1. **member_detail_bottom_sheet.dart**
```dart
// 자체 구독 생성
_enrollmentSubscription = enrollmentService
    .watchUserEnrollments(userId, placeId: placeId)
    .listen((enrollments) { ... });
```

**쿼리**: `enrollments.where('userId', isEqualTo: userId).where('placeId', isEqualTo: placeId)`

### 2. **member_provider.dart**
```dart
// 코스별 멤버 조회
watchCourseMembers(courseId) {
  return enrollmentService.watchCourseMembers(courseId: courseId)...
}
```

**쿼리**: `courseMembers.where('courseId', isEqualTo: courseId)`

### 3. **EnrollmentProvider**
```dart
// 중앙화된 구독 관리 (이미 존재하지만 활용 안 됨)
loadUserEnrollments(userId, placeId) {
  _subscription = enrollmentService.watchUserEnrollments(...)
}
```

## 비효율적인 부분

### ❌ 문제 1: 중복 구독
- `member_detail_bottom_sheet`가 열릴 때마다 새로운 구독 생성
- 여러 바텀시트를 열면 여러 구독이 동시에 존재
- `EnrollmentProvider`가 이미 있는데 활용하지 않음

### ❌ 문제 2: 구독 관리 누락
- 바텀시트가 닫혀도 구독이 취소되지 않을 수 있음 (dispose에서 취소하지만)
- 같은 userId/placeId로 여러 바텀시트를 열면 중복 구독

### ❌ 문제 3: 데이터 소스 불일치
- `member_detail_bottom_sheet`: `enrollments` 컬렉션 직접 조회
- `member_provider`: `courseMembers` 컬렉션 조회
- 같은 enrollment 정보를 다른 방식으로 조회

## 개선 방안

### ✅ 방안 1: EnrollmentProvider 활용 (권장)

```dart
// member_detail_bottom_sheet.dart
Future<void> _loadUserData() async {
  final enrollmentProvider = Provider.of<EnrollmentProvider>(
    context,
    listen: false,
  );
  
  // EnrollmentProvider 사용 (중복 구독 방지)
  await enrollmentProvider.loadUserEnrollments(
    userId: widget.member.userId,
    placeId: placeId,
  );
  
  // Provider 구독
  enrollmentProvider.addListener(_onEnrollmentsChanged);
}

void _onEnrollmentsChanged() {
  if (!mounted) return;
  final enrollmentProvider = Provider.of<EnrollmentProvider>(
    context,
    listen: false,
  );
  setState(() {
    _enrollments = enrollmentProvider.enrollments;
    // ...
  });
}
```

**장점**:
- 중복 구독 방지
- 중앙화된 구독 관리
- 여러 바텀시트가 같은 userId를 조회해도 구독 1개만

**단점**:
- Provider 의존성 증가
- 바텀시트가 닫혀도 Provider 구독 유지 (다른 화면에서 사용 중일 수 있음)

### ✅ 방안 2: 구독 공유 (Stream 재사용)

```dart
// EnrollmentService에 구독 캐시 추가
class EnrollmentService {
  final Map<String, Stream<List<CourseEnrollment>>> _userEnrollmentStreams = {};
  
  Stream<List<CourseEnrollment>> watchUserEnrollments(
    String userId, {
    String? placeId,
  }) {
    final key = '${userId}_${placeId ?? 'all'}';
    return _userEnrollmentStreams.putIfAbsent(
      key,
      () => _createUserEnrollmentsStream(userId, placeId),
    );
  }
}
```

**장점**:
- 같은 userId/placeId 조합은 Stream 재사용
- Firestore 구독 1개만 생성

**단점**:
- Stream 캐시 관리 복잡
- 메모리 누수 가능성

### ✅ 방안 3: 현재 구조 유지 + 최적화

```dart
// member_detail_bottom_sheet.dart
// dispose에서 확실히 구독 취소
@override
void dispose() {
  _enrollmentSubscription?.cancel();
  _enrollmentSubscription = null; // 명시적 null 처리
  _nameController?.dispose();
  super.dispose();
}

// initState에서 기존 구독 확인
@override
void initState() {
  super.initState();
  // 같은 userId로 이미 구독 중이면 재사용
  _loadUserData();
}
```

**장점**:
- 구조 변경 최소화
- 빠른 적용 가능

**단점**:
- 근본적인 중복 구독 문제 해결 안 됨

## 권장 사항

**단기**: 방안 3 (현재 구조 유지 + dispose 최적화)
**장기**: 방안 1 (EnrollmentProvider 활용)

## 성능 영향

### 현재 (비효율)
- 바텀시트 1개: Firestore 구독 1개
- 바텀시트 3개 (같은 userId): Firestore 구독 3개 ❌
- 네트워크 트래픽: 3배

### 개선 후
- 바텀시트 1개: Firestore 구독 1개
- 바텀시트 3개 (같은 userId): Firestore 구독 1개 ✅
- 네트워크 트래픽: 1배

## 추가 고려사항

1. **member_provider의 courseMembers 구독**
   - 코스별로 구독이 생성됨
   - 여러 코스를 선택하면 여러 구독
   - 이는 정상적인 동작 (코스별 필터링 필요)

2. **pendingMembers 조회**
   - `_loadPendingMembers`는 일회성 조회 (구독 아님)
   - 비효율 없음

