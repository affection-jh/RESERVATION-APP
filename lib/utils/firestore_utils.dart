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

  /// 실패한 쓰기의 **로컬 캐시·펜딩 큐를 원래 값으로 덮어씁니다.**
  ///
  /// Firestore에는 "큐에서 단일 pending write 제거" API가 없습니다. 대신 **같은 문서에
  /// 이전 값으로 다시 쓰면**, 로컬 캐시와 펜딩 큐에 그 값이 들어가고, 나중에 동기화될 때
  /// 실패했던 쓰기 위에 적용되어 **관리자가 "적용 안 됐다"고 본 상태가 서버에도 유지**됩니다.
  ///
  /// - 리버트 시 호출: Provider 복원 + 이 메서드로 문서 덮어쓰기
  /// - [ref]: 덮어쓸 문서 참조 (예: enrollments/docId)
  /// - [data]: 원래 값의 Map (Firestore 직렬화 형태, DateTime → Timestamp 변환된 상태)
  /// - await 하지 않아도 됨: 로컬에만 반영해 큐에 넣는 것이 목적
  static Future<void> overwritePendingWrite(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> data,
  ) async {
    await ref.set(data, SetOptions(merge: true));
  }

  /// 리버트(생성 취소) 시 펜딩 큐에 삭제를 넣어, 실패한 set 위에 적용되도록 합니다.
  /// (예: capacity override 신규 생성 실패 시 해당 문서 제거)
  static Future<void> deletePendingWrite(
    DocumentReference<Map<String, dynamic>> ref,
  ) async {
    await ref.delete();
  }

  /// 저장 전 네트워크 확인. **서버**에 연결 가능하면 true, 불가면 false.
  /// 캐시만 있으면 false (오프라인에서 저장 막기 위해 Source.server 사용).
  /// false일 때 호출측에서 스낵바("네트워크 연결을 확인해주세요. ") 띄우고 return.
  /// [probeCollection], [probeDocId]: 확인용 문서 (예: places / placeId). 반드시 존재할 수 있는 문서를 넘기면 됨.
  static Future<bool> canReachFirestoreForSave({
    required String probeCollection,
    required String probeDocId,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    try {
      await FirebaseFirestore.instance
          .collection(probeCollection)
          .doc(probeDocId)
          .get(const GetOptions(source: Source.server))
          .timeout(timeout);
      return true;
    } catch (_) {
      return false;
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
