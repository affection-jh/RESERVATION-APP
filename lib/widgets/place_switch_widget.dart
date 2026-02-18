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
import '../providers/reservation_summary_provider.dart';
import '../services/auth_service.dart';
import '../utils/phone_utils.dart';
import '../utils/snackbar_util.dart';
import '../screens/app_startup_screen.dart';
import '../widgets/cached_image_widget.dart' show PlaceImageWidget;
import '../widgets/place_image_detail_screen.dart';

/// 등록되지 않은 플레이스에서 나가기 시 place-waiting으로 이동 (홈/마이페이지 공통)
/// [skipAutoEnter] true면 플레이스 1개여도 자동 진입하지 않음 (설정에서 "모든 플레이스 보기" 등)
void navigateToPlaceWaitingScreen(
  BuildContext context,
  AuthProvider authProvider, {
  bool skipAutoEnter = false,
}) {
  String phoneNumber = '';
  final user = authProvider.currentUser;
  final admin = authProvider.currentAdmin;
  final linkedAdmin = authProvider.linkedAdmin;
  final fromUser = (user?.phoneNumber ?? '').trim();
  final fromAdmin = (admin?.phoneNumber)?.trim() ?? '';
  final fromLinked = (linkedAdmin?.phoneNumber)?.trim() ?? '';
  if (fromUser.isNotEmpty) {
    phoneNumber = fromUser;
  } else if (fromAdmin.isNotEmpty) {
    phoneNumber = fromAdmin;
  } else if (fromLinked.isNotEmpty) {
    phoneNumber = fromLinked;
  }
  phoneNumber = PhoneUtils.normalize(
    phoneNumber.replaceAll(RegExp(r'[^\d+]'), ''),
  );
  final arguments =
      skipAutoEnter
          ? {'phoneNumber': phoneNumber, 'skipAutoEnter': true}
          : phoneNumber;
  Navigator.of(context).pushNamedAndRemoveUntil(
    '/place-waiting',
    (route) => false,
    arguments: arguments,
  );
}

/// 플레이스 정보 및 전환 위젯 (공통)
class PlaceSwitchWidget extends StatefulWidget {
  /// 패딩을 커스터마이징할 수 있음
  final EdgeInsets? padding;

  /// 스위처 활성화 여부 (true: 활성, false: 비활성)
  /// 일반 홈/관리자 홈: false, 마이페이지: true
  final bool enabled;

  /// 설명 표시 여부 (PlaceSelector 호환성)
  final bool showDescription;

  /// 알림 아이콘 표시 여부 (홈 화면에서 사용)
  final bool showNotificationIcon;

  /// Hero 태그 고유성을 위한 접미사 (여러 화면에서 사용 시 중복 방지)
  final String? heroTagSuffix;

  /// 등록되지 않은 플레이스일 때 나가기(로그아웃) 버튼 표시 여부 (마이페이지에서 중복 방지용 false)
  final bool showExitWhenUnregistered;

  /// 현재 화면이 관리자(Admin) 맥락인지 여부 — 같은 플레이스라도 멤버/관리자 선택 표시에 사용
  final bool isAdminContext;

  /// 홈 화면 등에서 아래/위 화살표(chevron) 숨김
  final bool hideChevron;

