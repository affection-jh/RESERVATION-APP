import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../models/admin_models.dart';
import '../../../models/user.dart';
import '../../../models/pending_member.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/place_provider.dart';
import 'admin_shared_widgets.dart';

// ===== 공유 헬퍼 (admin_member_screen 코스별 보기와 동일) =====

String _normalizePhone(String phone) {
  return phone.replaceAll(RegExp(r'[^\d]'), '');
}

/// 관리자 화면 표시 이름: placeMemberships.displayName 우선, 없으면 pending 동일 전화번호 이름, 없으면 user.name
String getAdminDisplayNameForUser(
  User user,
  List<PendingMember> pendingMembers,
  Map<String, String> membershipDisplayNamesByUserId,
) {
  final membershipName = membershipDisplayNamesByUserId[user.userId];
  if (membershipName != null && membershipName.trim().isNotEmpty) {
    return membershipName;
  }
  final normalized = _normalizePhone(user.phoneNumber);
  for (final p in pendingMembers) {
    if (_normalizePhone(p.phoneNumber) == normalized) {
      return p.name ?? user.name;
    }
  }
  return user.name;
}

MemberData userToMemberData(User user, {String? displayName}) {
  return MemberData(
    userId: user.userId,
    name: displayName ?? user.name,
    phoneNumber: user.phoneNumber,
    role: '일반',
    isActive: true,
    pendingExtensionRequests: 0,
    enrolledCourseIds: [],
  );
}

MemberData pendingMemberToMemberData(PendingMember pendingMember) {
  return MemberData(
    userId: 'pending_${pendingMember.id}',
    name: pendingMember.name ?? '이름 없음',
    phoneNumber: pendingMember.phoneNumber,
    role: '대기중',
    isActive: false,
    pendingExtensionRequests: 0,
    enrolledCourseIds: pendingMember.derivedCourseIds,
  );
}

List<User> filterMembersBySearch(List<User> members, String searchQuery) {
  if (searchQuery.isEmpty) return members;
  final query = searchQuery.toLowerCase();
  return members.where((user) {
    return user.name.toLowerCase().contains(query) ||
        user.phoneNumber.toLowerCase().contains(query);
  }).toList();
}

// ===== 코스별 멤버 리스트 (enrollments + pendingMembers 동일 소스·동일 UI) =====

/// 코스별 보기와 코스 상세에서 공통 사용. 동일한 데이터(enrollment + pending) + 동일한 표시 방식.
class CourseMemberListContent extends StatelessWidget {
  /// 로그에서 호출 위치 구분용 (예: 'AdminMember', 'CourseDetail')
  final String logLabel;
  final String courseId;
  final String? placeId;
  final String searchQuery;
  final String emptyMessage;
  final bool showEmptyCta;
  final VoidCallback? onMemberTapped;
  final EdgeInsets? listPadding;

  /// true: SingleChildScrollView 안에서 사용(코스 상세). false: Expanded 안에서 스크롤(코스별 탭).
  final bool shrinkWrap;

  /// 코스 상세용: 헤더 "멤버(N명)" + 추가 버튼 표시
  final bool showHeaderWithCount;
  final String Function(int count)? headerTitleBuilder;
  final VoidCallback? onAddTap;

  /// 멤버 카드 배경색 (미지정 시 MemberCard 기본값 사용)
  final Color? cardBackgroundColor;

