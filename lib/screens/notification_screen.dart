import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:reservation/utils/timezone_utils.dart';
import '../theme/app_colors.dart';
import '../models/notification.dart';
import '../providers/notification_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/member_provider.dart';
import '../providers/course_provider.dart';
import '../providers/enrollment_provider.dart';
import '../providers/place_provider.dart';
import '../screens/admin/widgets/enrollment_detail_screen.dart';
import '../widgets/common_dialog.dart';

/// 알림 스크린
class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshNotifications();
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels < pos.maxScrollExtent - 200) return;
    final provider = Provider.of<NotificationProvider>(context, listen: false);
    if (provider.hasMoreNotifications && !provider.isLoadingMore) {
      provider.loadMoreNotifications();
    }
  }

  Future<void> _refreshNotifications({bool clearExisting = true}) async {
    if (!mounted) return;
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final notificationProvider = Provider.of<NotificationProvider>(
      context,
      listen: false,
    );
    final user = authProvider.currentUser;
    final admin = authProvider.currentManagerUser;
    final currentPlace = placeProvider.currentPlace;

    if (user != null || admin != null) {
      final isAdmin = admin != null;
      final userId = isAdmin ? admin.userId : user!.userId;
      final placeId = currentPlace?.id;
      await notificationProvider.loadNotifications(
        userId,
        isAdmin: isAdmin,
        placeId: placeId,
        forceRefresh: true,
        clearExisting: clearExisting,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 알림 타입 의미: reservation=예약 완료/취소/변경, system=연장 요청·새 수업 일정 등
  Future<void> _handleNotificationTap(
    AppNotification notification,
    NotificationProvider provider,
  ) async {
    if (!notification.isRead) provider.markAsRead(notification.id);

    final data = notification.data;
    if (data == null) return;

    final enrollmentId = data['enrollmentId'] as String?;
    final userId = data['userId'] as String?;
    final courseId = data['courseId'] as String?;
    final placeId = data['placeId'] as String?;
    final dateStr =
        data['date'] as String? ?? data['reservedDateString'] as String?;
    final dayOfWeek = _parseInt(data['dayOfWeek']);
    final startTime = data['startTime'] as String?;

    switch (notification.type) {
      case NotificationType.system:
        if (enrollmentId != null &&
            userId != null &&
            courseId != null &&
            placeId != null) {
          await _navigateToEnrollmentDetail(
            enrollmentId: enrollmentId,
            userId: userId,
            courseId: courseId,
            placeId: placeId,
            initialTabIndex: 1,
          ).catchError(
            (e) => debugPrint('[NotificationScreen] enrollment 이동 오류: $e'),
          );
        } else if (courseId != null && placeId != null) {
          await _navigateToReservationWithHighlight(
            courseId: courseId,
            placeId: placeId,
            date: dateStr,
            dayOfWeek: dayOfWeek,
            startTime: startTime,
          );
        }
        break;
      case NotificationType.reservation:
        if (notification.title.contains('취소')) break;
        if (courseId == null &&
            placeId == null &&
            data['reservationId'] == null)
          break;
        final reservedDate =
            dateStr != null && dateStr.isNotEmpty
                ? DateTime.tryParse(dateStr)
                : null;
        await _navigateToMyPage(
          highlightReservation:
              reservedDate != null
                  ? {
                    'reservedDate': reservedDate,
                    'courseId': courseId,
                    'dayOfWeek': dayOfWeek,
                    'startTime': startTime,
                    'shouldShowBottomSheet': false,
                  }
                  : null,
        );
        break;
    }
  }

  static int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse('$v');
  }

  /// 예약 화면으로 이동 + 해당 주차·세션 강조 (새 수업 일정 알림용)
  Future<void> _navigateToReservationWithHighlight({
    required String courseId,
    required String placeId,
    String? date,
    int? dayOfWeek,
    String? startTime,
  }) async {
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/main',
        (route) => false,
        arguments: {
          'initialIndex': 1, // 예약 탭
          'highlightNewSession': {
            'courseId': courseId,
            'placeId': placeId,
            if (date != null) 'date': date,
            if (dayOfWeek != null) 'dayOfWeek': dayOfWeek,
            if (startTime != null) 'startTime': startTime,
          },
        },
      );
    }
  }

  /// 마이페이지(예약 목록)로 이동 (해당 주차까지 설정)
  Future<void> _navigateToMyPage({
    Map<String, dynamic>? highlightReservation,
  }) async {
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/main',
        (route) => false,
        arguments: {
          'initialIndex': 2, // 마이페이지 탭
          if (highlightReservation != null)
            'highlightReservation': highlightReservation,
        },
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
      memberProvider.setPlaceId(placeId);
      final member = memberProvider.getMemberView(userId);
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

      // EnrollmentDetailScreen으로 이동 (연장 탭으로)
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (context) => EnrollmentDetailScreen(
                  member: member,
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
        final hasLoadedOnce = notificationProvider.hasLoadedOnce;
        final error = notificationProvider.error;
        final unreadCount = notificationProvider.unreadCount;
        final authProvider = Provider.of<AuthProvider>(context, listen: false);
        final showContent = hasLoadedOnce && !isLoading;
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
            actions: [
              if (showContent && notifications.isNotEmpty)
                TextButton(
                  onPressed: () async {
                    final confirmed = await CommonDialog.show(
                      context: context,
                      title: '알림 모두 지우기',
                      message: '모든 알림을 삭제하시겠습니까?',
                      cancelText: '취소',
                      confirmText: '모두 지우기',
                      confirmButtonColor: const Color.fromARGB(
                        255,
                        255,
                        79,
                        67,
                      ),
                    );
                    if (confirmed == true) {
                      await notificationProvider.deleteAllNotifications();
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '모두 지우기',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary.withOpacity(0.8),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          body: _buildScrollBody(
            notifications,
            isLoading,
            hasLoadedOnce,
            notificationProvider.isLoadingMore,
            notificationProvider.hasMoreNotifications,
            error,
            notificationProvider,
          ),
        );
      },
    );
  }

  Widget _buildScrollBody(
    List<AppNotification> notifications,
    bool isLoading,
    bool hasLoadedOnce,
    bool isLoadingMore,
    bool hasMore,
    String? error,
    NotificationProvider provider,
  ) {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final hasUser = authProvider.currentUser != null;
    final showInitialLoading =
        !hasLoadedOnce || (isLoading && notifications.isEmpty);

    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        CupertinoSliverRefreshControl(
          onRefresh: () => _refreshNotifications(clearExisting: false),
        ),
        if (showInitialLoading)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CupertinoActivityIndicator(radius: 14)),
          )
        else if (notifications.isEmpty || !hasUser)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                '알림이 없습니다',
                style: TextStyle(
                  fontSize: 16,
                  color: AppColors.textSecondary.withOpacity(0.6),
                ),
              ),
            ),
          )
        else
          ..._buildNotificationSlivers(
            notifications: notifications,
            provider: provider,
            isLoadingMore: isLoadingMore,
            hasMore: hasMore,
          ),
      ],
    );
  }

  List<Widget> _buildNotificationSlivers({
    required List<AppNotification> notifications,
    required NotificationProvider provider,
    required bool isLoadingMore,
    required bool hasMore,
  }) {
    final todayStart = TimezoneUtils.getSeoulToday();
    final weekStart = todayStart.subtract(const Duration(days: 7));
    final monthStart = todayStart.subtract(const Duration(days: 30));

    final sections = <String, List<AppNotification>>{
      '오늘':
          notifications.where((n) => n.createdAt.isAfter(todayStart)).toList(),
      '이번 주':
          notifications
              .where(
                (n) =>
                    n.createdAt.isAfter(weekStart) &&
                    !n.createdAt.isAfter(todayStart),
              )
              .toList(),
      '최근 30일':
          notifications
              .where(
                (n) =>
                    n.createdAt.isAfter(monthStart) &&
                    !n.createdAt.isAfter(weekStart),
              )
              .toList(),
      '그 이전':
          notifications.where((n) => !n.createdAt.isAfter(monthStart)).toList(),
    };

    final slivers = <Widget>[
      const SliverPadding(padding: EdgeInsets.only(top: 8)),
    ];
    for (final entry in sections.entries) {
      if (entry.value.isEmpty) continue;
      slivers.add(SliverToBoxAdapter(child: _buildSectionHeader(entry.key)));
      slivers.add(
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) =>
                _buildNotificationItem(entry.value[index], provider),
            childCount: entry.value.length,
          ),
        ),
      );
    }
    if (isLoadingMore) {
      slivers.add(
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: CupertinoActivityIndicator(radius: 12),
            ),
          ),
        ),
      );
    } else if (!hasMore && notifications.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                '마지막 알림입니다',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary.withOpacity(0.5),
                ),
              ),
            ),
          ),
        ),
      );
    }
    slivers.add(const SliverPadding(padding: EdgeInsets.only(bottom: 8)));
    return slivers;
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

  Widget _buildNotificationIcon() {
    final color =
        notification.isRead
            ? AppColors.textSecondary.withOpacity(0.6)
            : Colors.white;
    if (notification.type == NotificationType.reservation) {
      return SvgPicture.asset(
        'assets/icons/calendar-icon.svg',
        width: 28,
        height: 28,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      );
    }
    return Icon(Icons.info_outline, size: 28, color: color);
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
                    child: Center(child: _buildNotificationIcon()),
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

    if (difference.inMinutes < 1) {
      return '방금';
    } else if (difference.inMinutes < 60) {
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
