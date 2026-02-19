# 트랜잭션·네비게이션 필수 구간 조사 (코스 수정 제외)

트랜잭션: (1) 백엔드 원자성 (2) 화면·로딩·네비게이션 일관성(로딩 중 나가기 등)  
**코스 수정(course_edit_screen)은 수정 대상에서 제외.**

**적용 완료 (클라이언트):** 플레이스 삭제 finally, 스토리 추가 외곽 try/finally, 멤버 코스 등록 _leaveRequested 시 _isSaving 해제, 수강 상세 나가기 시 플래그 해제.

---

## 1. 플레이스 삭제 (`place_delete_confirm_screen.dart`)

### 백엔드
- **deletePlace**: Cloud Function `deletePlace` 1회 호출 → 서버에서 일괄 삭제(트랜잭션 처리 가능).
- 클라이언트: `placeProvider.deletePlace()` 성공 후 `userService.updateAdmin(updatedAdmin)` 호출.
- **이슈**: 플레이스 삭제는 Function 한 번이지만, 그 다음 `updateAdmin`이 실패하면 “플레이스는 삭제됐는데 Admin 문서는 갱신 안 됨” 상태가 될 수 있음. (서버 트랜잭션으로 묶을 수 있으면 이상적.)

### 화면·네비게이션
- `_isLoading`, `_leaveRequested`, `PopScope(canPop: !_isLoading)`, `_handleBackDuringDelete()` 있음.
- **이슈**: 성공 경로에 `finally`가 없음.  
  - 성공 시에는 `pushNamedAndRemoveUntil`으로 화면을 바꾸므로 실사용에는 문제 없을 수 있음.  
  - 예외가 `deletePlace` 성공 후 `updateAdmin` 전/중에 나면 `_isLoading`이 false로 안 돌아갈 수 있음.  
  - **권장**: `_handleDelete()` 전체를 `try / catch / finally`로 감싸고, `finally`에서 `if (mounted) setState(() => _isLoading = false);` 한 번 수행.

---

## 2. 비정기 일정 추가·정기 일정 취소 (`weekly_override_schedule_screen.dart`)

### 백엔드
- **저장 흐름**:  
  - 기존 오버라이드 삭제(`deleteFutures`) → `Future.wait(deleteFutures)`  
  - 비정기 추가(`createFutures`) → `Future.wait(createFutures)`  
  - 정기 취소(`cancelFutures`) → `Future.wait(cancelFutures)`  
  - (미리 예약 열기 `setBookingWeekOpened` 등)
- **이슈**: 한 번의 “저장”이 여러 단계로 나뉘고, 각 단계만 `Future.wait`로 묶여 있음.  
  - 중간에 실패하면 “일부만 반영된 상태”(예: 삭제만 되고 추가는 안 됨) 가능.  
  - 로딩 중 나가기(`_leaveRequested`) 시 이미 완료된 `Future.wait`는 롤백되지 않음 → **부분 저장** 가능.
- **권장**: 가능하면 Functions에서 “한 주차 비정기 일정 전체를 받아서” 한 트랜잭션으로 replace하는 API가 있으면, 클라이언트는 한 번만 호출하도록 변경 검토.

### 화면·네비게이션
- `_isSaving`, `_leaveRequested`, `_isLeaving`, `PopScope(canPop: !_isLeaving && !_isSaving)`, `_handleBackDuringSave()` 있음.
- 저장 성공 시 `_popOnce(true)`로 한 번만 pop 하도록 되어 있음.
- `finally`에서 `courseProvider.clearSavingOverrides`, `setState(() => _isSaving = false)` 수행 → 로딩 상태 해제는 잘 됨.
- **이슈**: 사용자가 “저장 중 나가기” 선택 시 `_leaveRequested = true`만 설정하고 pop 하는데, 백엔드 요청은 계속 진행됨. 완료 후 `mounted`일 때만 `_popOnce` 호출하므로, 이미 나간 뒤에는 중복 pop은 없음. 다만 **이미 나갔는데 저장이 완료되면** UI와 서버 상태가 어긋날 수 있음(사용자 기대: “취소했는데 저장됨”).

---

## 3. 정기 일정 저장/삭제 (`course_schedule_edit_screen.dart`) — 조사만, 수정 제외