  const CourseMemberListContent({
    super.key,
    this.logLabel = 'CourseMemberListContent',
    required this.courseId,
    this.placeId,
    this.searchQuery = '',
    this.emptyMessage = '등록된 멤버가 없어요.',
    this.showEmptyCta = false,
    this.onMemberTapped,
    this.listPadding,
    this.shrinkWrap = false,
    this.showHeaderWithCount = false,
    this.headerTitleBuilder,
    this.onAddTap,
    this.cardBackgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer2<MemberProvider, PlaceProvider>(
      builder: (context, memberProvider, placeProvider, child) {
        final effectivePlaceId = placeId ?? placeProvider.currentPlace?.id;
        if (kDebugMode) {
          debugPrint(
            '[$logLabel] courseId=$courseId placeId=$effectivePlaceId '
            'passedPlaceId=$placeId',
          );
        }
        return StreamBuilder<List<User>>(
          stream: memberProvider.watchCourseMembers(
            courseId,
            placeId: effectivePlaceId,
          ),
          builder: (context, snapshot) {
            // Stream 첫 프레임(hasData=false)에서도 캐시된 enrolled 멤버를 먼저 보여줘서
            // 코스 전환/복귀 시 "pending만 잠깐 보이는" 깜빡임을 방지.
            final cached = memberProvider.getCourseMembers(
              courseId,
              placeId: effectivePlaceId,
            );
            final courseMembers = snapshot.hasData ? snapshot.data! : cached;
            if (kDebugMode && snapshot.hasData) {
              final pendingCount =
                  effectivePlaceId != null
                      ? memberProvider.pendingMembers
                          .where((pm) => pm.derivedCourseIds.contains(courseId))
                          .length
                      : 0;
              debugPrint(
                '[$logLabel] courseId=$courseId '
                'enrolled=${courseMembers.length} pending=$pendingCount',
              );
            }

            if (snapshot.hasError) {
              return Center(
                child: Text(
                  '오류가 발생했습니다: ${snapshot.error}',
                  style: TextStyle(
                    color: AppColors.textSecondary.withOpacity(0.8),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            }

            // pendingMembers도 placeId까지 일치하는 것만 포함 (서로 다른 place 데이터 섞임 방지)
            final pendingMembers =
                effectivePlaceId != null
                    ? memberProvider.pendingMembers
                        .where(
                          (pm) =>
                              pm.placeId == effectivePlaceId &&
                              pm.derivedCourseIds.contains(courseId),
                        )
                        .toList()
                    : <PendingMember>[];

            final pendingAsUsers =
                pendingMembers.map((pm) {
                  return User(
                    userId: 'pending_${pm.id}',
                    name: pm.name ?? '이름 없음',
                    phoneNumber: pm.phoneNumber,
                    placeIds: [pm.placeId],
                    enrollments: const [],
                    notificationsEnabled: false,
                    createdAt: pm.createdAt,
                    updatedAt: null,
                  );
                }).toList();

            final allMembers = [...courseMembers, ...pendingAsUsers];
            final filteredMembers = filterMembersBySearch(
              allMembers,
              searchQuery,
            );
            final totalCount = allMembers.length;
            if (kDebugMode && snapshot.hasData) {
              final summary = filteredMembers
                  .map((u) => '${u.userId}|${u.name}|${u.phoneNumber}')
                  .take(10)
                  .join(' , ');
              debugPrint(
                '[$logLabel] renderMembers(count=${filteredMembers.length}): $summary',
              );
            }

            if (filteredMembers.isEmpty) {
              final emptyContent = Padding(
                padding:
                    listPadding ?? const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 18),
                      child: Text(
                        emptyMessage,
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              );
              if (showHeaderWithCount) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(context, totalCount),
                    const SizedBox(height: 16),
                    emptyContent,
                  ],
                );
              }
              return emptyContent;
            }

            final listContent = ListView.builder(
              padding:
                  listPadding ??
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              shrinkWrap: shrinkWrap,
              physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
              itemCount: filteredMembers.length,
              itemBuilder: (context, index) {
                final member = filteredMembers[index];
                final isPending = member.userId.startsWith('pending_');
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: MemberCard(
                    backgroundColor: cardBackgroundColor,
                    member:
                        isPending
                            ? pendingMemberToMemberData(
                              pendingMembers.firstWhere(
                                (pm) => 'pending_${pm.id}' == member.userId,
                              ),
                            )
                            : userToMemberData(
                              member,
                              displayName: getAdminDisplayNameForUser(
                                member,
                                pendingMembers,
                                memberProvider.membershipDisplayNamesByUserId,
                              ),
                            ),
                    onMemberTapped: onMemberTapped ?? () {},
                  ),
                );
              },
            );

            if (showHeaderWithCount) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(context, totalCount),
                  const SizedBox(height: 16),
                  listContent,
                ],
              );
            }
            return listContent;
          },
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, int totalCount) {
    final title =
        headerTitleBuilder != null
            ? headerTitleBuilder!(totalCount)
            : '멤버($totalCount명)';
    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        const Spacer(),
        if (onAddTap != null)
          GestureDetector(
            onTap: onAddTap,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Icon(
                Icons.add_circle,
                color: AppColors.primaryGreen,
                size: 30,
              ),
            ),
          ),
      ],
    );
  }
}
