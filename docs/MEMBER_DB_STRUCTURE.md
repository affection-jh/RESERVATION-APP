# 멤버 통합관리 시스템 DB 구조

## 핵심 컬렉션

| 경로 | 용도 | 역할 판별 |
|------|------|-----------|
| `places/{placeId}/members/{uid}` | 플레이스 소속 멤버 (역할·권한) | role: manager \| submanager \| member |
| `places/{placeId}/pendingMembers/{inviteId}` | 가입 전 초대 상태 | inviteId = `{placeId}_{전화번호}` |
| `enrollments` | 코스별 수강 등록 (횟수·기간) | userId, placeId, courseId |
| `reservations` (top-level) | 예약 | userId, placeId, courseId, reservedDateString |

---

## 역할 (PlaceMemberRole)

| role | 설명 | 권한 |
|------|------|------|
| manager | 매니저 | 플레이스 전체 관리 |
| submanager | 부매니저 | manageableCourseIds 범위만 관리 |
| member | 일반 | 예약/수강만 |

---

## 멤버 생명주기

```
[초대] pendingMembers 문서 생성 (phoneNumber, role, allowedCourseIds)
       ↓
[가입] users 생성 + enrollments 생성 + pendingMembers 삭제
       ↓
[멤버화] places/{placeId}/members/{uid} 생성 (역할 등록)
```

---

## 주요 관계

- **멤버 ↔ 수강**: `enrollments` (userId + placeId + courseId)
- **멤버 ↔ 예약**: `reservations` (userId, placeId)
- **초대 ↔ 멤버**: pendingMembers.phoneNumber → users.phoneNumber 매칭 후 enrollments 생성

---

## 레거시/병행

| 컬렉션 | 상태 |
|--------|------|
| adminUsers | 관리자 권한 (일부 Functions만 사용, places/members와 병행) |
| placeMemberships | 미사용 (rules: deny all) |
