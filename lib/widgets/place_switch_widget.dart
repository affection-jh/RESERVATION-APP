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
import '../providers/promotion_provider.dart';
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
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
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
                              color: AppColors.textPrimary.withOpacity(0.8),
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
                    size: 24,
                  ),
              ],
            ),
          ),

          // 플레이스 리스트 (펼쳐질 때)
          if (_isExpanded && canSwitch) ...[
            const SizedBox(height: 12),
            FutureBuilder<List<Place>>(
              future: _loadPlaces(uniquePlaceIds),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                if (snapshot.hasError || !snapshot.hasData) {
                  return const SizedBox.shrink();
                }

                final places = snapshot.data!;
                final placeMap = {for (final p in places) p.id: p};
                final inAdminMode = authProvider.currentAdmin != null;

                return Column(
                  children: accessEntries.map((entry) {
                    final place = placeMap[entry.placeId];
                    if (place == null) return const SizedBox.shrink();

                    final isCurrentEntry =
                        place.id == currentPlaceId &&
                        entry.isAdmin == inAdminMode;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: InkWell(
                        onTap: isCurrentEntry || _isSwitching
                            ? null
                            : () => _switchPlace(place, entry.isAdmin),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: isCurrentEntry
                                ? AppColors.primaryGreen.withOpacity(0.1)
                                : AppColors.backgroundWhite,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isCurrentEntry
                                  ? AppColors.primaryGreen
                                  : AppColors.textSecondary.withOpacity(0.2),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      place.name,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                        color: isCurrentEntry
                                            ? AppColors.primaryGreen
                                            : AppColors.textPrimary,
                                      ),
                                    ),
                                    Text(
                                      entry.isAdmin ? '관리자 모드' : '일반 모드',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textSecondary,
                                        fontWeight: FontWeight.w400,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (isCurrentEntry)
                                Icon(
                                  Icons.check_circle,
                                  color: AppColors.primaryGreen,
                                  size: 20,
                                ),
                              if (_isSwitching && !isCurrentEntry)
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      AppColors.primaryGreen,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
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

    // 관리자 모드로 전환하는 경우
    final linkedAdmin = authProvider.linkedAdmin;
    if (switchToAdminMode) {
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

      // 관리자 계정으로 전환 (AuthProvider는 user를 유지)
      authProvider.setCurrentAdmin(linkedAdmin);

      setState(() => _isSwitching = true);

      try {
        // 모든 프로바이더 데이터 클리어
        final courseProvider = Provider.of<CourseProvider>(
          context,
          listen: false,
        );
        final storyProvider = Provider.of<StoryProvider>(
          context,
          listen: false,
        );
        final promotionProvider = Provider.of<PromotionProvider>(
          context,
          listen: false,
        );

        courseProvider.clear();
        storyProvider.clear();
        promotionProvider.clear();

        // PlaceProvider 업데이트
        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        placeProvider.setCurrentPlace(newPlace);

        // AuthService에 마지막 접속 플레이스 저장
        final authService = AuthService();
        await authService.setCurrentPlace(newPlace);

        // 새 플레이스 데이터 로드 (관리자는 예약/등록 정보 불필요)
        await Future.wait([
          courseProvider.loadCourses(newPlace.id),
          storyProvider.loadStories(newPlace.id),
          promotionProvider.loadPromotions(newPlace.id),
        ]);

        if (mounted) {
          setState(() {
            _isExpanded = false;
            _isSwitching = false;
          });
          SnackbarUtil.showSuccess(context, '관리자 모드로 전환되었습니다.');
        }
        return;
      } catch (e) {
        if (mounted) {
          setState(() => _isSwitching = false);
          SnackbarUtil.showError(context, '관리자 모드 전환에 실패했습니다.');
        }
        return;
      }
    }

    // 일반 사용자 모드로 전환하는 경우 (관리자 모드 해제)
    authProvider.clearCurrentAdmin();

    // 승인 멤버십 기준으로 접근 권한 확인
    final memberPlaceIds = authProvider.approvedPlaceIds;
    if (!memberPlaceIds.contains(newPlace.id)) {
      SnackbarUtil.showError(context, '해당 플레이스에 접근 권한이 없습니다.');
      return;
    }
    if (authProvider.currentUser == null) {
      SnackbarUtil.showError(context, '사용자 정보를 찾을 수 없습니다.');
      return;
    }

    setState(() => _isSwitching = true);

    try {
      // 모든 프로바이더 데이터 클리어
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final reservationProvider = Provider.of<ReservationProvider>(
        context,
        listen: false,
      );
      final storyProvider = Provider.of<StoryProvider>(context, listen: false);
      final promotionProvider = Provider.of<PromotionProvider>(
        context,
        listen: false,
      );

      final enrollmentProvider = Provider.of<EnrollmentProvider>(
        context,
        listen: false,
      );

      courseProvider.clear();
      await reservationProvider.clear();
      await enrollmentProvider.clear();
      storyProvider.clear();
      promotionProvider.clear();

      // PlaceProvider 업데이트
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      placeProvider.setCurrentPlace(newPlace);

      // AuthService에 마지막 접속 플레이스 저장
      final authService = AuthService();
      await authService.setCurrentPlace(newPlace);

      // 새 플레이스 데이터 로드
      final currentUser = authProvider.currentUser;
      final userId = currentUser?.userId;
      final loadTasks = <Future>[
        courseProvider.loadCourses(newPlace.id),
        storyProvider.loadStories(newPlace.id),
        promotionProvider.loadPromotions(newPlace.id),
      ];

      // 일반 사용자인 경우에만 예약 및 등록 정보 로드
      if (currentUser != null && userId != null) {
        loadTasks.addAll([
          reservationProvider.loadUserReservations(
            userId: userId,
            placeId: newPlace.id,
          ),
          enrollmentProvider.loadUserEnrollments(
            userId: userId,
            placeId: newPlace.id,
          ),
        ]);
      }

      await Future.wait(loadTasks);

      if (mounted) {
        setState(() {
          _isExpanded = false;
          _isSwitching = false;
        });
        SnackbarUtil.showSuccess(context, '플레이스가 전환되었습니다.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSwitching = false);
        SnackbarUtil.showError(context, '플레이스 전환에 실패했습니다.');
      }
    }
  }
}
