/// 포맷팅 관련 유틸리티 함수들
class FormatUtils {
  /// 전화번호를 한국 형식으로 포맷팅
  /// 
  /// 예시:
  /// - "01012345678" -> "010-1234-5678"
  /// - "0101234" -> "010-1234"
  /// - "010" -> "010"
  static String formatPhoneNumber(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length <= 3) {
      return digits;
    } else if (digits.length <= 7) {
      return '${digits.substring(0, 3)}-${digits.substring(3)}';
    } else if (digits.length <= 11) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7)}';
    } else {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7, 11)}';
    }
  }
}



