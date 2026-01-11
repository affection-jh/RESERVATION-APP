/// 세션 초안 데이터 모델
class SessionDraft {
  final String startTime;
  final String endTime;
  final int capacity;

  SessionDraft({
    required this.startTime,
    required this.endTime,
    required this.capacity,
  });
}
