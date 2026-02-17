import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Firestore 공통 헬퍼
class FirestoreUtils {
  FirestoreUtils._();

  /// Firestore 쓰기 작업이 **서버에 반영(ack)** 될 때까지 대기합니다.
  ///
  /// Firestore는 오프라인 상태에서도 write가 로컬에 먼저 반영되며 `set/update/delete`가
  /// "성공"처럼 완료될 수 있습니다. 관리자 기능에서는 서버 반영이 확인된 뒤에만
  /// 성공 처리(UI/스낵바/pop)를 하도록, 필요한 곳에서 이 메서드를 호출합니다.
  ///
  /// - 온라인: 대개 빠르게 완료
  /// - 오프라인/불안정: timeout 후 예외 발생 (호출측에서 실패로 처리)
  static Future<void> waitForServerAck({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      await FirebaseFirestore.instance.waitForPendingWrites().timeout(timeout);
    } on TimeoutException {
      // ErrorMessageUtil에서 offline 문구를 한국어로 변환하기 쉽도록 원문 유지
      throw Exception('The internet connection appears to be offline');
    }
  }

  /// 날짜를 "YYYY-MM-DD" 형식으로 변환
  static String formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// Timestamp를 DateTime으로 변환
  static DateTime timestampToDateTime(dynamic timestamp) {
    if (timestamp == null) return DateTime.now();
    if (timestamp is Timestamp) return timestamp.toDate();
    if (timestamp is String) return DateTime.parse(timestamp);
    throw Exception('Invalid timestamp format');
  }

  /// DateTime을 Timestamp로 변환
  static Timestamp dateTimeToTimestamp(DateTime dateTime) {
    return Timestamp.fromDate(dateTime);
  }

  /// null/다른 타입 → ''
  static String ensureString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    return value.toString();
  }

  /// null이면 null, 아니면 문자열로
  static String? ensureStringOrNull(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
  }
}