  const PlaceSwitchWidget({
    super.key,
    this.padding,
    this.enabled = true,
    this.showDescription = false,
    this.showNotificationIcon = false,
    this.heroTagSuffix,
    this.showExitWhenUnregistered = true,
    this.isAdminContext = false,
    this.hideChevron = false,
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
    final summaryProvider = Provider.of<ReservationSummaryProvider>(
      context,
      listen: false,
    );
    // 현재 플레이스 제거
    placeProvider.clearPlace();

    // 모든 데이터/구독 초기화
    courseProvider.clear();
    summaryProvider.clear();
    storyProvider.clear();
    notificationProvider.clear();
    memberProvider.clear();
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

    final accessEntries = <_PlaceAccessEntry>[
      ...memberPlaceIds.map(
        (id) => _PlaceAccessEntry(placeId: id, isAdmin: false),
      ),
      ...adminPlaceIds.map(
        (id) => _PlaceAccessEntry(placeId: id, isAdmin: true),
      ),
    ];

    final uniquePlaceIds = accessEntries.map((e) => e.placeId).toSet().toList();

    final hasMultiplePlaces = accessEntries.length > 1;
    final currentPlaceId = currentPlace.id;
    final canSwitch = widget.enabled && hasMultiplePlaces;

    return Padding(
      padding: EdgeInsets.only(top: 10, bottom: 10, left: 20, right: 10),
      child: Column(
        children: [
          // 플레이스 정보 (로그인 시에만 클릭 가능)
          Row(
            children: [
              // 플레이스 이미지와 이름 (탭 시 이미지 상세 보기로 이동 — 홈/마이페이지 공통)
              Expanded(
                child: Builder(
                  builder: (context) {
                    final placeHeroTag =
                        'place_image_${currentPlace.id}'
                        '${widget.heroTagSuffix != null ? '_${widget.heroTagSuffix}' : ''}';
                    return InkWell(
                      onTap: () {
                        Navigator.of(context).push(
                          PageRouteBuilder(
                            pageBuilder:
                                (
                                  context,
                                  animation,
                                  secondaryAnimation,
                                ) => PlaceImageDetailScreen(
                                  imageUrl: currentPlace.imageUrl,
                                  placeName: currentPlace.name,
                                  placeDescription:
                                      currentPlace.description ?? '',
                                  heroTag: placeHeroTag,
                                ),
                            transitionDuration: const Duration(
                              milliseconds: 300,
                            ),
                            reverseTransitionDuration: const Duration(
                              milliseconds: 300,
                            ),
                            opaque: false,
                            transitionsBuilder: (
                              context,
                              animation,
                              secondaryAnimation,
                              child,
                            ) {
                              return FadeTransition(
                                opacity: animation,
                                child: child,
                              );
                            },
                          ),
                        );
                      },
                      borderRadius: BorderRadius.circular(16),
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      child: Row(
                        children: [
                          // 플레이스 이미지 (들어올 때 Hero 애니메이션)
                          Hero(
                            tag: placeHeroTag,
                            child: Material(
                              color: Colors.transparent,
                              child: PlaceImageWidget(
                                imageUrl: currentPlace.imageUrl,
                                width: 50,
                                height: 50,
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          // 플레이스 이름
                          Expanded(
                            child: Builder(
                              builder: (context) {
                                // description이 있는지 확인
                                final descriptionText =
                                    widget.showDescription
                                        ? (currentPlace.description ?? '')
                                            .trim()
                                        : '';
                                final hasDescription =
                                    descriptionText.isNotEmpty;

                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      currentPlace.name,
                                      style: TextStyle(
                                        // showDescription이 true이고 description이 없을 때는 크게 (20)
                                        // showDescription이 true이고 description이 있을 때는 중간 (18)
                                        // showDescription이 false일 때는 작게 (16)
                                        fontSize:
                                            widget.showDescription
                                                ? (hasDescription ? 18 : 20)
                                                : 20,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.textPrimary,
                                        letterSpacing: -0.5,
                                      ),
                                    ),
                                    // showDescription이 true이고 description이 있을 때만 표시
                                    if (widget.showDescription &&
                                        hasDescription) ...[
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
                          SizedBox(width: 16),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // 토글 모드일 때만 화살표 표시 (홈에서는 hideChevron으로 숨김)
              if (!widget.hideChevron && widget.enabled && hasMultiplePlaces)
                InkWell(
                  onTap: () {
                    setState(() {
                      _isExpanded = !_isExpanded;
                    });
                  },
                  borderRadius: BorderRadius.circular(16),
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Icon(
                      _isExpanded
                          ? Icons
                              .keyboard_arrow_up // 펼쳐졌을 때: 위로 닫기 화살표
                          : Icons.keyboard_arrow_down, // 접혔을 때: 아래로 펼치기 화살표
                      color: AppColors.textSecondary,
                      size: 28,
                    ),
                  ),
                ),
            ],
          ),

          // 플레이스 리스트 (펼쳐질 때) — 캐시(PlaceProvider) 기반만 사용, 네트워크 호출 없음
          if (canSwitch)
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child:
                  _isExpanded
                      ? Column(
                        children: [
                          const SizedBox(height: 12),
                          Builder(
                            builder: (context) {
                              final auth = Provider.of<AuthProvider>(context);
                              final placeMap = <String, Place?>{
                                for (final id in uniquePlaceIds) id: placeProvider.getPlace(id),
                              };
                              final inAdminMode = widget.isAdminContext;

                              return Column(
                                children:
                                    accessEntries.map((entry) {
                                      final place = placeMap[entry.placeId];
                                      if (place == null)
                                        return const SizedBox.shrink();

                                      final isCurrentEntry =
                                          place.id == currentPlaceId &&
                                          entry.isAdmin == inAdminMode;
                                      final placeMember = entry.isAdmin ? auth.getPlaceMemberForPlace(entry.placeId) : null;
                                      final adminLabel = placeMember == null
                                          ? '매니저'
                                          : (placeMember.isManager ? '매니저' : '코스매니저');

                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 6,
                                        ),
                                        child: Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            onTap:
                                                isCurrentEntry || _isSwitching
                                                    ? null
                                                    : () => _switchPlace(
                                                      place,
                                                      entry.isAdmin,
                                                    ),
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                            splashColor: AppColors.primaryGreen
                                                .withOpacity(0.1),
                                            highlightColor: AppColors
                                                .primaryGreen
                                                .withOpacity(0.05),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 20,
                                                    vertical: 16,
                                                  ),
                                              decoration: BoxDecoration(
                                                color:
                                                    isCurrentEntry
                                                        ? Colors.black
                                                        : AppColors
                                                            .backgroundWhite
                                                            .withOpacity(0.6),
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                boxShadow:
                                                    isCurrentEntry
                                                        ? [
                                                          BoxShadow(
                                                            color: Colors.black
                                                                .withOpacity(
                                                                  0.15,
                                                                ),
                                                            blurRadius: 8,
                                                            offset:
                                                                const Offset(
                                                                  0,
                                                                  2,
                                                                ),
                                                          ),
                                                        ]
                                                        : [
                                                          BoxShadow(
                                                            color: Colors.black
                                                                .withOpacity(
                                                                  0.04,
                                                                ),
                                                            blurRadius: 4,
                                                            offset:
                                                                const Offset(
                                                                  0,
                                                                  1,
                                                                ),
                                                          ),
                                                        ],
                                              ),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                          place.name,
                                                          style: TextStyle(
                                                            fontSize: 18,
                                                            fontWeight:
                                                                isCurrentEntry
                                                                    ? FontWeight
                                                                        .w700
                                                                    : FontWeight
                                                                        .w600,
                                                            color:
                                                                isCurrentEntry
                                                                    ? Colors
                                                                        .white
                                                                    : AppColors
                                                                        .textPrimary,
                                                            letterSpacing: -0.3,
                                                          ),
                                                        ),

                                                        if (entry.isAdmin)
                                                          Text(
                                                            adminLabel,
                                                            style: TextStyle(
                                                              fontSize: 15,
                                                              color:
                                                                  isCurrentEntry
                                                                      ? Colors
                                                                          .white
                                                                          .withOpacity(
                                                                            0.7,
                                                                          )
                                                                      : AppColors
                                                                          .textSecondary,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w500,
                                                              letterSpacing:
                                                                  -0.2,
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                  if (isCurrentEntry)
                                                    Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                            4,
                                                          ),

                                                      child: Icon(
                                                        Icons.check,
                                                        color: Colors.white,
                                                        size: 20,
                                                      ),
                                                    ),
                                                  if (_isSwitching &&
                                                      !isCurrentEntry)
                                                    SizedBox(
                                                      width: 18,
                                                      height: 18,
                                                      child: CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        valueColor:
                                                            AlwaysStoppedAnimation<
                                                              Color
                                                            >(
                                                              AppColors
                                                                  .primaryGreen,
                                                            ),
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

  Future<void> _switchPlace(Place newPlace, bool switchToAdminMode) async {
    if (_isSwitching) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final user = authProvider.currentUser;
    final admin = authProvider.currentAdmin;

    if (user == null && admin == null) {
      SnackbarUtil.showInfo(context, '사용자 정보를 찾을 수 없습니다.');
      return;
    }

    // ✅ 공통 검증 + 스플래시 기반 전환 플로우로 통일
    final authService = AuthService();

    if (switchToAdminMode) {
      // 관리 권한: linkedAdmin(연동 관리자) 또는 places/.../members(본인 매니저) 둘 다 허용
      final adminPlaceIds = authProvider.adminManagedPlaceIds;
      if (!adminPlaceIds.contains(newPlace.id)) {
        SnackbarUtil.showInfo(context, '해당 플레이스에 대한 관리자 권한이 없습니다.');
        return;
      }
    } else {
      // 멤버(일반) 권한 확인
      final memberPlaceIds = authProvider.approvedPlaceIds;
      if (!memberPlaceIds.contains(newPlace.id)) {
        SnackbarUtil.showInfo(context, '해당 플레이스에 접근 권한이 없습니다.');
        return;
      }
      if (authProvider.currentUser == null) {
        SnackbarUtil.showInfo(context, '사용자 정보를 찾을 수 없습니다.');
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

      // 2) 마지막 접속 모드/플레이스 저장
      if (switchToAdminMode) {
        await authService.updateLastAccessedPlace(newPlace.id);
      } else {
        await authService.setCurrentPlace(newPlace);
      }

      if (!mounted) return;

      // 3) 스택 클리어 후 스플래시로 이동 (옆에서 슬라이드 말고 바로 전환)
      Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder(
          pageBuilder:
              (context, animation, secondaryAnimation) =>
                  const AppStartupScreen(),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) =>
                  FadeTransition(opacity: animation, child: child),
          transitionDuration: Duration.zero,
        ),
        (route) => false,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isSwitching = false);
        SnackbarUtil.showInfo(context, '전환에 실패했습니다.');
      }
    }
  }
}
