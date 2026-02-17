# 코스 배열 → 서브컬렉션 + 정책 embed 마이그레이션

## 개요

- **기존:** `places/{placeId}` 문서 안에 `courses: [...]` 배열 필드, 정책은 `coursePolicies/{courseId}` 별도 컬렉션
- **변경:**
  - 코스: `places/{placeId}/courses/{courseId}` 서브컬렉션으로 분리
  - 정책: 코스 문서 내 `policy` 필드로 embed (버전 없이 단일 정책)

## 실행 순서

### 1. 마이그레이션 스크립트 실행 (데이터 이전)

```bash
cd functions

# 드라이런 (실제 쓰기 없이 로그만)
npx ts-node scripts/migrate-courses-to-subcollection.ts

# 실제 반영
npx ts-node scripts/migrate-courses-to-subcollection.ts --execute
```

- 모든 place 문서의 `courses` 배열을 읽어, 각 코스를 `places/{placeId}/courses/{courseId}` 문서로 저장
- 각 코스에 대해 `coursePolicies/{courseId}` 를 읽어 **유효 정책(active/scheduled 중 적용중)** 을 골라 코스 문서에 `policy` 필드로 병합
- `--execute` 시 해당 place 문서에서 `courses` 필드 제거

정책 필드 형식 (코스 문서 내 `policy`):
- `closeBeforeMinutes`: number
- `allowAdminForceMoveWithinCourse`: boolean
- `openStrategy`: { type, rollingWindow?, weeklyRelease? }

### 2. Rules 배포

```bash
firebase deploy --only firestore:rules
```

- `places/{placeId}/courses/{courseId}` 규칙이 이미 코드에 반영되어 있음

### 3. Functions 배포

```bash
cd functions && npm run build && firebase deploy --only functions
```

### 4. 앱 배포

- Flutter 앱 빌드·배포 (이미 서브컬렉션 읽기/쓰기로 코드 반영됨)

## 롤백

- 마이그레이션 전 place 문서를 백업해 두었다면, `courses` 필드를 복구하고 서브컬렉션 코드를 이전 버전으로 되돌리면 됨
- **실행 전** 반드시 드라이런으로 처리할 place/코스 수 확인 권장