### 백엔드
- **updateCourseSchedule** Cloud Function 한 번 호출로 정기 일정 전체 갱신.
- 서버에서 트랜잭션 처리 여부는 functions 코드 확인 필요. 클라이언트 관점에선 “한 번의 호출”로 원자적으로 보임.

### 화면·네비게이션
- `_isSaving`, `_leaveRequested`, `PopScope`, `_handleBackDuringSave` 있음.
- **finally**에서 `_isSaving = false` 설정함 → 로딩 중 나가기 후 상태 꼬임 방지 양호.
- 저장 성공 시 `Navigator.of(context).pop(true)` 한 번만 호출.

---

## 4. 스토리 추가 (`story_add_screen.dart`)

### 백엔드
- 스토리 문서 생성 등 개별 쓰기. 여러 문서를 쓴다면 원자성은 서버 설계에 따름.

### 화면·네비게이션
- `_isSaving`, `_leaveRequested`, `canPop: !_isSaving && !_isDeleting && !_hasChanges()`, 저장 중 나가기 확인 다이얼로그 있음.
- **이슈**: `_handleSave` 등에서 예외 시 `setState(() => _isSaving = false)`는 있으나, **전체 try/catch/finally**로 감싸서 **모든** 경로(성공/실패/나가기)에서 `_isSaving` 해제하는 구조가 있으면 더 안전함.

---

## 5. 멤버·수강 관련

### 멤버 코스 등록 (`member_course_enrollment_screen.dart`)
- `_isSaving`, `_leaveRequested`, `PopScope(canPop: false)` + `onPopInvoked`에서 `_onWillPop` → 저장 중이면 `_handleBackDuringSave()`.
- 나가기 시 `setState(() => _isSaving = false)` 후 pop.  
- **이슈**: 저장 중 나가기 선택 시 `_leaveRequested = true`만 하고 pop 하면, 백그라운드에서 저장이 계속 진행될 수 있음. 완료 시 `mounted` 체크 후 setState 등 하므로 크래시는 적을 수 있으나, “나갔는데 저장됨” 불일치 가능.

### 수강 상세·횟수/기간 조정 등 (`enrollment_detail_screen.dart`)
- `_isSaving`, `_isReenrolling`, `_isCancelling`, `_leaveRequested`, `PopScope(canPop: !isLoading)` 있음.
- **이슈**: 저장/재등록/취소 중 “나가기” 시 `Navigator.pop()`만 하고 `_isSaving` 등은 false로 안 돌림. 위젯이 pop 되어 dispose 되면 이후 setState는 no-op이므로, **finally**에서 한 번에 `_isSaving = false` 등으로 정리해 두는 편이 안전함.

### 멤버 일괄 등록 (`member_registration_screen.dart`)
- `_isSaving`, `_leaveRequested`, canPop 조건, 저장 중 나가기 확인 있음.
- 저장 플로우 내부에 `_leaveRequested` 체크 다수 있음.

---

## 6. 공통·로딩 중 나가기 요약

| 화면/기능 | canPop / 나가기 처리 | finally에서 로딩 해제 | _leaveRequested | 비고 |
|-----------|----------------------|------------------------|------------------|------|
| 플레이스 삭제 | ✅ canPop, 나가기 다이얼로그 | ❌ 없음 | ✅ | 성공 시 finally 추가 권장 |
| 비정기 일정 | ✅ canPop, 나가기 다이얼로그 | ✅ | ✅ | 백엔드 부분 저장 가능 |
| 정기 일정 (수정 제외) | ✅ | ✅ | ✅ | — |
| 스토리 추가 | ✅ | 부분적 | ✅ | 전 구간 finally 권장 |
| 멤버 코스 등록 | ✅ (PopScope false + onPopInvoked) | 부분적 | ✅ | 나가기 시 백그라운드 저장 계속 가능 |
| 수강 상세 | ✅ | 부분적 | ✅ | 나가기 시 플래그 해제 없음, finally 권장 |
| 플레이스 등록(admin_place_edit) | ✅ | ✅ (catch에서 해제) | ✅ | — |

---

## 7. 권장 조치 (우선순위)

1. **플레이스 삭제**  
   - `_handleDelete()`에 **finally** 추가: `if (mounted) setState(() => _isLoading = false);`  
   - (선택) 서버: deletePlace 성공 후 admin 업데이트까지 Function 내부에서 처리하면 더 일관적.

