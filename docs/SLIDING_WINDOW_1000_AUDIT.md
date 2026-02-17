# 슬라이딩 윈도우 1000명 안정성·성능 점검

## 1. 1000명 시나리오 요약

| 구분 | 1000명 플레이스 기준 | 상태 |
|------|----------------------|------|
| 세그먼트 수 | 34개 (0~33) | ✅ |
| 세그먼트당 멤버 | 30명 | ✅ |
| 세그먼트당 reads | 30 (members) | ✅ |
| 세그먼트당 enrollment reads | ~60 (30 userIds × ~2 enrollments/인) | ✅ |

---

## 2. 비용 (1000명 기준)

### 초기 로드 (segment 0)

- **members**: 30 docs (실시간 구독)
- **enrollments**: 30 userIds → ~60 docs (실시간 구독)
- **pending**: limit 100, 실시간 구독

### 스크롤 (예: 0 → 5 → 10)

- 세그먼트 변경 시: 기존 구독 취소 → 새 세그먼트 구독
- 동시 구독: members 1개 + enrollments 1개 (최대 2개 Firestore 리스너)

### 메모리

- **cached**: 최대 990명 (segment 33에서)
- **streamed**: 30명
- **loadedAfter**: 100~200명 (loadMore)
- **합계**: ~1200 PlaceMember 객체 ≈ 300~600KB

---

## 3. 점검 항목

### 3.1 enrollment userIds 우선순위 (수정 완료)

**문제**: userIds를 cached+streamed+loaded 순으로 모으면, 30명 초과 시 앞쪽(cached) 30명만 enrollment 구독 → 현재 화면(streamed)에 enrollment 미표시

**해결**: **streamed(현재 세그먼트) 우선** → cached → loaded 순으로 30명 선택

### 3.2 구독 해제

- `setPlaceId(null)` 또는 `clear()`: 모든 스트림 취소
- `_switchSegmentTo`: 기존 members 구독 취소 후 새 구독
- `_refreshEnrollmentsSubscription`: 기존 enrollments 구독 취소 후 새 구독 (userIds 변경 시만)

### 3.3 boundary 의존성

- segment N 구독 시 `startAfter = _segmentBoundaryDocs[N-1]`
- boundary는 해당 세그먼트를 지나갈 때만 저장
- 스크롤 가능 범위 = 리스트 길이로 제한 → boundary 없음 상황 없음

### 3.4 pending 전체 구독

- `watchPendingMembersByPlace(placeId, limit: 100)`
- 1000명 플레이스에서 대기 멤버는 보통 소수 → 100 제한으로 충분

---

## 4. 잠재 이슈

| 이슈 | 영향 | 판단 |
|------|------|------|
| firstVisibleIndex 추정 오차 | scrollOffset/64 사용, 실제 아이템 높이와 다를 수 있음 | 30명 단위 전환이라 허용 |
| 필터/정렬과 raw 인덱스 불일치 | 코스별 탭에서 segmentIndex가 부정확할 수 있음 | 코스별은 인원 적어 segment 0 유지 가능성 높음 |
| 캐시 990명 메모리 | segment 33에서 cached 990명 | 기기당 300~600KB 수준, 수용 가능 |

---

## 5. 결론

- **1000명 플레이스에서 안정적**  
  - 세그먼트 단위 구독, 해제 처리, boundary 의존성 모두 정상
- **비용**  
  - members + enrollments 합산 ~90 docs/세그먼트 수준
- **개선 사항**  
  - enrollment userIds에 **streamed 우선** 적용으로 현재 화면 enrollment 누락 방지
