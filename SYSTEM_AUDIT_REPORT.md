# 전체 시스템 점검 보고서

## 📋 개요
전체 시스템을 막론하고 불완전한 부분을 점검한 결과입니다. 관리자 기능까지 포함하여 확인했습니다.

---

## 🔴 Critical Issues (즉시 수정 필요)

### 1. 일반 사용자 재등록 기능 미구현
**위치**: `lib/widgets/enrollment_detail_bottom_sheet.dart:509`

**문제점**:
```dart
onPressed: () {
  // TODO: 재등록 기능 구현
  SnackbarUtil.showInfo(context, '재등록 기능은 준비 중입니다.');
},
```

**현재 상태**:
- 관리자는 재등록 기능이 구현되어 있음 (`enrollment_detail_screen.dart`, `member_detail_bottom_sheet.dart`)
- 일반 사용자는 재등록 버튼만 있고 실제 기능이 없음

**권장 조치**:
- 관리자 재등록 로직을 참고하여 일반 사용자용 재등록 기능 구현
- 또는 재등록은 관리자만 처리하도록 버튼 제거

---

### 2. 일반 사용자 연장 요청 기능 미구현
**위치**: `lib/widgets/enrollment_detail_bottom_sheet.dart:586`

**문제점**:
```dart
void _requestExtension(String reason) {
  setState(() {
    _isRequesting = true;
  });

  // TODO: 실제 연장 요청 로직 구현
  Future.delayed(const Duration(seconds: 1), () {
    // ...
    SnackbarUtil.showSuccess(context, '연장 요청이 접수되었습니다.');
  });
}
```

**현재 상태**:
- `UserService.requestExtension()` 메서드는 이미 구현되어 있음 (`lib/services/user_service.dart:365`)
- 하지만 `enrollment_detail_bottom_sheet.dart`에서 호출하지 않음
- EnrollmentService에도 연장 요청 관련 메서드가 있음

**권장 조치**:
```dart
void _requestExtension(String reason) async {
  setState(() {
    _isRequesting = true;
  });

  try {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final currentUser = authProvider.currentUser;
    if (currentUser == null) {
      throw Exception('로그인이 필요합니다.');
    }

    final userService = UserService();
    await userService.requestExtension(
      userId: currentUser.userId,
      courseId: widget.enrollment.courseId,
      reason: reason,
    );

    if (mounted) {
      setState(() {
        _isRequesting = false;
        _isExpanded = false;
      });
      _reasonController.clear();
      widget.onExtensionRequested?.call();
      SnackbarUtil.showSuccess(context, '연장 요청이 접수되었습니다.');
    }
  } catch (e) {
    if (mounted) {
      setState(() {
        _isRequesting = false;
      });
      SnackbarUtil.showInfo(context, '연장 요청 중 오류가 발생했습니다: $e');
    }
  }
}
```

---

### 3. 관리자 예약 추가 기능 미구현
**위치**: `lib/screens/admin/widgets/reservation_manage_bottom_sheet.dart:226`

**문제점**:
```dart
Future<void> _addReservation() async {
  // ...
  try {
    // TODO: 실제 예약 추가 로직 구현
    // ...
    widget.onReservationAdded?.call();
  } catch (e) {
    // ...
  }
}
```

**현재 상태**:
- `session_detail_screen.dart:436`에는 `_addReservationForUser()` 메서드가 구현되어 있음
- `ReservationService.createReservation()`을 사용하여 예약 생성
- 하지만 `reservation_manage_bottom_sheet.dart`에서는 미구현

**권장 조치**:
- `session_detail_screen.dart`의 구현을 참고하여 `reservation_manage_bottom_sheet.dart`에 동일한 로직 추가
- 또는 `ReservationService` 또는 `FirestoreService.createReservation()` 직접 호출

---

## 🟡 Medium Issues (개선 권장)

### 4. 관리자 ID 하드코딩
**위치**: `lib/screens/admin/widgets/enrollment_detail_screen.dart` (여러 곳)

**문제점**:
```dart
performedBy: 'admin', // TODO: 실제 admin ID로 변경
```

