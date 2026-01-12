import '../models/admin_models.dart';

/// 멤버 관련 유틸리티 함수
class MemberUtils {
  /// userId가 pending 멤버인지 확인
  static bool isPendingMember(String userId) {
    return userId.startsWith('pending_');
  }

  /// MemberData가 pending 멤버인지 확인
  static bool isPendingMemberData(MemberData member) {
    return isPendingMember(member.userId);
  }
}
