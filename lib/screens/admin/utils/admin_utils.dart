// ===== 유틸리티 =====

String newId(String prefix) {
  return '${prefix}_${DateTime.now().microsecondsSinceEpoch}';
}
