# 시간대(Timezone) 처리 가이드

## ⚠️ 문제점

Firestore의 Timestamp는 **항상 UTC**로 저장됩니다. 하지만:
- 클라이언트(Flutter)는 사용자의 로컬 시간대 사용
- Cloud Functions도 기본적으로 UTC 기준
- 서울 시간대(KST, UTC+9)와 UTC는 9시간 차이

**예시 문제:**
- 한국 시간: 2024-01-15 23:30
- UTC 시간: 2024-01-15 14:30
- 날짜 비교 시 잘못된 결과 가능

---

## ✅ 해결 방법

### 1. 날짜는 항상 "YYYY-MM-DD" 문자열로 저장

**이유:**
- 시간대와 무관하게 날짜만 비교 가능
- 문자열 비교로 간단하고 안전

**현재 구현:**
```dart
// Flutter (클라이언트)
final dateString = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
```

```typescript
// Cloud Functions (서버)
const dateString = formatDateToSeoul(timestamp); // 서울 시간대 기준
```

### 2. Cloud Functions에서 서울 시간대 사용

**개선된 코드:**
```typescript
// 서울 시간대 기준 날짜 문자열 반환
function formatDateToSeoul(date: Date): string {
  const seoulDate = new Date(date.toLocaleString('en-US', { timeZone: 'Asia/Seoul' }));
  return formatDate(seoulDate);
}

// Firestore Timestamp를 서울 시간대로 변환
function formatTimestampToSeoulDate(timestamp: admin.firestore.Timestamp): string {
  const date = timestamp.toDate();
  return formatDateToSeoul(date);
}
```

### 3. 날짜 비교는 항상 날짜만 비교

**Flutter (클라이언트):**
```dart
// ✅ 올바른 방법: 날짜만 비교
final today = DateTime(now.year, now.month, now.day);
final reservationDate = DateTime(
  reservation.reservedDate.year,
  reservation.reservedDate.month,
  reservation.reservedDate.day,
);
final isToday = reservationDate == today;
```

**Cloud Functions:**
```typescript
// ✅ 올바른 방법: 날짜 문자열 비교
const seoulNow = new Date(new Date().toLocaleString('en-US', { timeZone: 'Asia/Seoul' }));
const todayString = formatDate(seoulNow);
const isToday = dateString === todayString;
```

---

## 📋 주요 변경사항

### Cloud Functions (`functions/src/index.ts`)

1. **서울 시간대 변환 함수 추가**
   - `formatDateToSeoul()` - Date를 서울 시간대로 변환
   - `formatTimestampToSeoulDate()` - Firestore Timestamp를 서울 시간대로 변환
   - `getSeoulDateString()` - 현재 서울 시간 기준 날짜 문자열

2. **예약 생성/삭제 시 날짜 처리**
   - `reservedDateString` 우선 사용
   - 없으면 Timestamp를 서울 시간대로 변환

3. **유효 기간 체크 시 서울 시간 사용**
   - `onEnrollmentUpdated`에서 서울 시간 기준으로 체크

4. **데이터 검증 시 서울 시간 사용**
   - `validateDataConsistency`에서 서울 시간 기준으로 7일 전 계산

---

## 🔍 검증 방법

### 테스트 시나리오

1. **자정 근처 예약**
   - 한국 시간: 2024-01-15 23:30에 예약 생성
   - UTC 시간: 2024-01-15 14:30
   - **기대 결과**: `reservedDateString`이 "2024-01-15"로 저장되어야 함

2. **날짜 경계 테스트**
   - 한국 시간: 2024-01-16 00:30 (다음날 새벽)
   - UTC 시간: 2024-01-15 15:30 (전날)
   - **기대 결과**: "2024-01-16"으로 올바르게 처리

3. **과거 날짜 예약 불가 검증**
   - 한국 시간 기준으로 "오늘" 판단
   - UTC 기준이 아닌 서울 시간 기준으로 체크

---

## ⚠️ 주의사항

### 1. 클라이언트에서 날짜 생성 시

```dart
// ✅ 올바른 방법: 로컬 시간 기준으로 날짜 문자열 생성
final date = DateTime.now();
final dateString = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

// ❌ 잘못된 방법: UTC 기준으로 변환하면 안 됨
final utcDate = date.toUtc(); // 사용하지 말 것!
```

### 2. Firestore에 저장 시

```dart
// ✅ 올바른 방법: reservedDateString과 reservedDate 모두 저장
await firestore.collection('reservations').add({
  'reservedDateString': dateString, // "YYYY-MM-DD" 형식
  'reservedDate': Timestamp.fromDate(date), // UTC Timestamp (백업용)
  // ...
});
```

### 3. 날짜 비교 시

```dart
// ✅ 올바른 방법: 날짜만 비교 (시간 제거)
final today = DateTime(now.year, now.month, now.day);
final reservationDate = DateTime(
  reservation.reservedDate.year,
  reservation.reservedDate.month,
  reservation.reservedDate.day,
);

// ❌ 잘못된 방법: 전체 DateTime 비교하면 시간대 문제 발생
final isToday = reservation.reservedDate == now; // 사용하지 말 것!
```

---

## 🎯 핵심 원칙

1. **날짜는 항상 문자열로 저장**: "YYYY-MM-DD" 형식
2. **서울 시간대 기준으로 처리**: Cloud Functions에서 변환
3. **날짜 비교는 날짜만 비교**: 시간 제거 후 비교
4. **UTC Timestamp는 백업용**: 주로 `reservedDateString` 사용

---

## 📊 시간대 변환 예시

| 한국 시간 (KST) | UTC 시간 | 날짜 문자열 |
|----------------|----------|------------|
| 2024-01-15 23:30 | 2024-01-15 14:30 | "2024-01-15" |
| 2024-01-16 00:30 | 2024-01-15 15:30 | "2024-01-16" |
| 2024-01-16 08:00 | 2024-01-15 23:00 | "2024-01-16" |

**결론**: 항상 한국 시간 기준으로 날짜 문자열을 생성하고 사용해야 합니다.

