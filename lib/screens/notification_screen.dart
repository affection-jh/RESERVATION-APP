import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shimmer/shimmer.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../models/notification.dart';
import '../providers/notification_provider.dart';
import '../providers/auth_provider.dart';

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
    final notificationProvider = Provider.of<NotificationProvider>(
      context,
      listen: false,
    );

    // 알림이 없고 로딩 중이 아니면 로드
    if (notificationProvider.notifications.isEmpty &&
        !notificationProvider.isLoading) {
      final user = authProvider.currentUser;
      if (user != null) {
        _hasLoaded = true;
        notificationProvider.loadNotifications(user.userId, isAdmin: false);
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _handleNotificationTap(
    AppNotification notification,
    NotificationProvider provider,
  ) {
    // 읽지 않은 알림이면 읽음 처리
    if (!notification.isRead) {
      provider.markAsRead(notification.id);
    }
    // TODO: 알림 타입에 따라 상세 화면으로 이동
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        final notifications = notificationProvider.notifications;
        final isLoading = notificationProvider.isLoading;
        final error = notificationProvider.error;
        final unreadCount = notificationProvider.unreadCount;

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
                if (unreadCount > 0) ...[
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
    if (isLoading && notifications.isEmpty) {
      return _buildShimmerLoading();
    }

    // 오류가 발생해도 자세한 오류 메시지는 표시하지 않고 빈 화면으로 처리
    if (notifications.isEmpty) {
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
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final weekStart = todayStart.subtract(const Duration(days: 7));
    final monthStart = todayStart.subtract(const Duration(days: 30));

    // 오늘 알림
    final todayNotifications = notifications
        .where((n) => n.createdAt.isAfter(todayStart))
        .toList();

    // 이번 주 알림 (오늘 제외)
    final weekNotifications = notifications
        .where(
          (n) =>
              n.createdAt.isAfter(weekStart) &&
              !n.createdAt.isAfter(todayStart),
        )
        .toList();

    // 이번 달 알림 (이번 주 제외)
    final monthNotifications = notifications
        .where(
          (n) =>
              n.createdAt.isAfter(monthStart) &&
              !n.createdAt.isAfter(weekStart),
        )
        .toList();

    // 그 이전 알림
    final earlierNotifications = notifications
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
  double _swipeProgress = 0.0;

  @override
  Widget build(BuildContext context) {
    // 스와이프 진행도를 곡선 함수로 변환 (초반에 빠르게 진해지도록)
    // sqrt를 사용하여 초반에 빠르게 변하고, 나중에는 천천히
    final curvedProgress = _swipeProgress < 0.0
        ? 0.0
        : (_swipeProgress * _swipeProgress * _swipeProgress); // 세제곱으로 더 빠르게

    // 스와이프 진행도에 따라 색상 진하기 조절 (0.0 ~ 1.0)
    // 초반에 빠르게 진해지도록 더 높은 계수 사용
    final opacity = (0.05 + curvedProgress * 0.5).clamp(0.05, 0.55);
    final gradientOpacity = (0.02 + curvedProgress * 0.3).clamp(0.02, 0.32);

    return Dismissible(
      key: Key(widget.notification.id),
      direction: DismissDirection.endToStart,
      onUpdate: (details) {
        // 스와이프 진행도 계산 (0.0 ~ 1.0)
        final progress = (details.progress).clamp(0.0, 1.0);
        setState(() {
          _swipeProgress = progress;
        });
      },
      onDismissed: (direction) {
        widget.onDismissed();
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
            colors: [
              const Color.fromARGB(255, 255, 79, 67).withOpacity(opacity),
              const Color.fromARGB(
                255,
                255,
                79,
                67,
              ).withOpacity(gradientOpacity),
              Colors.transparent,
            ],
          ),
        ),
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
                      color: notification.isRead
                          ? AppColors.backgroundLight
                          : AppColors.primaryGreen,
                    ),
                    child: Icon(
                      _getNotificationIcon(),
                      size: 28,
                      color: notification.isRead
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
                        fontWeight: notification.isRead
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
    final now = DateTime.now();
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
