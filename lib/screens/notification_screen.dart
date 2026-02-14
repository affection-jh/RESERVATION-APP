import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:reservation/utils/timezone_utils.dart';
import 'package:shimmer/shimmer.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../models/notification.dart';
import '../providers/notification_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/member_provider.dart';
import '../providers/course_provider.dart';
import '../providers/enrollment_provider.dart';
import '../providers/place_provider.dart';
import '../screens/admin/widgets/enrollment_detail_screen.dart';
import '../models/admin_models.dart';
import '../screens/story/story_detail_screen.dart';
import '../providers/story_provider.dart';

/// 알림 스크린
class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _hasLoaded = false;

  @override
  void initState() {
    super.initState();
    // 화면이 열릴 때 데이터가 없으면 로드
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadNotificationsIfNeeded();
    });
  }

  void _loadNotificationsIfNeeded() {
    if (_hasLoaded) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final notificationProvider = Provider.of<NotificationProvider>(
      context,
      listen: false,
    );

    // 알림이 없고 로딩 중이 아니면 로드
    if (notificationProvider.notifications.isEmpty &&
        !notificationProvider.isLoading) {
      final user = authProvider.currentUser;
      final admin = authProvider.currentAdmin;
      final currentPlace = placeProvider.currentPlace;

      if (user != null || admin != null) {
        _hasLoaded = true;

        // 관리자인지 일반 사용자인지 확인
        final isAdmin = admin != null;
        final userId = isAdmin ? admin.userId : user!.userId;
        final placeId = currentPlace?.id;

        notificationProvider.loadNotifications(
          userId,
          isAdmin: isAdmin,
          placeId: placeId,
        );
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _handleNotificationTap(
    AppNotification notification,
    NotificationProvider provider,
  ) async {
    // 읽지 않은 알림이면 읽음 처리
    if (!notification.isRead) {
      provider.markAsRead(notification.id);
    }

    // 알림 데이터 확인
    final data = notification.data;
    if (data == null) return;

    // 연장 요청 알림인지 확인 (enrollmentId, userId, courseId, placeId가 모두 있는 경우)
    final enrollmentId = data['enrollmentId'] as String?;
    final userId = data['userId'] as String?;
    final courseId = data['courseId'] as String?;
    final placeId = data['placeId'] as String?;

    // 알림 타입별 처리
    switch (notification.type) {
      case NotificationType.system:
        // 연장 요청 알림인 경우 enrollment 상세 화면으로 이동
        if (enrollmentId != null &&
            userId != null &&
            courseId != null &&
            placeId != null) {
          try {
            // 연장 요청: 탭 1
            final initialTabIndex = 1;

            await _navigateToEnrollmentDetail(
              enrollmentId: enrollmentId,
              userId: userId,
              courseId: courseId,
              placeId: placeId,
              initialTabIndex: initialTabIndex,
            );
          } catch (e) {
            debugPrint('[NotificationScreen] enrollment 상세 화면 이동 오류: $e');
          }
        }
        break;

      case NotificationType.story:
        // 스토리 알림인 경우 스토리 상세 화면으로 이동
        final storyId = data['storyId'] as String?;
        final storyPlaceId = data['placeId'] as String?;
        if (storyId != null && storyPlaceId != null) {
          try {
            await _navigateToStoryDetail(
              storyId: storyId,
              placeId: storyPlaceId,
            );
          } catch (e) {
            debugPrint('[NotificationScreen] 스토리 상세 화면 이동 오류: $e');
          }
        }
        break;

      case NotificationType.promotion:
        // 프로모션 알림인 경우 홈 화면으로 이동
        final promotionPlaceId = data['placeId'] as String?;
        if (promotionPlaceId != null) {
          try {
            await _navigateToHome();
          } catch (e) {
            debugPrint('[NotificationScreen] 홈 화면 이동 오류: $e');
          }
        }
        break;

      case NotificationType.reservation:
        // 예약 알림은 현재 특별한 처리 없음 (알림 화면에 머무름)
        break;
    }
  }

  /// 스토리 상세 화면으로 이동
  Future<void> _navigateToStoryDetail({
    required String storyId,
    required String placeId,
  }) async {
    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final storyProvider = Provider.of<StoryProvider>(context, listen: false);

      // 현재 플레이스 확인
      final currentPlace = placeProvider.currentPlace;
      if (currentPlace?.id != placeId) {
        debugPrint(
          '[NotificationScreen] 플레이스 불일치: current=${currentPlace?.id}, required=$placeId',
        );
        return;
      }

      // 스토리 목록 로드
      await storyProvider.loadStories(placeId);
      final story = storyProvider.stories.firstWhere(
        (s) => s.id == storyId,
        orElse: () => throw Exception('Story not found'),
      );

      // StoryDetailScreen으로 이동
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (context) =>
                    StoryDetailScreen(story: story, place: currentPlace),
          ),
        );
      }
    } catch (e) {
      debugPrint('[NotificationScreen] 스토리 상세 화면 이동 오류: $e');
      rethrow;
    }
  }

  /// 홈 화면으로 이동
  Future<void> _navigateToHome() async {
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/main',
        (route) => false,
        arguments: {'initialIndex': 0}, // 홈 탭
      );
    }
  }

  /// Enrollment 상세 화면으로 이동
  Future<void> _navigateToEnrollmentDetail({
    required String enrollmentId,
    required String userId,
    required String courseId,
    required String placeId,
    int initialTabIndex = 1, // 기본값: 연장 탭 (1)
  }) async {
    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final enrollmentProvider = Provider.of<EnrollmentProvider>(
        context,
        listen: false,
      );

      // 현재 플레이스 확인
      final currentPlace = placeProvider.currentPlace;
      if (currentPlace?.id != placeId) {
        debugPrint(
          '[NotificationScreen] 플레이스 불일치: current=${currentPlace?.id}, required=$placeId',
        );
        // 플레이스를 변경하거나 오류 메시지 표시
        return;
      }

      // 멤버 조회
      await memberProvider.loadMembers(placeId);
      final member = memberProvider.getMember(userId);
      if (member == null) {
        debugPrint('[NotificationScreen] 멤버를 찾을 수 없습니다: $userId');
        return;
      }

      // 코스 조회
      await courseProvider.loadCourses(placeId);
      final course = courseProvider.courses.firstWhere(
        (c) => c.id == courseId,
        orElse: () => courseProvider.courses.first,
      );

      // Enrollment 조회
      await enrollmentProvider.loadUserEnrollments(
        userId: userId,
        placeId: placeId,
      );
      final enrollment = enrollmentProvider.enrollments.firstWhere(
        (e) => e.id == enrollmentId,
        orElse: () => throw Exception('Enrollment not found'),
      );

      // MemberData 생성
      final memberData = MemberData(
        userId: member.userId,
        name: member.name,
        phoneNumber: member.phoneNumber,
        role: 'user', // 관리자 여부는 adminUsers 등 별도 소스에서 조회
        isActive: true,
        pendingExtensionRequests: member.pendingExtensionRequests.length,
        enrolledCourseIds: member.enrollments.map((e) => e.courseId).toList(),
      );

      // EnrollmentDetailScreen으로 이동 (연장 탭으로)
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (context) => EnrollmentDetailScreen(
                  member: memberData,
                  enrollment: enrollment,
                  course: course,
                ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[NotificationScreen] enrollment 상세 화면 이동 오류: $e');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        final notifications = notificationProvider.notifications;
        final isLoading = notificationProvider.isLoading;
        final error = notificationProvider.error;
        final unreadCount = notificationProvider.unreadCount;
        final authProvider = Provider.of<AuthProvider>(context, listen: false);
        return Scaffold(
          backgroundColor: AppColors.backgroundLight,
          appBar: AppBar(
            scrolledUnderElevation: 0,
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: Icon(
                Icons.arrow_back_ios_new_rounded,
                color: AppColors.textPrimary,
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
            centerTitle: false,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '알림',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (unreadCount > 0 && authProvider.currentUser != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color.fromARGB(255, 255, 79, 67),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$unreadCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            actions: [],
          ),
          body: RefreshIndicator(
            onRefresh: () async {
              // 새로고침은 하지 않음 (FCM으로 자동 갱신)
            },
            child: _buildBody(
              notifications,
              isLoading,
              error,
              notificationProvider,
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(
    List<AppNotification> notifications,
    bool isLoading,
    String? error,
    NotificationProvider provider,
  ) {
    // Provider에서 이미 플레이스와 역할로 필터링되었으므로 중복 필터링 제거
    final filteredNotifications = notifications;
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    if (isLoading && filteredNotifications.isEmpty) {
      return _buildShimmerLoading();
    }

    // 오류가 발생해도 자세한 오류 메시지는 표시하지 않고 빈 화면으로 처리
    if (filteredNotifications.isEmpty || authProvider.currentUser == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '알림이 없습니다',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.textSecondary.withOpacity(0.6),
              ),
            ),
          ],
        ),
      );
    }

    // 날짜별로 그룹화 (동적)
    final todayStart = TimezoneUtils.getSeoulToday();
    final weekStart = todayStart.subtract(const Duration(days: 7));
    final monthStart = todayStart.subtract(const Duration(days: 30));

    // 오늘 알림
    final todayNotifications =
        filteredNotifications
            .where((n) => n.createdAt.isAfter(todayStart))
            .toList();

    // 이번 주 알림 (오늘 제외)
    final weekNotifications =
        filteredNotifications
            .where(
              (n) =>
                  n.createdAt.isAfter(weekStart) &&
                  !n.createdAt.isAfter(todayStart),
            )
            .toList();

    // 이번 달 알림 (이번 주 제외)
    final monthNotifications =
        filteredNotifications
            .where(
              (n) =>
                  n.createdAt.isAfter(monthStart) &&
                  !n.createdAt.isAfter(weekStart),
            )
            .toList();

    // 그 이전 알림
    final earlierNotifications =
        filteredNotifications
            .where((n) => !n.createdAt.isAfter(monthStart))
            .toList();

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (todayNotifications.isNotEmpty) ...[
          _buildSectionHeader('오늘'),
          ...todayNotifications.map(
            (notification) => _buildNotificationItem(notification, provider),
          ),
        ],
        if (weekNotifications.isNotEmpty) ...[
          _buildSectionHeader('이번 주'),
          ...weekNotifications.map(
            (notification) => _buildNotificationItem(notification, provider),
          ),
        ],
        if (monthNotifications.isNotEmpty) ...[
          _buildSectionHeader('이번 달'),
          ...monthNotifications.map(
            (notification) => _buildNotificationItem(notification, provider),
          ),
        ],
        if (earlierNotifications.isNotEmpty) ...[
          _buildSectionHeader('그 이전'),
          ...earlierNotifications.map(
            (notification) => _buildNotificationItem(notification, provider),
          ),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }

  Widget _buildShimmerLoading() {
    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _buildSectionHeader('오늘'),
        ...List.generate(5, (index) => _buildShimmerNotificationCard(index)),
      ],
    );
  }

  Widget _buildShimmerNotificationCard(int index) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 프로필 아바타 쉬머
          Stack(
            clipBehavior: Clip.none,
            children: [
              Shimmer.fromColors(
                baseColor: AppColors.textSecondary.withOpacity(0.1),
                highlightColor: AppColors.textSecondary.withOpacity(0.1),
                period: const Duration(milliseconds: 1200),
                child: Container(
                  width: 65,
                  height: 65,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          // 알림 내용 쉬머
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 제목 쉬머 (2줄)
                Shimmer.fromColors(
                  baseColor: AppColors.textSecondary.withOpacity(0.1),
                  highlightColor: AppColors.textSecondary.withOpacity(0.1),
                  period: const Duration(milliseconds: 1200),
                  child: Container(
                    width: double.infinity,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Shimmer.fromColors(
                  baseColor: AppColors.textSecondary.withOpacity(0.1),
                  highlightColor: AppColors.textSecondary.withOpacity(0.1),
                  period: const Duration(milliseconds: 1200),
                  child: Container(
                    width: 200,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // 타임스탬프 쉬머
                Shimmer.fromColors(
                  baseColor: AppColors.textSecondary.withOpacity(0.1),
                  highlightColor: AppColors.textSecondary.withOpacity(0.1),
                  period: const Duration(milliseconds: 1200),
                  child: Container(
                    width: 80,
                    height: 14,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationItem(
    AppNotification notification,
    NotificationProvider provider,
  ) {
    return _DismissibleNotificationItem(
      notification: notification,
      onDismissed: () => provider.deleteNotification(notification.id),
      onTap: () => _handleNotificationTap(notification, provider),
    );
  }
}

/// 스와이프 가능한 알림 아이템
class _DismissibleNotificationItem extends StatefulWidget {
  final AppNotification notification;
  final VoidCallback onDismissed;
  final VoidCallback onTap;

  const _DismissibleNotificationItem({
    required this.notification,
    required this.onDismissed,
    required this.onTap,
  });

  @override
  State<_DismissibleNotificationItem> createState() =>
      _DismissibleNotificationItemState();
}

class _DismissibleNotificationItemState
    extends State<_DismissibleNotificationItem> {
  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key(widget.notification.id),
      direction: DismissDirection.endToStart,
      onDismissed: (direction) {
        widget.onDismissed();
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: Colors.transparent,
        child: Container(
          width: 48,
          height: 48,
          decoration: const BoxDecoration(shape: BoxShape.circle),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 3.0),
            child: Center(
              child: SvgPicture.asset(
                'assets/icons/delete.svg',
                width: 28,
                height: 28,
                colorFilter: const ColorFilter.mode(
                  Color.fromARGB(255, 255, 79, 67),
                  BlendMode.srcIn,
                ),
              ),
            ),
          ),
        ),
      ),
      child: _NotificationTile(
        notification: widget.notification,
        onTap: widget.onTap,
      ),
    );
  }
}

/// 알림 타일 위젯
class _NotificationTile extends StatelessWidget {
  final AppNotification notification;
  final VoidCallback onTap;

  const _NotificationTile({required this.notification, required this.onTap});

  IconData _getNotificationIcon() {
    switch (notification.type) {
      case NotificationType.reservation:
        return Icons.calendar_today_outlined;
      case NotificationType.story:
        return Icons.article_outlined;
      case NotificationType.promotion:
        return Icons.local_offer_outlined;
      case NotificationType.system:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 읽은 알림은 덜 선명하게 표시 (opacity 0.6)
    final opacity = notification.isRead ? 0.8 : 1.0;

    return Opacity(
      opacity: opacity,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Colors.transparent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 프로필 아바타
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 65,
                    height: 65,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          notification.isRead
                              ? AppColors.backgroundLight
                              : AppColors.primaryGreen,
                    ),
                    child: Icon(
                      _getNotificationIcon(),
                      size: 28,
                      color:
                          notification.isRead
                              ? AppColors.textSecondary.withOpacity(0.6)
                              : Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              // 알림 내용
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notification.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight:
                            notification.isRead
                                ? FontWeight.w400
                                : FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (notification.body.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        notification.body,
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary.withOpacity(0.8),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      _formatTime(notification.createdAt),
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary.withOpacity(0.5),
                      ),
                    ),
                  ],
                ),
              ),
              // 읽지 않은 알림 표시
              if (!notification.isRead)
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(left: 8, top: 4),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color.fromARGB(255, 255, 79, 67),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dateTime) {
    final now = TimezoneUtils.getSeoulDateTime();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 60) {
      return '${difference.inMinutes}분 전';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}시간 전';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}일 전';
    } else {
      return '${dateTime.month}/${dateTime.day}';
    }
  }
}
