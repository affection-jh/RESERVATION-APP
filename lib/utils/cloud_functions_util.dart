/// Cloud Functions 호출 결과(result.data)를 [Map<String, dynamic>]으로 안전 변환.
/// 반환 타입이 _Map<Object?, Object?>일 때 직접 캐스트 시 런타임 에러가 나므로 사용.
Map<String, dynamic>? ensureCallableResultMap(dynamic data) {
  if (data == null) return null;
  if (data is! Map) return null;
  return Map<String, dynamic>.from(data);
}
