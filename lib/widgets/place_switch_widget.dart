import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../models/place.dart';
import '../providers/place_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/course_provider.dart';
import '../providers/reservation_provider.dart';
import '../providers/enrollment_provider.dart';
import '../providers/story_provider.dart';
import '../providers/member_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/admin_provider.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../utils/snackbar_util.dart';
import '../widgets/cached_image_widget.dart' show PlaceImageWidget;

/// 플레이스 정보 및 전환 위젯 (공통)
class PlaceSwitchWidget extends StatefulWidget {
  /// 패딩을 커스터마이징할 수 있음
  final EdgeInsets? padding;

  /// 스위처 활성화 여부 (true: 활성, false: 비활성)
  /// 일반 홈/관리자 홈: false, 마이페이지: true
  final bool enabled;

  /// 설명 표시 여부 (AdminPlaceSelector 호환성)
  final bool showDescription;

  /// 알림 아이콘 표시 여부 (홈 화면에서 사용)
  final bool showNotificationIcon;

  const PlaceSwitchWidget({
    super.key,
    this.padding,
    this.enabled = true,
    this.showDescription = false,
    this.showNotificationIcon = false,
  });

  @override
  State<PlaceSwitchWidget> createState() => _PlaceSwitchWidgetState();
}

class _PlaceAccessEntry {
  final String placeId;
  final bool isAdmin;

  const _PlaceAccessEntry({required this.placeId, required this.isAdmin});
}

class _PlaceSwitchWidgetState extends State<PlaceSwitchWidget> {
  bool _isExpanded = false;
  bool _isSwitching = false;

