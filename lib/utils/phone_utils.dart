/// 전화번호 공통 유틸
class PhoneUtils {
  PhoneUtils._();

  /// 한국 번호 정규화 (+82 → 0, 국가코드 제거)
  static String normalize(String phoneNumber) {
    if (phoneNumber.startsWith('+82')) {
      return '0${phoneNumber.substring(3)}';
    }
    if (phoneNumber.startsWith('+')) {
      return phoneNumber.substring(phoneNumber.length - 10);
    }
    return phoneNumber;
  }

  /// pendingMembers/서버 쿼리용: 숫자만 추출 후 0 선두 (010xxxxxxxx)
  /// registerMemberByAdmin·createEnrollmentsFromPendingMembers와 동일 형식
  static String normalizeForStorage(String phoneNumber) {
    final digits = phoneNumber.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('82') && digits.length >= 11) {
      return '0${digits.substring(2)}';
    }
    if (digits.startsWith('0')) {
      return digits;
    }
    return '0$digits';
  }
}
