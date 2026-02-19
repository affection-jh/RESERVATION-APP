/// 서버/네트워크 에러 메시지를 사용자 친화적인 한국어로 변환
class ErrorMessageUtil {
  /// raw 에러 문자열을 스낵바에 표시할 한국어 메시지로 변환
  /// 예: "The internet connection appears to be offline" → "인터넷 연결이 끊어졌습니다."
  static String toUserFriendlyMessage(String raw) {
    if (raw.isEmpty) return '오류가 발생했습니다. 잠시 후 다시 시도해주세요.';

    final lower = raw.toLowerCase();
    if (lower.contains('permission-denied') || lower.contains('permission_denied')) {
      return '권한이 없습니다.';
    }
    if (lower == 'internal' || lower.trim() == 'internal') {
      return '서버 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.';
    }
    final trimmed =
        raw.replaceFirst(RegExp(r'^Exception:\s*'), '').trim();

    // 인터넷/오프라인 관련 (서버·플랫폼에서 오는 영문 메시지)
    if (lower.contains('offline') ||
        (lower.contains('internet') && lower.contains('connection')) ||
        lower.contains('connection') && (lower.contains('appears') || lower.contains('lost')) ||
        lower.contains('network') && lower.contains('unreachable') ||
        lower.contains('socket') && lower.contains('exception') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('no internet') ||
        lower.contains('network_error')) {
      return '인터넷 연결이 끊어졌습니다. 연결을 확인해주세요.';
    }

    // 일반적인 네트워크·연결 관련
    if (lower.contains('network') || lower.contains('connection')) {
      return '네트워크 연결을 확인한 뒤 다시 시도해주세요.';
    }
    if (lower.contains('timeout')) {
      return '요청 시간이 초과되었습니다. 다시 시도해주세요.';
    }

    return trimmed.isNotEmpty ? trimmed : '오류가 발생했습니다. 잠시 후 다시 시도해주세요.';
  }
}
