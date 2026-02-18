# 저장 시 네트워크 확인 패턴

Firestore 쓰기 전 네트워크 도달 가능 여부를 확인하고, 불가 시 저장을 차단하는 방식.

## 전략

- **리버트/Guard 미사용**: 저장 단계에서 네트워크 확인 후 불가하면 스낵바로 안내하고 저장을 막음.  
  따라서 Provider의 revert 상태·복원 로직은 사용하지 않음.
- **네트워크 확인**: `FirestoreUtils.canReachFirestoreForSave(probeCollection, probeDocId, timeout)`  
  저장 직전에 호출하여, 실패 시 `"네트워크 연결을 확인해주세요. "` 스낵바 표시 후 `return`.

## 적용 위치

| 영역 | 화면/위젯 | 비고 |
|------|-----------|------|
| Enrollments | enrollment_detail_screen | 남은 횟수/기간, 재등록, 취소, pending 처리 등 |
| Courses | course_edit_screen | 저장, 삭제(cascade 여부) |
| Places | admin_place_edit_screen, place_delete_confirm_screen | 업데이트, 삭제 |
| Capacity override | session_detail_screen, compact_calendar_widget | setCapacityOverride |
| 세션 취소/삭제 | session_detail_screen, compact_calendar_widget | upsertCourseOverride |
| 주간 override | weekly_override_schedule_screen | 저장 전 canReachFirestoreForSave 후 차단 |

## 주의사항

- 저장하기 직전에만 `canReachFirestoreForSave` 호출.  
  통과한 뒤의 쓰기 실패(타임아웃 등)는 별도 예외 처리.
- 오프라인에서 사용자가 저장을 눌 수 없도록 막는 것이 목적이므로,  
  Firestore 캐시·pending write 덮어쓰기나 Provider revert는 사용하지 않음.
