# 플레이스 전체 매니저 복수 명 구조 확장 (adminId → adminIds)

현재 `places` 문서에 `adminId`(단일 문자열)가 있으며, 이를 `adminIds`(문자열 배열)로 확장할 때 수정해야 할 위치 정리.

---

## 1. 데이터 구조

| 구분 | 현재 | 변경 후 |
|------|------|----------|
| Firestore `places` | `adminId: string` | `adminIds: string[]` |
| 호환 | — | 기존 문서: `adminId`만 있으면 `adminIds = [adminId]`로 읽기 |

---

## 2. 수정 대상 (파일별)

### Flutter (Dart)

| 파일 | 변경 내용 |
|------|-----------|
| **lib/models/place.dart** | `adminId` → `adminIds` (getter `adminId`는 `adminIds.isNotEmpty ? adminIds.first : ''` 호환용 유지 가능). `fromJson`: `adminIds` 없으면 `json['adminId']`로 `[adminId]` 생성. `toJson`: `adminIds` 저장. |
| **lib/services/place_firestore_service.dart** | `getManagedPlaceIdsByAdminId`: 쿼리를 `.where('adminIds', arrayContains: adminId)` 로 변경. `searchPlaces` 응답 파싱 시 `adminIds` 처리 (없으면 `adminId`로 배열 생성). |
| **lib/screens/admin/widgets/member_detail_bottom_sheet.dart** | `place.adminId == widget.member.userId` → `place.adminIds.contains(widget.member.userId)` (전체 매니저 여부). |
| **lib/providers/auth_provider.dart** | (변경 없음 – `getManagedPlaceIdsByAdminId` 결과만 사용하므로, 서비스/함수만 배열 쿼리로 바꾸면 됨) |
| **lib/providers/place_provider.dart** | `createPlace` 등에서 place 생성 시 `adminIds` 전달 여부 확인 (현재는 Function 호출이라 Function 쪽 수정이 핵심). |

### Firebase Functions (TypeScript)

| 파일 | 변경 내용 |
|------|-----------|
| **functions/src/admin_auth.ts** | `getPlaceIdsWhereUserMustDeletePlaceFirst`: `where('adminId', '==', uid)` 제거하고 `where('adminIds', 'array-contains', uid)` 로 조회. |
| **functions/src/index.ts** | ① **createPlaceWithMember**: place 문서에 `adminIds: [adminId]` 저장 (기존 `adminId` 제거 또는 호환용 유지). ② **중복 체크**: `where('adminIds', 'array-contains', adminId)` 후 동일 이름 검사. ③ **removeMember**: `placeData.adminIds` 배열에 `targetUserId` 있으면 소유자로 제거 불가. ④ **searchPlaces** 응답: 각 place에 `adminIds` 포함 (또는 `adminId` 호환). ⑤ **listMyPlaces** 등 place 반환 시 `adminIds` 포함. ⑥ **place_1771454304126** 등 단일 place 읽는 곳: `placeAdminId` 대신 `placeData.adminIds` 배열 사용. |

### Firestore Rules

| 파일 | 변경 내용 |
|------|-----------|
| **firestore.rules** | `isPlaceOwner(placeId)`: `get(...).data.adminId == request.auth.uid` → `request.auth.uid in get(...).data.adminIds`. (배열 필드가 없는 구 문서는 `adminId`만 체크하는 식으로 호환 가능). place **create** 규칙: `request.resource.data.adminIds`에 `request.auth.uid` 포함 여부로 검사. |

### Firestore 인덱스

- `places` 컬렉션에서 `adminIds` 배열에 대한 **array-contains** 쿼리만 쓰면 단일 필드 인덱스로 동작 (복합이면 콘솔에서 인덱스 생성).

---

## 3. 변경량 요약

| 영역 | 파일 수 | 비고 |
|------|---------|------|
| Dart 모델/서비스/UI | 약 3~4개 | Place 모델, place_firestore_service, member_detail_bottom_sheet 등 |
| Functions | 2개 | admin_auth.ts, index.ts (createPlace/removeMember/searchPlaces/중복 체크 등) |
| Rules | 1개 | isPlaceOwner, place create |
| **합계** | **약 6~7개** | 새 API/화면 없이 기존 필드 확장 중심 |

---

## 4. 권장 순서

1. **Functions**: `adminIds` 배열 저장/조회로 변경 (createPlaceWithMember, admin_auth, removeMember, searchPlaces 등).
2. **Firestore rules**: `isPlaceOwner`를 `adminIds` 배열 기준으로 수정.
3. **Flutter**: Place 모델 `adminIds` + fromJson 호환, place_firestore_service 쿼리, member_detail_bottom_sheet 조건.
4. **기존 데이터**: 기존 `adminId`만 있는 문서는 Functions/클라이언트에서 읽을 때 `adminIds ?? [adminId]` 로 처리하거나, 일회성 마이그레이션 스크립트로 `adminIds` 필드 채우기.

이 순서로 적용하면 “플레이스 전체 매니저도 여러 명”으로 확장할 수 있고, 변경 지점이 위 목록으로 제한됩니다.
