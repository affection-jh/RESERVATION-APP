import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:provider/provider.dart';
import 'package:reservation/services/user_service.dart';
import '../theme/app_colors.dart';
import '../models/place.dart';
import '../models/place_membership.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../providers/course_provider.dart';
import '../providers/enrollment_provider.dart';
import '../providers/place_provider.dart';
import '../providers/reservation_provider.dart';
import '../providers/story_provider.dart';
import '../services/firestore_service.dart';
import '../services/member_service.dart';
import '../services/auth_service.dart';
import '../widgets/common_dialog.dart';
import '../widgets/cached_image_widget.dart';
import '../constants/app_constants.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// 플레이스 대기 화면
///
/// 전화번호 인증 후 초대된 플레이스가 없으면 안내 메시지,
/// 있으면 플레이스 리스트를 표시
class PlaceWaitingScreen extends StatefulWidget {
  final String phoneNumber;

  const PlaceWaitingScreen({super.key, required this.phoneNumber});

  @override
  State<PlaceWaitingScreen> createState() => _PlaceWaitingScreenState();
}

class _PlaceWaitingScreenState extends State<PlaceWaitingScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final MemberService _memberService = MemberService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  String? _userId;
  StreamSubscription<List<PlaceMembership>>? _membershipSubscription;
  List<PlaceMembership> _memberships = [];
  Map<String, Place> _placesMap = {};
  bool _isLoading = true;
  bool _hasAutoNavigated = false;
  bool _requireManualEntrySelection = false;
  bool _isEnteringPlace = false;

  /// AuthProvider.currentUser를 보장한다.
  ///
  /// - 가능한 경우: Firebase Auth UID로 users/{uid} 문서를 우선 로드
  /// - 실패 시: phoneNumber 기반 조회(이미 정규화된 값 기대)를 시도
  /// - 어떤 경우에도 화면 흐름을 막지 않는다.
  Future<void> _ensureAuthProviderUser({
    required String uid,
    String? phoneNumber,
  }) async {
    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      if (authProvider.currentUser?.userId == uid) return;

      // 1) UID 기반 문서 우선 (rules/request.auth.uid와 정합성)
      try {
        final user = await _userService.getUser(uid);
        authProvider.setCurrentUser(user);
        return;
      } catch (_) {
        // ignore
      }

      // 2) phoneNumber 기반 조회 (폴백)
      if (phoneNumber != null && phoneNumber.trim().isNotEmpty) {
        final user = await _authService.findUserByPhone(phoneNumber);
        if (user != null) {
          authProvider.setCurrentUser(user);
        }
      }
    } catch (_) {
      // ignore
    }
  }

  @override
  void initState() {
    super.initState();
    _initializeUser();
  }

  @override
  void dispose() {
    _membershipSubscription?.cancel();
    super.dispose();
  }

  /// 사용자 초기화
  Future<void> _initializeUser() async {
    try {
      _requireManualEntrySelection =
          await _authService.requiresManualEntrySelection();

      // Firebase Auth에서 현재 사용자 확인
      final firebaseUser = _authService.currentFirebaseUser;
      if (firebaseUser == null) {
        // 인증 정보가 없으면 로그인 화면으로 이동
        if (mounted) {
          Navigator.of(
            context,
          ).pushNamedAndRemoveUntil('/phone-number', (route) => false);
        }
        return;
      }

      // ✅ 자동 로그인 성공 후에는 AuthProvider에서 먼저 확인
      // (AppStartupScreen에서 이미 setCurrentUser를 했을 수 있음)
      User? user;
      try {
        final authProvider = Provider.of<AuthProvider>(context, listen: false);
        user = authProvider.currentUser;
        if (user != null) {
          debugPrint(
            '[PlaceWaitingScreen] AuthProvider에서 사용자 정보 가져옴: ${user.userId}',
          );
        }
      } catch (_) {
        // Provider가 아직 준비 안 됐을 수 있음
      }

      // AuthProvider에 없으면 findUserByPhone 시도
      if (user == null) {
        String phoneNumber =
            widget.phoneNumber.isNotEmpty
                ? widget.phoneNumber
                : (firebaseUser.phoneNumber ?? '');

        // ✅ AuthService의 _normalizePhoneNumber와 동일한 정규화 적용
        // (Firestore에 저장된 형식과 일치해야 함)
        phoneNumber = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
        // +82로 시작하는 경우 0으로 변환
        if (phoneNumber.startsWith('+82')) {
          phoneNumber = '0${phoneNumber.substring(3)}';
        }
        // +로 시작하는 다른 국가코드 제거 (마지막 10자리만)
        else if (phoneNumber.startsWith('+')) {
          phoneNumber = phoneNumber.substring(phoneNumber.length - 10);
        }

        debugPrint('[PlaceWaitingScreen] findUserByPhone 시도: $phoneNumber');
        user = await _authService.findUserByPhone(phoneNumber);
        if (user == null) {
          debugPrint('[PlaceWaitingScreen] findUserByPhone 결과: null');
        } else {
          debugPrint('[PlaceWaitingScreen] findUserByPhone 성공: ${user.userId}');
        }
      }

      // ✅ Firebase Auth 세션이 살아있으면 findUserByPhone 실패해도 진행
      // (자동 로그인 성공 후 Firestore 조회가 일시적으로 실패할 수 있음)
      if (user == null) {
        debugPrint(
          '[PlaceWaitingScreen] findUserByPhone 실패, 하지만 Firebase Auth 세션 존재 → 진행',
        );
        // Firebase Auth 세션이 있으면 userId를 직접 사용
        final uid = firebaseUser.uid;
        if (uid.isNotEmpty) {
          setState(() {
            _userId = uid;
            _isLoading = true;
          });
          // ✅ Main 진입 시 enrollments/reservations 로드를 위해 currentUser 보장
          String? fallbackPhone;
          try {
            fallbackPhone =
                widget.phoneNumber.isNotEmpty
                    ? widget.phoneNumber
                    : (firebaseUser.phoneNumber ?? '');
            fallbackPhone = fallbackPhone.replaceAll(RegExp(r'[^\d+]'), '');
            if (fallbackPhone.startsWith('+82')) {
              fallbackPhone = '0${fallbackPhone.substring(3)}';
            } else if (fallbackPhone.startsWith('+')) {
              fallbackPhone = fallbackPhone.substring(
                fallbackPhone.length - 10,
              );
            }
          } catch (_) {
            fallbackPhone = null;
          }
          await _ensureAuthProviderUser(uid: uid, phoneNumber: fallbackPhone);
          // 멤버십 구독 시작 (userId가 uid일 수도 있음)
          _startMembershipSubscription();
          return;
        }
        // uid도 없으면 로그인 화면으로
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          Navigator.of(
            context,
          ).pushNamedAndRemoveUntil('/phone-number', (route) => false);
        }
        return;
      }

      // ✅ Firestore rules 권한 확인을 위해 request.auth.uid 사용
      // user.userId는 request.auth.uid와 일치해야 함
      final uid = firebaseUser.uid;
      setState(() {
        _userId = uid; // request.auth.uid 사용 (Firestore rules와 일치)
        _isLoading = true;
      });

      // ✅ Main 진입 시 enrollments/reservations 로드를 위해 currentUser 보장
      await _ensureAuthProviderUser(uid: uid, phoneNumber: user.phoneNumber);

      // 멤버십 구독 시작
      _startMembershipSubscription();
    } catch (e) {
      debugPrint('[PlaceWaitingScreen] _initializeUser 에러: $e');
      // ✅ Firebase Auth 세션이 살아있으면 에러가 나도 /phone-number로 보내지 않음
      final firebaseUser = _authService.currentFirebaseUser;
      if (firebaseUser == null) {
        // 인증 정보가 없으면 로그인 화면으로 이동
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          Navigator.of(
            context,
          ).pushNamedAndRemoveUntil('/phone-number', (route) => false);
        }
      } else {
        // Firebase Auth 세션이 있으면 그냥 진행 (멤버십이 없을 수도 있음)
        debugPrint('[PlaceWaitingScreen] 에러 발생했지만 Firebase Auth 세션 존재 → 진행');
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  /// 멤버십 실시간 구독 시작
  void _startMembershipSubscription() {
    if (_userId == null) return;

    // 이미 같은 userId로 구독 중이면 재구독하지 않음
    if (_membershipSubscription != null) {
      return;
    }

    _membershipSubscription = _memberService
        .watchUserMemberships(_userId!)
        .listen((memberships) async {
          // status 제거로 모든 멤버십이 승인된 것으로 처리
          final approvedMemberships = memberships;

          // 플레이스 정보 가져오기 (배치 처리로 최적화)
          final placesMap = <String, Place>{};

          // 이미 로드된 플레이스는 재사용
          final placeIdsToLoad =
              approvedMemberships
                  .map((m) => m.placeId)
                  .where((placeId) => !_placesMap.containsKey(placeId))
                  .toList();

          // 배치로 플레이스 로드 (병렬 처리)
          if (placeIdsToLoad.isNotEmpty) {
            final places = await Future.wait(
              placeIdsToLoad.map((placeId) async {
                try {
                  return await _firestoreService.getPlace(placeId);
                } catch (e) {
                  return null;
                }
              }),
            );

            // 로드된 플레이스를 맵에 추가
            for (int i = 0; i < placeIdsToLoad.length; i++) {
              final place = places[i];
              if (place != null) {
                placesMap[placeIdsToLoad[i]] = place;
              }
            }
          }

          // 기존 플레이스 맵과 새로 로드한 플레이스 맵 병합
          final updatedPlacesMap = <String, Place>{..._placesMap, ...placesMap};

          // 승인된 멤버십에 해당하는 플레이스만 필터링
          final finalPlacesMap = <String, Place>{};
          for (final membership in approvedMemberships) {
            final place = updatedPlacesMap[membership.placeId];
            if (place != null) {
              finalPlacesMap[membership.placeId] = place;
            }
          }

          if (mounted) {
            setState(() {
              _memberships = approvedMemberships;
              _placesMap = finalPlacesMap;
              _isLoading = false;
            });

            // 자동 로그인 처리 (한 번만 실행)
            // ✅ 명시적 재로그인 직후에는 자동 진입을 하지 않는다.
            if (!_requireManualEntrySelection &&
                !_hasAutoNavigated &&
                approvedMemberships.length == 1) {
              _hasAutoNavigated = true;
              final place = finalPlacesMap[approvedMemberships.first.placeId];
              if (place != null) {
                _navigateToMain(place);
              }
            }
          }
        });
  }

  /// 승인된 플레이스 리스트 가져오기
  List<Place> _getApprovedPlaces() {
    return _memberships
        .map((m) => _placesMap[m.placeId])
        .where((place) => place != null)
        .cast<Place>()
        .toList();
  }

  void _onPlaceTap(Place place) async {
    // 인증정보 확인 (Firebase Auth)
    final firebaseUser = _authService.currentFirebaseUser;
    if (firebaseUser == null) {
      // 인증정보가 없으면 다이얼로그 표시
      final confirmed = await CommonDialog.show(
        context: context,
        title: '인증정보 오류',
        message: '인증정보를 찾을 수 없습니다.\n다시 로그인해주세요.',
        cancelText: '취소',
        confirmText: '로그인하기',
      );

      if (confirmed == true) {
        // 초기 로그인 화면으로 이동 (모든 화면 제거)
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/phone-number', (route) => false);
      }
      return;
    }

    _navigateToMain(place);
  }

  void _navigateToMain(Place place) async {
    if (_isEnteringPlace) return;
    setState(() {
      _isEnteringPlace = true;
    });

    // 플레이스 이미지 프리로드 (이미지 URL이 있는 경우)
    if (place.imageUrl != null && place.imageUrl!.isNotEmpty) {
      try {
        // 이미지를 미리 캐시에 로드 (동기적 프리로드)
        await precacheImage(
          CachedNetworkImageProvider(place.imageUrl!),
          context,
        );
      } catch (e) {
        // 프리로드 실패해도 계속 진행 (이미지가 없어도 앱은 정상 동작)
        debugPrint('[PlaceWaitingScreen] 이미지 프리로드 실패: $e');
      }
    }

    try {
      // 플레이스 선택 시 마지막 접속 플레이스로 저장
      await _authService.setCurrentPlace(place);
      // 명시적 진입 선택 완료 → 플래그 해제
      await _authService.clearRequireManualEntrySelection();

      if (!mounted) return;

      // ✅ MainScreen이 의존하는 PlaceProvider를 먼저 세팅
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      placeProvider.setCurrentPlace(place);

      // ✅ 이전 place 데이터가 남아있지 않도록 클리어 후, 새 place 데이터 로드
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final storyProvider = Provider.of<StoryProvider>(context, listen: false);
      final reservationProvider = Provider.of<ReservationProvider>(
        context,
        listen: false,
      );
      final enrollmentProvider = Provider.of<EnrollmentProvider>(
        context,
        listen: false,
      );

      courseProvider.clear();
      storyProvider.clear();
      await reservationProvider.clear();
      await enrollmentProvider.clear();

      // ✅ 스플래시 동안 "첫 화면 체감"에 중요한 데이터만 먼저 로드하고,
      // 나머지는 백그라운드로 돌린다 (Future.wait에 묶여 스플래시가 끝없이 걸리는 문제 방지)
      final primaryLoads = <Future<void>>[storyProvider.loadStories(place.id)];
      try {
        await Future.wait(primaryLoads).timeout(const Duration(seconds: 6));
      } catch (e) {
        debugPrint('[PlaceWaitingScreen] primary load timeout/error: $e');
      }

      // 나머지 데이터는 기다리지 않고 백그라운드 로드 (필요 시 화면에서 자연스럽게 갱신됨)
      courseProvider.loadCourses(place.id);
      final user = authProvider.currentUser;
      if (user != null) {
        reservationProvider.loadUserReservations(
          userId: user.userId,
          placeId: place.id,
        );
        enrollmentProvider.loadUserEnrollments(
          userId: user.userId,
          placeId: place.id,
        );
      }

      // ✅ 스토리 이미지 프리캐시 (Image.network 기반)
      final precacheFuture = _precacheAllStoryImages(storyProvider);
      // 프리캐시는 "시작"은 스플래시에서 하고, 너무 오래 끌면 메인 진입을 막지 않도록 캡을 둔다.
      await Future.any([
        precacheFuture,
        Future.delayed(const Duration(seconds: 2)),
      ]);

      if (!mounted) return;
      // ✅ 모든 이전 화면을 제거하고 main을 첫 화면으로 설정
      Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
    } finally {
      if (mounted) {
        setState(() {
          _isEnteringPlace = false;
        });
      }
    }
  }

  Future<void> _precacheAllStoryImages(StoryProvider storyProvider) async {
    try {
      // 일반 이미지 URL 수집
      final imageUrls =
          <String>{
            for (final story in storyProvider.stories) ...story.imageUrls,
          }.where((u) => u.trim().isNotEmpty).toList();

      // 배경 이미지 URL 수집
      final backgroundImageUrls =
          <String>{
            for (final story in storyProvider.stories)
              if (story.backgroundImageUrl != null &&
                  story.backgroundImageUrl!.isNotEmpty)
                story.backgroundImageUrl!,
          }.where((u) => u.trim().isNotEmpty).toList();

      final allUrls = [...imageUrls, ...backgroundImageUrls];

      for (final url in allUrls) {
        if (!mounted) return;
        try {
          // ✅ CachedNetworkImageProvider를 사용하여 캐시 키 일치
          // StoryCard의 cacheKey와 동일하게 URL을 캐시 키로 사용
          await precacheImage(CachedNetworkImageProvider(url), context);
        } catch (_) {
          // ignore
        }
      }
    } catch (_) {
      // ignore
    }
  }

  /// 뒤로가기 처리
  Future<bool> _onWillPop() async {
    final confirmed = await CommonDialog.show(
      context: context,
      title: '로그아웃',
      message: '로그아웃 하시겠습니까?',
      confirmText: '로그아웃',
      cancelText: '취소',
    );

    if (confirmed == true) {
      if (mounted) {
        await _authService.logout();
        await _authService.clearRequireManualEntrySelection();
        Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
      }
      return false; // 뒤로가기 방지 (이미 네비게이션 처리됨)
    }
    return false; // 다이얼로그에서 취소하면 뒤로가기 방지
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (!didPop) {
          await _onWillPop();
        }
      },
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: AppColors.backgroundLight,
            appBar: AppBar(
              backgroundColor: AppColors.backgroundLight,
              elevation: 0,
              scrolledUnderElevation: 0,
              leading: IconButton(
                onPressed: () async {
                  await _onWillPop();
                },
                icon: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: SvgPicture.asset(
                    'assets/icons/logout-icon.svg',
                    width: 26,
                    height: 26,
                    colorFilter: ColorFilter.mode(
                      AppColors.primaryGreen,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await _handleAdminLogin();
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '관리자로 진행하기',
                          style: TextStyle(
                            fontSize: 18,
                            color: AppColors.primaryGreen,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Icon(
                          Icons.arrow_forward_ios,
                          size: 16,
                          color: AppColors.primaryGreen,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
            body: SafeArea(
              child:
                  _isLoading
                      ? const Center(
                        child: CircularProgressIndicator(
                          color: AppColors.primaryGreen,
                        ),
                      )
                      : _buildContent(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final approvedPlaces = _getApprovedPlaces();

    if (approvedPlaces.isEmpty) {
      return Center(child: _buildEmptyState());
    }

    return _buildPlaceList(approvedPlaces);
  }

  /// 초대된 플레이스가 없을 때 표시 (미니게임 포함)
  Widget _buildEmptyState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                AppConstants.noInvitedPlacesTitle,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),

          Text(
            AppConstants.noInvitedPlacesMessage,
            style: TextStyle(
              fontSize: 16,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// 플레이스 리스트 표시
  Widget _buildPlaceList(List<Place> places) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 헤더
        SizedBox(height: 16),
        // 플레이스 리스트
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: places.length,
            itemBuilder: (context, index) {
              return _buildPlaceCard(places[index]);
            },
          ),
        ),
      ],
    );
  }

  /// 플레이스 카드
  Widget _buildPlaceCard(Place place) {
    return GestureDetector(
      onTap: () => _onPlaceTap(place),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.backgroundWhite,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              // 플레이스 이미지 (PlaceImageWidget 사용)
              PlaceImageWidget(
                imageUrl: place.imageUrl,
                width: 100,
                height: 100,
                borderRadius: BorderRadius.circular(12),
              ),
              const SizedBox(width: 16),
              // 플레이스 정보
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      place.name,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        overflow: TextOverflow.ellipsis,
                        letterSpacing: -0.3,
                      ),
                    ),
                    if (place.location != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        place.location!,
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 관리자 로그인 처리
  /// waiting_screen에 있다는 것은 이미 로그인이 완료된 상태이므로
  /// 인증은 스킵하고 관리자 정보만 조회하여 PIN 입력 화면으로 이동
  Future<void> _handleAdminLogin() async {
    try {
      // waiting_screen에 있다는 것은 이미 로그인된 상태
      // Firebase Auth에서 전화번호 가져오기 (인증 정보 확인)
      String? phoneNumber;

      final firebaseUser = _authService.currentFirebaseUser;
      if (firebaseUser != null) {
        phoneNumber = firebaseUser.phoneNumber;
      }

      // Firebase Auth에서 전화번호를 찾을 수 없으면 인증 정보가 없는 것
      if (phoneNumber == null || phoneNumber.isEmpty) {
        if (mounted) {
          final confirmed = await CommonDialog.show(
            context: context,
            title: '인증정보 오류',
            message: '인증정보를 찾을 수 없습니다.\n다시 로그인해주세요.',
            cancelText: '취소',
            confirmText: '로그인하기',
          );

          if (confirmed == true) {
            // 초기 로그인 화면으로 이동 (모든 화면 제거)
            Navigator.of(
              context,
            ).pushNamedAndRemoveUntil('/phone-number', (route) => false);
          }
        }
        return;
      }

      // 전화번호 정규화
      phoneNumber = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
      if (phoneNumber.startsWith('82')) {
        phoneNumber = '0${phoneNumber.substring(2)}';
      } else if (!phoneNumber.startsWith('0')) {
        phoneNumber = '0$phoneNumber';
      }

      // 관리자 정보만 조회 (인증은 이미 완료된 상태)
      final admin = await _authService.findAdminByPhone(phoneNumber);

      if (mounted) {
        if (admin != null) {
          // 기존 관리자인 경우 PIN 입력 화면으로 이동
          Navigator.of(context).pushNamed(
            '/admin-pin-input',
            arguments: {
              'phoneNumber': phoneNumber,
              'verificationCode': '', // 인증은 이미 완료된 상태이므로 불필요
            },
          );
        } else {
          // 관리자가 아니지만 관리자가 되고자 하는 경우 PIN 등록 화면으로 이동
          // 전화번호가 인증되었으면 관리자 정보가 없어도 바로 등록으로 이동
          Navigator.of(context).pushNamed(
            '/admin-register',
            arguments: {
              'phoneNumber': phoneNumber,
              'verificationCode': '', // 인증은 이미 완료된 상태이므로 불필요
            },
          );
        }
      }
    } catch (e) {
      // 에러 발생 시 에러 메시지 표시
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('관리자 정보를 불러올 수 없습니다: $e')));
      }
    }
  }
}
