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

  /// 비교/저장용 전화번호 정규화 (11자리 숫자, 82→0, 앞에 0 보정)
  static String normalizePhoneForCompare(String phoneNumber) {
    var digits = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.startsWith('82')) {
      digits = '0${digits.substring(2)}';
    }
    if (digits.isNotEmpty && !digits.startsWith('0')) {
      digits = '0$digits';
    }
    return digits;
  }

  /// 입력 중 표시용 포맷 (빈 값이면 "010", 그 외 010-1234-5678)
  static String formatPhoneInput(String digitsOnly) {
    if (digitsOnly.isEmpty) return '010';
    if (digitsOnly.length <= 3) return digitsOnly;
    if (digitsOnly.length <= 7) {
      return '${digitsOnly.substring(0, 3)}-${digitsOnly.substring(3)}';
    }
    if (digitsOnly.length <= 11) {
      return '${digitsOnly.substring(0, 3)}-${digitsOnly.substring(3, 7)}-${digitsOnly.substring(7)}';
    }
    return '${digitsOnly.substring(0, 3)}-${digitsOnly.substring(3, 7)}-${digitsOnly.substring(7, 11)}';
  }
}