  Future<void> _resetAllProvidersForSwitch(BuildContext context) async {
    // ✅ 전환 플로우 표준화:
    // - 모든 place 의존 Provider를 비우고
    // - AppStartupScreen(스플래시)로 스택을 리셋하여
    //   "스플래시 → 데이터 로드 → 홈" 흐름으로 통일한다.
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    final storyProvider = Provider.of<StoryProvider>(context, listen: false);

    final notificationProvider = Provider.of<NotificationProvider>(
      context,
      listen: false,
    );
    final adminProvider = Provider.of<AdminProvider>(context, listen: false);

    // 현재 플레이스 제거
    placeProvider.clearPlace();

    // 모든 데이터/구독 초기화
    courseProvider.clear();
    storyProvider.clear();
    notificationProvider.clear();
    adminProvider.clearAdmin();
    await memberProvider.clear();
    await reservationProvider.clear();
    await enrollmentProvider.clear();
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final placeProvider = Provider.of<PlaceProvider>(context);

    final currentPlace = placeProvider.currentPlace;

    // 플레이스가 없으면 빈 섹션 표시
    if (currentPlace == null) {
      return const SizedBox.shrink();
    }

    // ✅ 플레이스 목록 구성 (멤버/관리자를 "독립 엔트리"로 유지)
    // 같은 placeId라도 (멤버, 관리자) 2개로 노출되어야 하므로 Set으로 합치지 않는다.
    final memberPlaceIds = authProvider.approvedPlaceIds;
    final adminPlaceIds = authProvider.adminManagedPlaceIds;

    debugPrint(
      '[PlaceSwitchWidget] 멤버 승인 플레이스 ID: $memberPlaceIds (개수: ${memberPlaceIds.length})',
    );
    debugPrint(
      '[PlaceSwitchWidget] 관리자 관리 플레이스 ID: $adminPlaceIds (개수: ${adminPlaceIds.length})',
    );

    final accessEntries = <_PlaceAccessEntry>[
      ...memberPlaceIds.map(
        (id) => _PlaceAccessEntry(placeId: id, isAdmin: false),
      ),
      ...adminPlaceIds.map(
        (id) => _PlaceAccessEntry(placeId: id, isAdmin: true),
      ),
    ];

    final uniquePlaceIds = accessEntries.map((e) => e.placeId).toSet().toList();

    debugPrint(
      '[PlaceSwitchWidget] accessEntries: ${accessEntries.map((e) => "${e.placeId}:${e.isAdmin ? "admin" : "member"}").toList()} (개수: ${accessEntries.length})',
    );
    debugPrint(
      '[PlaceSwitchWidget] hasMultiplePlaces: ${accessEntries.length > 1}, enabled: ${widget.enabled}',
    );

    final hasMultiplePlaces = accessEntries.length > 1;
    final currentPlaceId = currentPlace.id;
    final canSwitch = widget.enabled && hasMultiplePlaces;

    return Padding(
      padding: EdgeInsets.only(top: 10, bottom: 10, left: 20, right: 10),
      child: Column(
        children: [
          // 플레이스 정보 (클릭 가능)
          InkWell(
            onTap: canSwitch
                ? () {
                    setState(() {
                      _isExpanded = !_isExpanded;
                    });
                  }
                : null,
            borderRadius: BorderRadius.circular(16),
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            child: Row(
              children: [
                // 플레이스 이미지
                PlaceImageWidget(
                  imageUrl: currentPlace.imageUrl,
                  width: 50,
                  height: 50,
                  borderRadius: BorderRadius.circular(16),
                ),
                const SizedBox(width: 16),
                // 플레이스 이름
                Expanded(
                  child: Builder(
                    builder: (context) {
                      // description이 있는지 확인
                      final descriptionText = widget.showDescription
                          ? (currentPlace.description ??
                                    currentPlace.location ??
                                    '')
                                .trim()
                          : '';
                      final hasDescription = descriptionText.isNotEmpty;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            currentPlace.name,
                            style: TextStyle(
                              // showDescription이 true이고 description이 없을 때는 크게 (20)
                              // showDescription이 true이고 description이 있을 때는 중간 (18)
                              // showDescription이 false일 때는 작게 (16)
                              fontSize: widget.showDescription
                                  ? (hasDescription ? 18 : 20)
                                  : 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.5,
                            ),
                          ),
                          // showDescription이 true이고 description이 있을 때만 표시
                          if (widget.showDescription && hasDescription) ...[
                            Text(
                              descriptionText,
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),

                // 토글 모드일 때만 화살표 표시
                if (widget.enabled && hasMultiplePlaces)
                  Icon(
                    _isExpanded
                        ? Icons
                              .keyboard_arrow_up // 펼쳐졌을 때: 위로 닫기 화살표
                        : Icons.keyboard_arrow_down, // 접혔을 때: 아래로 펼치기 화살표
                    color: AppColors.textSecondary,
                    size: 28,
                  ),
              ],
            ),
          ),

          // 플레이스 리스트 (펼쳐질 때)
          if (canSwitch)
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: _isExpanded
                  ? Column(
                      children: [
                        const SizedBox(height: 12),
                        FutureBuilder<List<Place>>(
                          future: _loadPlaces(uniquePlaceIds),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                  child: CircularProgressIndicator(
                                    color: AppColors.primaryGreen,
                                  ),
                                ),
                              );
                            }

                            if (snapshot.hasError || !snapshot.hasData) {
                              return const SizedBox.shrink();
                            }

                            final places = snapshot.data!;
                            final placeMap = {for (final p in places) p.id: p};
                            final inAdminMode =
                                authProvider.currentAdmin != null;

                            return Column(
                              children: accessEntries.map((entry) {
                                final place = placeMap[entry.placeId];
                                if (place == null)
                                  return const SizedBox.shrink();

                                final isCurrentEntry =
                                    place.id == currentPlaceId &&
                                    entry.isAdmin == inAdminMode;

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: isCurrentEntry || _isSwitching
                                          ? null
                                          : () => _switchPlace(
                                              place,
                                              entry.isAdmin,
                                            ),
                                      borderRadius: BorderRadius.circular(16),
                                      splashColor: AppColors.primaryGreen
                                          .withOpacity(0.1),
                                      highlightColor: AppColors.primaryGreen
                                          .withOpacity(0.05),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 20,
                                          vertical: 16,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isCurrentEntry
                                              ? Colors.black
                                              : AppColors.backgroundWhite
                                                    .withOpacity(0.6),
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          boxShadow: isCurrentEntry
                                              ? [
                                                  BoxShadow(
                                                    color: Colors.black
                                                        .withOpacity(0.15),
                                                    blurRadius: 8,
                                                    offset: const Offset(0, 2),
                                                  ),
                                                ]
                                              : [
                                                  BoxShadow(
                                                    color: Colors.black
                                                        .withOpacity(0.04),
                                                    blurRadius: 4,
                                                    offset: const Offset(0, 1),
                                                  ),
                                                ],
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    place.name,
                                                    style: TextStyle(
                                                      fontSize: 18,
                                                      fontWeight: isCurrentEntry
                                                          ? FontWeight.w700
                                                          : FontWeight.w600,
                                                      color: isCurrentEntry
                                                          ? Colors.white
                                                          : AppColors
                                                                .textPrimary,
                                                      letterSpacing: -0.3,
                                                    ),
                                                  ),

                                                  if (entry.isAdmin)
                                                    Text(
                                                      '관리자',
                                                      style: TextStyle(
                                                        fontSize: 15,
                                                        color: isCurrentEntry
                                                            ? Colors.white
                                                                  .withOpacity(
                                                                    0.7,
                                                                  )
                                                            : AppColors
                                                                  .textSecondary,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                        letterSpacing: -0.2,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                            if (isCurrentEntry)
                                              Container(
                                                padding: const EdgeInsets.all(
                                                  4,
                                                ),

                                                child: Icon(
                                                  Icons.check,
                                                  color: Colors.white,
                                                  size: 20,
                                                ),
                                              ),
                                            if (_isSwitching && !isCurrentEntry)
                                              SizedBox(
                                                width: 18,
                                                height: 18,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  valueColor:
                                                      AlwaysStoppedAnimation<
                                                        Color
                                                      >(AppColors.primaryGreen),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
        ],
      ),
    );
  }

  Future<List<Place>> _loadPlaces(List<String> placeIds) async {
    final firestoreService = FirestoreService();
    final places = <Place>[];

    for (final placeId in placeIds) {
      try {
        final place = await firestoreService.getPlace(placeId);
        if (place != null) {
          places.add(place);
        }
      } catch (e) {
        // 에러 발생 시 스킵
      }
    }

    return places;
  }

  Future<void> _switchPlace(Place newPlace, bool switchToAdminMode) async {
    if (_isSwitching) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final user = authProvider.currentUser;
    final admin = authProvider.currentAdmin;

    if (user == null && admin == null) {
      SnackbarUtil.showError(context, '사용자 정보를 찾을 수 없습니다.');
      return;
    }

    // ✅ 공통 검증 + 스플래시 기반 전환 플로우로 통일
    final authService = AuthService();

    if (switchToAdminMode) {
      final linkedAdmin = authProvider.linkedAdmin;
      if (linkedAdmin == null) {
        SnackbarUtil.showError(context, '연동된 관리자 계정을 찾을 수 없습니다.');
        return;
      }
      // 관리 권한 확인: places.adminId로 로드된 목록 기준
      final adminPlaceIds = authProvider.adminManagedPlaceIds;
      if (!adminPlaceIds.contains(newPlace.id)) {
        SnackbarUtil.showError(context, '해당 플레이스에 대한 관리자 권한이 없습니다.');
        return;
      }
    } else {
      // 멤버(일반) 권한 확인
      final memberPlaceIds = authProvider.approvedPlaceIds;
      if (!memberPlaceIds.contains(newPlace.id)) {
        SnackbarUtil.showError(context, '해당 플레이스에 접근 권한이 없습니다.');
        return;
      }
      if (authProvider.currentUser == null) {
        SnackbarUtil.showError(context, '사용자 정보를 찾을 수 없습니다.');
        return;
      }
    }

    setState(() {
      _isExpanded = false;
      _isSwitching = true;
    });

    try {
      // ✅ 관리자 → 일반 전환 시, 현재 admin 모드를 즉시 해제해야
      // AppStartup(멤버 플로우) 진입 후에도 UI가 admin으로 남지 않는다.
      if (!switchToAdminMode) {
        authProvider.clearCurrentAdmin();
      }

      // 1) Provider 전체 초기화
      await _resetAllProvidersForSwitch(context);

      // 1.5) 다음 화면에서 "현재 플레이스가 null"이어서 로드가 스킵되는 것을 방지하기 위해
      // 전환 대상 플레이스를 미리 주입한다. (AppStartup에서도 다시 복원/검증함)
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      placeProvider.setCurrentPlace(newPlace);

      // 2) 마지막 접속 모드/플레이스 저장 (AppStartup에서 복원에 사용)
      if (switchToAdminMode) {
        await authService.updateLastAccessedPlace(newPlace.id);
      } else {
        await authService.setCurrentPlace(newPlace);
      }

      if (!mounted) return;

      // 3) 스택 클리어 + AppStartupScreen으로 이동 (스플래시 → 로딩 → 홈 진입)
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
    } catch (e) {
      if (mounted) {
        setState(() => _isSwitching = false);
        SnackbarUtil.showError(context, '전환에 실패했습니다.');
      }
    }
  }
}
