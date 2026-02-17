# 슬라이딩 윈도우 시스템 점검

## 1. 개요

멤버 목록(places/{placeId}/members)을 30명 단위 세그먼트로 나누어, 화면에 보이는 구간만 Firestore 실시간 구독하는 구조.

| 항목 | 값 |
|------|-----|
| 세그먼트 크기 | 30명 |
| 디바운스 | 500ms |
| 정렬 | `__name__` (doc id) 기준 |

---

## 2. 데이터 구조

```
allMembers = cachedBefore + streamed + loadedAfter + pending
```

| 변수 | 설명 |
|------|------|
| `_cachedPlaceMembersBefore` | 현재 세그먼트 이전 구간(이미 지나쳐 온 세그먼트들). 스크롤 업 시 복원용 |
| `_streamedPlaceMembers` | 현재 세그먼트. Firestore `snapshots()` 구독 중 |
| `_loadedPlaceMembersAfter` | 무한 스크롤로 추가 로드한 이후 구간 (1회 fetch) |
| `_segmentBoundaryDocs` | 세그먼트별 `lastDoc` (다음 세그먼트 `startAfter`용) |

---

## 3. 흐름 점검

### 3.1 초기 로드 (setPlaceId)

1. `watchPlaceMembersSegment(placeId)` 호출 (startAfter=null, limit=30)
2. 첫 30명 구독, `_streamedPlaceMembers` 갱신
3. `_segmentBoundaryDocs[0]` = 마지막 doc

### 3.2 스크롤 다운 → 다음 세그먼트

1. `setVisibleRange(firstVisibleIndex)` → segmentIndex = floor(firstVisibleIndex / 30)
2. 500ms 디바운스 후 `_switchSegmentTo(newSegmentIndex)`
3. 현재 스트림 취소
4. `_streamedPlaceMembers` → `_cachedPlaceMembersBefore`에 추가
5. `_segmentBoundaryDocs[current]` 저장
6. `_loadedPlaceMembersAfter`에 30명 이상 있으면 → 그걸로 `_streamedPlaceMembers` 즉시 표시
7. 없으면 `_streamedPlaceMembers = []`, 스트림 시작 후 표시
8. `watchPlaceMembersSegment(placeId, startAfter: boundaryDocs[new-1])` 구독

### 3.3 스크롤 업 → 이전 세그먼트

1. `_cachedPlaceMembersBefore`에서 해당 세그먼트 추출
2. `sublist(newIndex * 30, (newIndex+1) * 30)` → `_streamedPlaceMembers`
3. cache는 `sublist(0, newIndex * 30)`로 축소
4. `watchPlaceMembersSegment` 구독 → 스트림이 emit되면 `_streamedPlaceMembers` 갱신(실시간 반영)

### 3.4 무한 스크롤 (loadMoreMembers)

1. `startAfter` = `_lastLoadedAfterDoc` 또는 `_streamedSegmentLastDoc` (loadedAfter 비었을 때)
2. `getPlaceMembersPage(placeId, startAfter, limit=100)` 1회 호출 (페이지 크기는 100 유지)
3. 결과를 `_loadedPlaceMembersAfter`에 append

---

## 4. 스크롤 → firstVisibleIndex 계산

| 위치 | 방식 |
|------|------|
| AdminMemberScreen (전체/코스별 탭) | `(scrollOffset / 64).floor()` |
| CourseMemberListContent | `(scrollOffset / 64).floor()` |

64px는 멤버 카드 예상 높이. 실제와 다르면 세그먼트 전환 시점이 어긋날 수 있음.

---

## 5. 잠재 이슈 및 트레이드오프

| 이슈 | 설명 | 판단 |
|------|------|------|
| 캐시된 세그먼트 실시간성 | 스크롤 업 시 캐시 사용 → 스트림 구독 전까지는 스냅샷 시점 데이터 | 스트림이 곧 emit되므로 수 초 이내 최신화 |
| firstVisibleIndex 추정 | scrollOffset/64로 추정, 필터/정렬과 raw 인덱스 불일치 | 근사치. 30명 단위 전환이므로 허용 |
| enrollments | members 슬라이딩 윈도우에 연동. 현재 로드된 멤버만 whereIn 구독 | ✅ 개선 완료 |

---

## 6. 2차 점검 (상세)

### 6.1 boundary 의존성

- `_switchSegmentTo(N)` 호출 시 `startAfter = _segmentBoundaryDocs[N-1]` (N>0)
- boundary는 해당 세그먼트를 지나올 때만 저장됨
- **결론**: 스크롤 범위가 리스트 길이로 제한되므로, 도달하지 않은 세그먼트로 점프 불가 → boundary 없음 문제 없음

### 6.2 loadMoreMembers startAfter

| 상황 | startAfter |
|------|------------|
| loadedAfter 비어 있음 | `_streamedSegmentLastDoc` 또는 `_segmentBoundaryDocs[current]` |
| loadedAfter 있음 | `_lastLoadedAfterDoc` |

loadedAfter에서 100명을 소비해도 `_lastLoadedAfterDoc`는 그대로 유효 (이미 로드한 페이지의 마지막 doc).

### 6.3 CourseMemberListContent

- filtered 리스트(코스 필터) 인덱스 ≠ raw 멤버 인덱스
- `firstVisibleIndex`는 filtered 기준 추정
- 코스별 보기에서는 보통 인원이 적어 segmentIndex가 0에 머무를 가능성이 높음 → 허용

### 6.4 doc.data().isEmpty 스킵

- `watchPlaceMembersSegment` / `getPlaceMembersPage`에서 빈 doc은 스킵
- `lastDoc`은 `snapshot.docs.last` 사용 → 빈 doc이 마지막이어도 pagination cursor로 사용 가능
- 반환 list 길이가 100 미만일 수 있음 (빈 doc 포함 시) → 정상 동작

---

## 7. 수정 이력 (2025-02)

- **segmentSize**: 200 → 100 → 30
- **스크롤 업 버그 수정**: 이전 로직은 캐시에서 항상 마지막 100명만 추출. 세그먼트 2→0 이동 시 세그먼트 1이 표시되던 문제 수정. `sublist(newIndex*100, (newIndex+1)*100)`로 해당 세그먼트만 추출하도록 변경.
- **캐시 부족 시**: `_streamedPlaceMembers = []`로 초기화하여 잘못된 세그먼트가 표시되지 않도록 처리.
- **segmentSize 30**: whereIn(30) 한 번에 enrollment 구독 가능. 비용 최소화.
- **enrollments 슬라이딩 윈도우 연동**: watchEnrollmentsForUserIds(placeId, userIds)로 현재 로드된 멤버에 한해 구독. 플레이스 전체 구독 제거.
