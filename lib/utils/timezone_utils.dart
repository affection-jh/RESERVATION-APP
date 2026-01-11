/// 시간대 처리 유틸리티
///
/// 서버와 클라이언트 간 시간대 일관성을 보장하기 위한 유틸리티 함수들
/// 서버에서는 getSeoulDateTime()을 사용하고, 클라이언트에서도 동일한 로직을 사용하여
/// 정책 엔진의 일관성을 보장합니다.
class TimezoneUtils {
  /// 서울 시간대(UTC+9) 기준 현재 시간 반환
  ///
  /// 서버의 getSeoulDateTime()과 동일한 로직을 사용합니다.
  /// UTC 시간에 9시간을 더하여 서울 시간대를 계산합니다.
  static DateTime getSeoulDateTime() {
    final nowUtc = DateTime.now().toUtc();
    final seoulUtcShifted = nowUtc.add(const Duration(hours: 9));

    // ⚠️ 중요:
    // - `toUtc()+9h`의 결과는 "서울 시각을 담고 있지만 isUtc=true" 인 DateTime이 된다.
    // - 이 값을 로컬(DateTime(...))과 비교하면 9시간 오차로 '이미 지남/마감' 등이 오판될 수 있다.
    // 따라서 서울 시각을 **로컬 DateTime(isUtc=false)** 로 재구성해서 반환한다.
    return DateTime(
      seoulUtcShifted.year,
      seoulUtcShifted.month,
      seoulUtcShifted.day,
      seoulUtcShifted.hour,
      seoulUtcShifted.minute,
      seoulUtcShifted.second,
      seoulUtcShifted.millisecond,
      seoulUtcShifted.microsecond,
    );
  }

  /// 날짜를 서울 시간대 기준으로 "YYYY-MM-DD" 형식 문자열로 변환
  ///
  /// 서버의 formatDateToSeoul()과 동일한 로직을 사용합니다.
  static String formatDateToSeoul(DateTime date) {
    final seoul = date.toUtc().add(const Duration(hours: 9));
    return '${seoul.year}-${seoul.month.toString().padLeft(2, '0')}-${seoul.day.toString().padLeft(2, '0')}';
  }

  /// 서울 시간대 기준 오늘 날짜만 반환 (시간 제거)
  static DateTime getSeoulToday() {
    final seoul = getSeoulDateTime();
    return DateTime(seoul.year, seoul.month, seoul.day);
  }

  /// 주어진 DateTime을 서울 시간대 기준으로 날짜만 추출 (시간 제거)
  ///
  /// 서버의 seoulDateOnly()와 유사한 로직입니다.
  static DateTime getSeoulDateOnly(DateTime date) {
    // date가 이미 "서울 시각을 로컬 DateTime으로 재구성한 값"일 수 있으므로
    // isUtc 여부에 따라 처리 분기한다.
    if (!date.isUtc) {
      return DateTime(date.year, date.month, date.day);
    }

    final seoul = date.toUtc().add(const Duration(hours: 9));
    return DateTime(seoul.year, seoul.month, seoul.day);
  }

  /// 날짜와 시간 문자열("HH:mm")을 결합하여 서울 시간대 DateTime 생성
  ///
  /// 서버의 makeSeoulDateTime()과 유사한 로직입니다.
  static DateTime combineDateAndTimeSeoul(DateTime date, String hhmm) {
    final parts = hhmm.split(':');
    final h = int.parse(parts[0]);
    final m = int.parse(parts[1]);

    // date는 "서울 날짜"로 들어오는 것을 전제로 한다.
    // (UTC DateTime으로 들어오면 날짜가 UTC 기준으로 해석될 수 있으므로,
    //  날짜 성분만 안전하게 추출)
    final dateOnly = getSeoulDateOnly(date);
    return DateTime(dateOnly.year, dateOnly.month, dateOnly.day, h, m);
  }
}