2. **비정기 일정**  
   - (서버) 한 주차 비정기 일정을 한 트랜잭션으로 replace하는 API 검토.  
   - (클라이언트) “저장 중 나가기” 시 이미 날아간 요청은 취소 불가이므로, 나가기 시 “저장 취소됨” 안내 또는 부분 저장 가능성 안내 고려.

3. **스토리 추가 / 수강 상세 / 멤버 코스 등록**  
   - 저장·취소·재등록 등 **긴 비동기 플로우**는 전부 **try/catch/finally**로 감싸고, **finally**에서 `_isSaving`(및 _isReenrolling, _isCancelling 등) 무조건 해제.  
   - 나가기 시 `_leaveRequested`만 설정하고 pop 하는 화면은 “나간 뒤 완료되면 어떻게 할지”(스낵바만 보여줄지, 아무것도 안 할지) 한 번 정리.

4. **공통**  
   - 로딩/저장 중에는 `PopScope(canPop: false)` 또는 `canPop: !_isLoading && !_isSaving` 유지.  
   - 네비게이션(pop, pushNamed 등)은 **mounted** 체크 후, 가능하면 **navigatorKey.currentContext**로 스낵바 등 표시해 dispose 후 호출 방지.

---

## 8. 적용 완료 (나가기 후 결과 알림)

- **플레이스 삭제**: `finally`에서 `_isLoading = false`, 성공/실패 시 `resultCtx = mounted ? context : navigatorKey.currentContext`로 스낵바 표시.
- **비정기 일정**: 저장 실패 시 `resultCtx`로 스낵바 (성공은 기존에 이미 navigatorKey 사용).
- **스토리 추가**: `navigator_key` import, 성공/실패 시 `resultCtx`로 스낵바, `finally`에서 `_isSaving = false`.
- **수강 상세**: 횟수 조정·기간 조정·대기 등록 성공/실패 시 `resultCtx`로 스낵바.
- **멤버 코스 등록**: 실패 시 `resultCtx`로 스낵바.

나가기한 뒤에도 백그라운드에서 완료/실패하면 **현재 보이는 화면**에 스낵바로 결과가 표시되도록 보완함.

---

## 9. 추가 조사·적용 (2차)

트랜잭션/로딩 해제가 필요해 보이는 **추가 구간**을 조사하고 아래처럼 적용함.

| 대상 | 이슈 | 적용 내용 |
|------|------|-----------|
| **스토리 추가 – 삭제** (`story_add_screen`) | 삭제 시 try/catch만 있고 finally 없음. 예외/early return 시 `_isDeleting`이 true로 남을 수 있음. | 삭제 콜백에 **finally** 추가: `if (mounted) setState(() => _isDeleting = false);` |
| **세션 상세 – 세션 취소** (`session_detail_screen`) | 세션 취소 시 try/catch만 있고 finally 없음. `_leaveRequested` 등 early return 시 `_isDeletingSession`이 true로 남을 수 있음. | 취소 플로우에 **finally** 추가: `if (mounted) setState(() => _isDeletingSession = false);` |
| **예약하기 바텀시트** (`user_reservation_manage_bottom_sheet`) | `_createReservation()` 호출에 try/finally 없음. 예외 시 `_isSubmitting`이 true로 남을 수 있음. | 예약하기 버튼 콜백을 **try/finally**로 감싸고, finally에서 `if (mounted) setState(() => _isSubmitting = false);` |

**백엔드·다단계 쓰기 (참고)**  
- **플레이스 등록** (`admin_place_edit`, greeting_massage_setting 등): `createPlace` / `createPlaceWithMember` 후 `updateAdmin`, `setPlaceMember` 등 여러 단계. 한 단계 실패 시 이전 단계는 이미 반영된 상태가 될 수 있음. 장기적으로는 “플레이스 생성 + 멤버 + admin 갱신”을 서버 한 트랜잭션(또는 단일 Function)으로 묶는 설계 검토 권장.
- **플레이스 삭제**: 동일하게 deletePlace 성공 후 updateAdmin 실패 시 불일치 가능. 문서 1번 참고.

---

*코스 수정(course_edit_screen)은 수정하지 않음. 정기 일정(course_schedule_edit_screen)은 조사만 반영.*
