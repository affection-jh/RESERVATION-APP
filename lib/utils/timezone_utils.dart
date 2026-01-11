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
    final now = DateTime.now().toUtc();
    // UTC에 9시간(540분) 추가
    return now.add(const Duration(hours: 9));
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

  /// 날짜와 시간 문자열("HH:mm")을 결합하여 서울 시간대 DateTime 생성
  ///
  /// 서버의 makeSeoulDateTime()과 유사한 로직입니다.
  static DateTime combineDateAndTimeSeoul(DateTime date, String hhmm) {
    final parts = hhmm.split(':');
    final h = int.parse(parts[0]);
    final m = int.parse(parts[1]);

    // 날짜를 UTC로 변환 후 서울 시간대 적용
    final dateUtc = DateTime.utc(date.year, date.month, date.day);
    final seoulBase = dateUtc.add(const Duration(hours: 9));

    // 시간 추가 (서울 시간대 기준)
    return DateTime(seoulBase.year, seoulBase.month, seoulBase.day, h, m);
  }
}