**발견된 위치**:
- Line 325: `adjustCount` 액션
- Line 547: `extendPeriod` 액션
- Line 732: `reenroll` 액션 (새 enrollment)
- Line 824: `reenroll` 액션 (기존 enrollment)
- Line 947: `cancel` 액션

**현재 상태**:
- `AuthProvider.currentAdmin?.userId`로 관리자 ID를 가져올 수 있음
- 하지만 모든 곳에서 `'admin'`으로 하드코딩되어 있음

**권장 조치**:
```dart
final authProvider = Provider.of<AuthProvider>(context, listen: false);
final adminId = authProvider.currentAdmin?.userId ?? 'admin'; // fallback

performedBy: adminId,
```

---

### 5. UnimplementedError 처리
**위치**: 
- `lib/services/user_service.dart:236` - `getUserPlaces()`
- `lib/services/auth_service.dart:810` - `verifyCode()` (Deprecated)

**문제점**:
- `getUserPlaces()`는 `UnimplementedError`를 throw하지만 실제로 호출되는 곳이 있는지 확인 필요
- `verifyCode()`는 `@Deprecated`이므로 사용되지 않을 것으로 예상

**권장 조치**:
- `getUserPlaces()`가 실제로 사용되는지 확인
- 사용되지 않으면 제거 또는 구현
- `verifyCode()`는 Deprecated이므로 그대로 유지

---

## ✅ 완료된 기능 (이전에 누락으로 보고되었으나 확인 결과 구현됨)

### 6. 세션 취소 기능
**위치**: `lib/screens/admin/widgets/session_detail_screen.dart:468`

**상태**: ✅ 완료
- Cloud Function `cancelSession` 구현됨
- 클라이언트 연동 완료 (`FirestoreService.cancelSession()`)
- UI 구현 완료 (세션 상세 화면에 버튼)
- 확인 다이얼로그 및 에러 처리 완료

---

## 📊 요약

| 카테고리 | Critical | Medium | 완료 | 총계 |
|---------|---------|--------|------|------|
| 미구현 기능 | 3 | 0 | 0 | 3 |
| 하드코딩/개선 | 0 | 1 | 0 | 1 |
| UnimplementedError | 0 | 1 | 0 | 1 |
| **전체** | **3** | **2** | **1** | **6** |

---

## 🎯 우선순위별 수정 권장사항

### 즉시 수정 (Critical)
1. **일반 사용자 연장 요청 기능 구현** (가장 쉬움 - 이미 서비스 메서드 존재)
2. **일반 사용자 재등록 기능 구현 또는 버튼 제거**
3. **관리자 예약 추가 기능 구현**

### 개선 권장 (Medium)
4. **관리자 ID 하드코딩 수정** (5곳)
5. **UnimplementedError 사용 여부 확인**

---

## 📝 추가 확인 사항

### 에러 처리
- 대부분의 try-catch 블록에서 에러 메시지를 사용자에게 표시하고 있음 ✅
- 일부 에러는 `debugPrint`만 하고 사용자에게 표시하지 않는 경우가 있으나, 대부분은 적절히 처리됨

### 데이터 검증
- 예약 생성 시 enrollment 검증 ✅
- 예약 취소 시 시간 제한 검증 ✅
- 코스 삭제 시 활성 예약 확인 ✅
- 관리자 예약 추가 시 정책 검증은 `createReservation` Cloud Function에서 처리됨 ✅

### 관리자 권한
- Cloud Functions에서 `assertAdminUid()`로 관리자 권한 확인 ✅
- 클라이언트에서도 적절히 관리자 체크 수행 ✅

---

## 🔍 발견되지 않은 이슈

다음 항목들은 이전에 우려되었으나 확인 결과 문제 없음:
- ✅ 세션 취소 기능 클라이언트 연동 (이미 완료)
- ✅ 에러 처리 대부분 적절히 구현됨
- ✅ 데이터 검증 로직 적절히 구현됨
- ✅ 관리자 권한 체크 적절히 구현됨

