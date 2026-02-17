import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:provider/provider.dart';
import 'package:reservation/services/user_service.dart';
import 'package:reservation/utils/snackbar_util.dart';
import '../theme/app_colors.dart';
import '../models/place.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../providers/course_provider.dart';
import '../providers/enrollment_provider.dart';
import '../providers/member_provider.dart';
import '../providers/place_provider.dart';
import '../providers/reservation_provider.dart';
import '../providers/reservation_summary_provider.dart';
import '../providers/story_provider.dart';
import '../services/firestore_service.dart';
import '../services/member_service.dart';
import '../services/auth_service.dart';
import '../utils/local_storage_util.dart';
import '../widgets/common_dialog.dart';
import '../widgets/cached_image_widget.dart';
import '../widgets/splash_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'admin/widgets/place_registration_screen.dart';
import 'admin_screen.dart';

/// 플레이스 대기 화면
///
/// 전화번호 인증 후 초대된 플레이스가 없으면 안내 메시지,
/// 있으면 플레이스 리스트를 표시
class PlaceWaitingScreen extends StatefulWidget {
  final String phoneNumber;

  /// true면 플레이스 1개여도 자동 진입하지 않고 목록만 표시 (예: 설정에서 "모든 플레이스 보기")
  final bool skipAutoEnter;

  const PlaceWaitingScreen({
    super.key,
    required this.phoneNumber,
    this.skipAutoEnter = false,
  });

  @override
  State<PlaceWaitingScreen> createState() => _PlaceWaitingScreenState();
}

class _PlaceWaitingScreenState extends State<PlaceWaitingScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final MemberService _memberService = MemberService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final TextEditingController _searchController = TextEditingController();
  bool _searchListenerAttached = false;
  String? _userId;
  StreamSubscription<List<String>>? _membershipSubscription;
  List<String> _memberPlaceIds = [];
  Map<String, Place> _placesMap = {};
  bool _isLoading = true;
  bool _hasAutoNavigated = false;
  bool _requireManualEntrySelection = false;
  bool _isEnteringPlace = false;
  String? _enteringPlaceId; // 진입 중인 플레이스 ID (해당 카드에 로딩 표시)
  List<Place>? _serverSearchResults; // 서버 검색 결과 (null = 미요청)
  bool _isSearchingServer = false;
  Timer? _searchDebounce; // 실시간 검색 디바운스 (SearchService와 동일 300ms)
  bool _linkedAdminLoaded = false; // 관리자 정보(linkedAdmin + managedIds) 최초 1회만 조회
  List<Place> _visitHistoryPlaces = []; // 로컬 방문 기록 (검색어 없을 때 노출)
  String? _lastSearchQuery; // 마지막으로 서버에 보낸 쿼리 (동일 쿼리 재요청 방지)
  int _lastSearchCount = -1; // 마지막 검색 결과 개수 (접두사 확장 시 스킵 판단용)
  bool _isAdminLoading = false; // 관리자 진입 시 스플래시 + 데이터 로드 중
  Widget? _adminTargetScreen; // 관리자 화면 (미리 렌더 후 스플래시만 페이드아웃)
  static const Duration _adminSplashMinDuration = Duration(seconds: 2);
  static const int _descriptionMaxCollapsed = 80; // 이 글자 수 초과 시 "펼치기" 표시
  final Set<String> _expandedDescriptionPlaceIds = {}; // 설명 펼친 플레이스 ID

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadVisitHistory();
    });
    // 검색 입력 트리거는 컨트롤러 리스너 1곳으로 통일
    _attachSearchListenerIfNeeded();
  }

  void _attachSearchListenerIfNeeded() {
    if (_searchListenerAttached) return;
    _searchController.addListener(_onSearchControllerChanged);
    _searchListenerAttached = true;
  }

  void _onSearchControllerChanged() {
    _onSearchChanged();
  }

  @override
  void dispose() {
    if (_searchListenerAttached) {
      _searchController.removeListener(_onSearchControllerChanged);
      _searchListenerAttached = false;
    }
    _searchDebounce?.cancel();
    _membershipSubscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// 검색어 변경 (SearchService.onSearchChanged와 동일 패턴)
  /// - 빈 값: 상태 초기화 + 방문 기록 로드
  /// - 값 있음: 디바운스 300ms 후 서버 검색
  void _onSearchChanged() {
    final query = _searchController.text.trim();
    _searchDebounce?.cancel();
    debugPrint('[PlaceWaitingScreen] searchChanged: "$query"');

    if (query.isEmpty) {
      setState(() {
        _serverSearchResults = null;
        _isSearchingServer = false;
        _lastSearchQuery = null;
        _lastSearchCount = -1;
      });
      _loadVisitHistory();
      return;
    }

    // 검색은 서버(searchPlaces) 전용. 전체 컬렉션 조회 사용 안 함.
    _isSearchingServer = true;
    if (mounted) setState(() {});

    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _performRealTimeSearch(_searchController.text.trim());
    });
  }

  /// 실시간 플레이스 검색 (SearchService._performRealTimeSearch와 동일 패턴)
  /// - 접두사 확장 + 이전 결과 0~1개면 요청 스킵 (클라이언트 필터만)
  /// - 사용자가 글자를 지우면 새로 요청
  Future<void> _performRealTimeSearch(String q) async {
    if (q.isEmpty) {
      if (mounted) {
        setState(() {
          _serverSearchResults = null;
          _lastSearchQuery = null;
          _lastSearchCount = -1;
          _isSearchingServer = false;
        });
      }
      return;
    }

    // 이전 검색 쿼리가 현재 쿼리의 접두사이고 결과가 0~1개면 서버 재요청 스킵 (서버 결과로 로컬 필터만)
    final canUseLocalFilterOnly =
        _serverSearchResults != null && _serverSearchResults!.isNotEmpty;
    if (canUseLocalFilterOnly &&
        _lastSearchQuery != null &&
        _lastSearchQuery!.isNotEmpty &&
        q.startsWith(_lastSearchQuery!) &&
        _lastSearchCount <= 1) {
      if (mounted) setState(() => _isSearchingServer = false);
      return;
    }

    // 사용자가 텍스트를 삭제한 경우 → 새 검색 허용
    if (_lastSearchQuery != null && q.length < _lastSearchQuery!.length) {
      _lastSearchQuery = null;
      _lastSearchCount = -1;
    }

    await _runServerSearch(q);
  }

  /// 서버 검색 단일 호출. 응답은 현재 검색어와 일치할 때만 반영(레이스 방지).
  Future<void> _runServerSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    if (_lastSearchQuery == trimmed) return;
    if (!mounted) return;

    debugPrint('[PlaceWaitingScreen] runServerSearch: "$trimmed"');
    setState(() => _isSearchingServer = true);
    try {
      final results = await _firestoreService.searchPlaces(trimmed);
      if (!mounted) return;

      final currentQuery = _searchController.text.trim();
      if (currentQuery != trimmed) {
        if (mounted) setState(() => _isSearchingServer = false);
        return;
      }

      setState(() {
        _serverSearchResults = results;
        _lastSearchQuery = trimmed;
        _lastSearchCount = results.length;
        _isSearchingServer = false;
      });
      debugPrint(
        '[PlaceWaitingScreen] 검색 결과 반영: "$trimmed" → ${results.length}건',
      );
    } catch (e) {
      debugPrint('[PlaceWaitingScreen] 서버 검색 실패: $e');
      if (mounted) {
        final currentQuery = _searchController.text.trim();
        if (currentQuery == trimmed) {
          setState(() {
            _lastSearchQuery = null;
            _lastSearchCount = -1;
            _serverSearchResults = null;
            _isSearchingServer = false;
          });
        } else {
          setState(() => _isSearchingServer = false);
        }
      }
    }
  }

  /// 로컬 방문 기록 로드 (검색어 없을 때 노출용)
  Future<void> _loadVisitHistory() async {
    if (!mounted) return;
    try {
      final list = await StorageService().getVisitHistoryPlaces();
      if (mounted) setState(() => _visitHistoryPlaces = list);
    } catch (e) {
      debugPrint('[PlaceWaitingScreen] 방문 기록 로드 실패: $e');
      if (mounted) setState(() => _visitHistoryPlaces = []);
    }
  }

  /// 사용자 초기화
  Future<void> _initializeUser() async {
    try {
      _requireManualEntrySelection =
          await _authService.requiresManualEntrySelection();

      // Firebase Auth에서 현재 사용자 확인
      final firebaseUser = _authService.currentFirebaseUser;

      // ✅ 로그인 없이도 플레이스 브라우징 가능 (추천만 서버에서 조회, 전체 컬렉션 조회 안 함)
      if (firebaseUser == null) {
        setState(() => _isLoading = false);
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

  /// 멤버십 실시간 구독 시작 (enrollment + pending 통합)
  void _startMembershipSubscription() {
    if (_userId == null) return;

    // 이미 같은 userId로 구독 중이면 재구독하지 않음
    if (_membershipSubscription != null) {
      return;
    }

    final phoneNumber =
        Provider.of<AuthProvider>(
          context,
          listen: false,
        ).currentUser?.phoneNumber ??
        widget.phoneNumber;

    _membershipSubscription = _memberService
        .watchUserPlaceIdsIncludingPending(_userId!, phoneNumber: phoneNumber)
        .listen(
          (placeIds) async {
            // 플레이스 정보 가져오기 (배치 처리로 최적화)
            final placesMap = <String, Place>{};

            // 이미 로드된 플레이스는 재사용
            final placeIdsToLoad =
                placeIds
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
            final updatedPlacesMap = <String, Place>{
              ..._placesMap,
              ...placesMap,
            };

            // 접근 가능한 플레이스만 필터링
            final finalPlacesMap = <String, Place>{};
            for (final placeId in placeIds) {
              final place = updatedPlacesMap[placeId];
              if (place != null) {
                finalPlacesMap[placeId] = place;
              }
            }

            if (mounted) {
              setState(() {
                _memberPlaceIds = placeIds;
                _placesMap = finalPlacesMap;
                _isLoading = false;
              });

              // PlaceSwitchWidget용: 서버에서 조회한 placeId 목록을 AuthProvider에 반영
              final authProvider = Provider.of<AuthProvider>(
                context,
                listen: false,
              );
              authProvider.setApprovedPlaceIds(placeIds);
              debugPrint(
                '[PlaceWaitingScreen] AuthProvider.setApprovedPlaceIds: $placeIds (${placeIds.length}개)',
              );

              // ✅ linkedAdmin + adminManagedPlaceIds는 최초 1회만 조회 (스트림 재emit 시 중복 방지)
              if (!_linkedAdminLoaded) {
                _linkedAdminLoaded = true;
                final user = authProvider.currentUser;
                final phoneNumber = user?.phoneNumber;
                if (phoneNumber != null && phoneNumber.trim().isNotEmpty) {
                  try {
                    final admin = await _authService.findAdminByPhone(
                      phoneNumber,
                    );
                    if (admin != null && mounted) {
                      authProvider.setLinkedAdmin(admin);
                      final managedIds = await _firestoreService
                          .getManagedPlaceIdsByAdminId(admin.userId);
                      authProvider.setAdminManagedPlaceIds(managedIds);
                      debugPrint(
                        '[PlaceWaitingScreen] AuthProvider linkedAdmin + adminManagedPlaceIds: ${managedIds.length}개',
                      );
                    } else if (mounted) {
                      authProvider.setLinkedAdmin(null);
                      authProvider.setAdminManagedPlaceIds([]);
                    }
                  } catch (e) {
                    debugPrint('[PlaceWaitingScreen] 관리자 정보 로드 실패 (무시): $e');
                    if (mounted) {
                      authProvider.setLinkedAdmin(null);
                      authProvider.setAdminManagedPlaceIds([]);
                    }
                  }
                }
              }

              // 자동 로그인 처리 (한 번만 실행)
              // ✅ 명시적 재로그인 직후 / 설정에서 "모든 플레이스 보기" 진입 시에는 자동 진입 안 함
              if (!_requireManualEntrySelection &&
                  !_hasAutoNavigated &&
                  !widget.skipAutoEnter &&
                  placeIds.length == 1) {
                _hasAutoNavigated = true;
                final place = finalPlacesMap[placeIds.first];
                if (place != null) {
                  _navigateToMain(place);
                }
              }
            }
          },
          onDone: () {
            if (mounted) {
              _membershipSubscription = null;
            }
          },
          onError: (Object e, StackTrace st) {
            debugPrint('[PlaceWaitingScreen] membership stream error (무시): $e');
            if (mounted) {
              setState(() {
                _memberPlaceIds = [];
                _isLoading = false;
              });
            }
          },
          cancelOnError: false,
        );
  }

  /// 접근 가능한 플레이스 리스트
  List<Place> _getApprovedPlaces() {
    return _memberPlaceIds
        .map((id) => _placesMap[id])
        .where((place) => place != null)
        .cast<Place>()
        .toList();
  }

  void _onPlaceTap(Place place) async {
    // ✅ Apple App Store 가이드라인 5.1.1 준수: 세션 브라우징은 로그인 없이도 가능해야 함
    // 플레이스 선택 시 바로 메인 화면으로 이동 (세션 브라우징 가능)
    // 예약 등 계정 기반 기능은 각 화면에서 로그인 체크
    _navigateToMain(place);
  }

  void _navigateToMain(Place place) async {
    if (_isEnteringPlace) return;
    setState(() {
      _isEnteringPlace = true;
      _enteringPlaceId = place.id;
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
      // 로컬 방문 기록에 추가 (비로그인 시 목록에 노출용)
      await StorageService().addPlaceToVisitHistory(place);
      // 플레이스 선택 시 마지막 접속 플레이스로 저장
      await _authService.setCurrentPlace(place);
      // 명시적 진입 선택 완료 → 플래그 해제
      await _authService.clearRequireManualEntrySelection();

      if (!mounted) return;

      // ✅ 플레이스 존재 여부 먼저 점검 (없으면 진입 차단 + 스낵바)
      Place? existingPlace;
      try {
        existingPlace = await _firestoreService.getPlace(place.id);
      } catch (e) {
        debugPrint('[PlaceWaitingScreen] getPlace error: $e');
      }
      if (existingPlace == null) {
        await StorageService().removePlaceFromVisitHistory(place.id);
        if (mounted) {
          setState(() {
            _visitHistoryPlaces =
                _visitHistoryPlaces.where((p) => p.id != place.id).toList();
          });
          SnackbarUtil.showInfo(context, '플레이스가 존재하지 않아요');
        }
        return;
      }

      // ✅ MainScreen이 의존하는 PlaceProvider를 먼저 세팅
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      placeProvider.setCurrentPlace(place);

      // Main 진입 전 PlaceSwitchWidget용 목록 한 번 더 동기화
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      if (_memberPlaceIds.isNotEmpty) {
        authProvider.setApprovedPlaceIds(_memberPlaceIds);
      }

      // ✅ 이전 place 데이터가 남아있지 않도록 클리어 후, 새 place 데이터 로드
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
      final summaryProvider = Provider.of<ReservationSummaryProvider>(
        context,
        listen: false,
      );

      courseProvider.clear();
      storyProvider.clear();
      summaryProvider.clear();
      await reservationProvider.clear();
      await enrollmentProvider.clear();

      // ✅ 스플래시 동안 스토리 먼저 로드 시도 (실패해도 진입은 허용)
      storyProvider.loadStories(place.id);

      // 코스는 백그라운드, 예약/등록권은 첫 스냅샷까지 대기 (유저 진입 시 0회 남음 오표시 방지)
      courseProvider.loadCourses(place.id);
      final user = authProvider.currentUser;
      if (user != null) {
        await reservationProvider.loadUserReservations(
          userId: user.userId,
          placeId: place.id,
        );
        await enrollmentProvider.loadUserEnrollments(
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
          _enteringPlaceId = null;
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

  /// 로그아웃/계정삭제 옵션 바텀시트 표시
  void _showAccountOptionsBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (sheetContext) => Container(
            decoration: BoxDecoration(
              color: AppColors.backgroundWhite,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            padding: EdgeInsets.only(
              top: 20,
              bottom: 20 + MediaQuery.of(context).padding.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.borderLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 24),
                InkWell(
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _performLogout();
                  },
                  child: SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          '로그아웃',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                InkWell(
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _performDeleteAccount();
                  },
                  child: SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          '계정삭제',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.red,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  Future<void> _performLogout() async {
    if (!mounted) return;
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );
    final summaryProvider = Provider.of<ReservationSummaryProvider>(
      context,
      listen: false,
    );
    await authProvider.logout();
    memberProvider.clear();
    summaryProvider.clear();
    await reservationProvider.clear();
    await enrollmentProvider.clear();
    await _authService.clearRequireManualEntrySelection();
    if (!mounted) return;
    _membershipSubscription?.cancel();
    _membershipSubscription = null;
    _linkedAdminLoaded = false;
    setState(() {
      _userId = null;
      _memberPlaceIds = [];
      _placesMap = {};
      _isLoading = false;
      _hasAutoNavigated = false;
      _adminTargetScreen = null;
    });
    _loadVisitHistory();
    SnackbarUtil.showInfo(context, '로그아웃되었습니다');
  }

  Future<void> _performDeleteAccount() async {
    final confirmed = await CommonDialog.show(
      context: context,
      title: '회원탈퇴',
      message: '정말 탈퇴 하시겠습니까?\n모든 데이터가 삭제됩니다.',
      confirmText: '탈퇴하기',
      cancelText: '취소',
      confirmButtonColor: Colors.red,
    );
    if (confirmed != true || !mounted) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final user = authProvider.currentUser;
    if (user == null) {
      SnackbarUtil.showInfo(context, '사용자 정보를 찾을 수 없습니다.');
      return;
    }

    SnackbarUtil.showLoading(context, '탈퇴중');

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'deleteUserAccount',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
      );
      await callable.call({'userId': user.userId});
      await authProvider.logout();
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      final reservationProvider = Provider.of<ReservationProvider>(
        context,
        listen: false,
      );
      final enrollmentProvider = Provider.of<EnrollmentProvider>(
        context,
        listen: false,
      );
      final summaryProvider = Provider.of<ReservationSummaryProvider>(
        context,
        listen: false,
      );
      memberProvider.clear();
      summaryProvider.clear();
      await reservationProvider.clear();
      await enrollmentProvider.clear();
      await _authService.clearRequireManualEntrySelection();

      if (!mounted) return;
      _membershipSubscription?.cancel();
      _membershipSubscription = null;
      _linkedAdminLoaded = false;
      setState(() {
        _userId = null;
        _memberPlaceIds = [];
        _placesMap = {};
        _isLoading = false;
        _hasAutoNavigated = false;
        _adminTargetScreen = null;
      });
      _loadVisitHistory();
      SnackbarUtil.showSuccess(context, '회원탈퇴가 완료되었습니다.');
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showInfoFromError(context, e, fallback: '회원탈퇴 중 오류가 발생했습니다.');
      }
    }
  }

  /// 뒤로가기 처리
  Future<bool> _onWillPop() async {
    final firebaseUser = _authService.currentFirebaseUser;
    if (firebaseUser == null) {
      return true;
    }
    _showAccountOptionsBottomSheet();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // 핫리로드로 initState가 재호출되지 않아도 검색 리스너는 보장
    _attachSearchListenerIfNeeded();
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (!didPop) {
          await _onWillPop();
        }
      },
      child: Stack(
        children: [
          // 하단: 관리자 화면 또는 플레이스 대기 (이미 렌더된 상태에서 스플래시만 페이드아웃)
          if (_adminTargetScreen != null)
            Positioned.fill(child: _adminTargetScreen!)
          else
            Scaffold(
              backgroundColor: AppColors.backgroundWhite,
              appBar: AppBar(
                backgroundColor: AppColors.backgroundWhite,
                elevation: 0,
                scrolledUnderElevation: 0,
                leading:
                    _authService.currentFirebaseUser != null
                        ? IconButton(
                          onPressed: _showAccountOptionsBottomSheet,
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
                        )
                        : null,
                actions: [
                  if (_authService.currentFirebaseUser != null)
                    Consumer<AuthProvider>(
                      builder: (context, authProvider, _) {
                        final hasManagedPlaces =
                            authProvider.adminManagedPlaceIds.isNotEmpty;
                        final label =
                            hasManagedPlaces ? '관리자로 접속하기' : '관리자로 시작하기';
                        return TextButton(
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
                                  label,
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
                        );
                      },
                    ),
                  if (_authService.currentFirebaseUser == null)
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pushNamed('/phone-number');
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
                              '로그인',
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
              body: SafeArea(child: _buildContent()),
            ),
          // 관리자 로딩 오버레이 (페이드 아웃)
          Positioned.fill(
            child: AnimatedOpacity(
              opacity: _isAdminLoading ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: IgnorePointer(
                ignoring: !_isAdminLoading,
                child: Container(
                  color: AppColors.backgroundWhite,
                  child: const Center(child: SplashScreen()),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    // ✅ 로그인 여부에 따라 다른 플레이스 목록 (전체 컬렉션 조회 없음)
    final firebaseUser = _authService.currentFirebaseUser;
    List<Place> places;
    if (firebaseUser == null) {
      places = _visitHistoryPlaces; // 로컬 방문 기록
    } else {
      places = _getApprovedPlaces();
    }

    // 검색어 변경 시 이 블록만 리빌드 → setState 없이 카드가 사라졌다 나왔다 하지 않음
    return Column(
      children: [
        Expanded(
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder: (context, value, _) {
              final searchQuery = value.text.trim();
              final hasSearchQuery = searchQuery.isNotEmpty;
              // 검색 시 서버 검색 결과만 사용 (전체 컬렉션 조회 안 함)
              final searchPool =
                  hasSearchQuery ? (_serverSearchResults ?? []) : places;
              final localFiltered = _filterPlacesWithQuery(
                searchPool,
                searchQuery,
              );

              List<Place> filteredPlaces;
              if (!hasSearchQuery) {
                if (firebaseUser != null) {
                  // 로그인된 경우: 접속 가능한(초대된) 플레이스만 표시
                  filteredPlaces = places;
                } else {
                  // 비로그인: 로컬 방문 기록만 표시
                  filteredPlaces = _visitHistoryPlaces;
                }
              } else if (_serverSearchResults != null &&
                  _lastSearchQuery != null &&
                  searchQuery.startsWith(_lastSearchQuery!)) {
                if (searchQuery == _lastSearchQuery) {
                  final serverIds =
                      _serverSearchResults!.map((p) => p.id).toSet();
                  final localOnly =
                      localFiltered
                          .where((p) => !serverIds.contains(p.id))
                          .toList();
                  filteredPlaces = [..._serverSearchResults!, ...localOnly];
                } else {
                  // 서버 결과만 필터하면(특히 서버 결과가 비어있는 경우) "검색 결과 없음"으로 떨어질 수 있어
                  // 로컬 부분일치 결과를 항상 병합한다.
                  final serverFiltered = _filterPlacesWithQuery(
                    _serverSearchResults!,
                    searchQuery,
                  );
                  final serverIds = serverFiltered.map((p) => p.id).toSet();
                  final localOnly =
                      localFiltered
                          .where((p) => !serverIds.contains(p.id))
                          .toList();
                  filteredPlaces = [...serverFiltered, ...localOnly];
                }
              } else if (_serverSearchResults != null) {
                final serverIds =
                    _serverSearchResults!.map((p) => p.id).toSet();
                final localOnly =
                    localFiltered
                        .where((p) => !serverIds.contains(p.id))
                        .toList();
                filteredPlaces = [..._serverSearchResults!, ...localOnly];
              } else {
                filteredPlaces = localFiltered;
              }

              // 검색 시 표시할 리스트 (로그인+초대 플레이스 없어도 서버 검색 결과는 반드시 표시)
              List<Place> searchDisplayListRaw;
              if (!hasSearchQuery) {
                searchDisplayListRaw = [];
              } else if (_isSearchingServer) {
                searchDisplayListRaw = localFiltered;
              } else if (filteredPlaces.isNotEmpty) {
                searchDisplayListRaw = filteredPlaces;
              } else if (_serverSearchResults != null &&
                  _serverSearchResults!.isNotEmpty) {
                // filteredPlaces가 비어있어도 서버 결과가 있으면 사용 (로그인 상태에서 분기 누락 방지)
                if (_lastSearchQuery != null &&
                    searchQuery.startsWith(_lastSearchQuery!)) {
                  if (searchQuery == _lastSearchQuery) {
                    searchDisplayListRaw = _serverSearchResults!;
                  } else {
                    searchDisplayListRaw = _filterPlacesWithQuery(
                      _serverSearchResults!,
                      searchQuery,
                    );
                  }
                } else {
                  searchDisplayListRaw = _serverSearchResults!;
                }
              } else {
                searchDisplayListRaw = _serverSearchResults ?? [];
              }
              final searchDisplayList =
                  hasSearchQuery ? searchDisplayListRaw : null;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 검색바 (value 기준으로 suffixIcon 갱신)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.backgroundLight,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: '플레이스 이름 또는 위치로 검색',
                          hintStyle: TextStyle(
                            color: AppColors.textSecondary.withOpacity(0.6),
                            fontSize: 16,
                          ),
                          prefixIcon: Icon(
                            Icons.search,
                            color: AppColors.textSecondary.withOpacity(0.6),
                          ),
                          suffixIcon:
                              value.text.isNotEmpty
                                  ? IconButton(
                                    icon: Icon(
                                      Icons.clear,
                                      color: AppColors.textSecondary
                                          .withOpacity(0.6),
                                    ),
                                    onPressed: () {
                                      _searchController.clear();
                                      _onSearchChanged();
                                    },
                                  )
                                  : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  // 플레이스 리스트
                  Expanded(
                    child:
                        _isLoading
                            ? _buildPlaceCardShimmerList()
                            : hasSearchQuery
                            ? (_isSearchingServer
                                ? _buildPlaceCardShimmerList()
                                : (searchDisplayList != null &&
                                        searchDisplayList.isNotEmpty
                                    ? ListView.builder(
                                      key: const PageStorageKey<String>(
                                        'place_search_list',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      itemCount: searchDisplayList.length,
                                      itemBuilder: (context, index) {
                                        return _buildPlaceCard(
                                          searchDisplayList[index],
                                        );
                                      },
                                    )
                                    : _isSearchResponseReceivedForCurrentQuery(
                                      searchQuery,
                                    )
                                    ? _buildSearchEmptyPlaceholder()
                                    : _buildPlaceCardShimmerList()))
                            : (filteredPlaces.isNotEmpty
                                ? ListView.builder(
                                  key: const PageStorageKey<String>(
                                    'place_main_list',
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  itemCount: filteredPlaces.length,
                                  itemBuilder: (context, index) {
                                    return _buildPlaceCard(
                                      filteredPlaces[index],
                                    );
                                  },
                                )
                                : firebaseUser != null
                                ? (MediaQuery.of(context).viewInsets.bottom == 0
                                    ? _buildNoInvitedPlacesPlaceholder()
                                    : const SizedBox.shrink())
                                : (MediaQuery.of(context).viewInsets.bottom == 0
                                    ? _buildNoVisitHistoryPlaceholder()
                                    : const SizedBox.shrink())),
                  ),
                ],
              );
            },
          ),
        ),
        // 로그인 안 된 경우 관리자 로그인 버튼 (화면 맨 아래) — 키보드 내려갔을 때만
        if (firebaseUser == null &&
            MediaQuery.of(context).viewInsets.bottom == 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: AppColors.backgroundLight,
                border: Border(
                  top: BorderSide(
                    color: AppColors.borderLight.withOpacity(0.5),
                    width: 0.5,
                  ),
                ),
              ),
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).pushNamed('/phone-number');
                },
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '관리자로 계속하려면 로그인하세요',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                        decorationColor: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 플레이스 검색 필터링 (검색어 인자로 받음 → ValueListenableBuilder에서 사용)
  List<Place> _filterPlacesWithQuery(List<Place> places, String searchQuery) {
    final q = searchQuery.trim().toLowerCase();
    if (q.isEmpty) {
      return places;
    }
    return places.where((place) {
      final nameMatch = place.name.toLowerCase().contains(q);
      return nameMatch;
    }).toList();
  }

  /// 현재 검색어에 대해 서버 응답을 이미 받은 상태인지 (응답 대기/디바운스 중이면 false)
  /// 마지막 응답 검색어와 같거나, 그 뒤로만 입력된 경우도 true (클라이언트 필터로 결과 확정)
  bool _isSearchResponseReceivedForCurrentQuery(String searchQuery) {
    if (_lastSearchQuery == null || _serverSearchResults == null) {
      return false;
    }
    return searchQuery == _lastSearchQuery ||
        (searchQuery.startsWith(_lastSearchQuery!) &&
            searchQuery.length > _lastSearchQuery!.length);
  }

  /// 로그인된데 초대된 플레이스가 없을 때 표시
  Widget _buildNoInvitedPlacesPlaceholder() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '초대된 플레이스가 없어요',
              style: TextStyle(
                fontSize: 22,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              '플레이스 관리자에게 초대를 문의해보세요',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// 비로그인 + 방문 기록 없을 때 플레이스홀더 (키보드가 내려가 있을 때만 표시)
  Widget _buildNoVisitHistoryPlaceholder() {
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      return const SizedBox.shrink();
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '방문 기록이 없어요',
              style: TextStyle(
                fontSize: 22,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              '검색해서 플레이스를 찾아보세요',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// 검색어 입력 중 결과가 없을 때 표시하는 플레이스홀더
  Widget _buildSearchEmptyPlaceholder() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '검색 결과가 없어요',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 플레이스 카드와 동일한 레이아웃의 쉬머 카드 (로딩/검색 중)
  Widget _buildPlaceCardShimmer() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Shimmer.fromColors(
              baseColor: AppColors.textSecondary.withOpacity(0.12),
              highlightColor: AppColors.textSecondary.withOpacity(0.06),
              period: const Duration(milliseconds: 1200),
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Shimmer.fromColors(
                    baseColor: AppColors.textSecondary.withOpacity(0.12),
                    highlightColor: AppColors.textSecondary.withOpacity(0.06),
                    period: const Duration(milliseconds: 1200),
                    child: Container(
                      height: 20,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Shimmer.fromColors(
                    baseColor: AppColors.textSecondary.withOpacity(0.12),
                    highlightColor: AppColors.textSecondary.withOpacity(0.06),
                    period: const Duration(milliseconds: 1200),
                    child: Container(
                      height: 16,
                      width: 160,
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
      ),
    );
  }

  Widget _buildPlaceCardShimmerList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: 5,
      itemBuilder: (context, index) => _buildPlaceCardShimmer(),
    );
  }

  /// 플레이스 카드
  Widget _buildPlaceCard(Place place) {
    final isEnteringThis = _enteringPlaceId == place.id;
    final desc = place.description?.trim();
    final hasDescription = desc != null && desc.isNotEmpty;
    final isExpanded =
        hasDescription && _expandedDescriptionPlaceIds.contains(place.id);
    final shouldShowExpand =
        hasDescription && desc.length > _descriptionMaxCollapsed;
    final displayDesc =
        hasDescription
            ? (isExpanded
                ? desc
                : (desc.length > _descriptionMaxCollapsed
                    ? '${desc.substring(0, _descriptionMaxCollapsed)}...'
                    : desc))
            : null;

    void toggleExpand() {
      setState(() {
        if (isExpanded) {
          _expandedDescriptionPlaceIds.remove(place.id);
        } else {
          _expandedDescriptionPlaceIds.add(place.id);
        }
      });
    }

    return GestureDetector(
      onTap: _isEnteringPlace ? null : () => _onPlaceTap(place),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: const Color.fromARGB(241, 255, 255, 255),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              PlaceImageWidget(
                imageUrl: place.imageUrl,
                width: 100,
                height: 100,
                borderRadius: BorderRadius.circular(12),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 제목과 펼치기/접기 화살표를 한 줄에 정렬
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            place.name,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              overflow: TextOverflow.ellipsis,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        if (isEnteringThis)
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primaryGreen,
                            ),
                          )
                        else if (shouldShowExpand)
                          GestureDetector(
                            onTap: toggleExpand,
                            child: Icon(
                              isExpanded
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down,
                              size: 24,
                              color: AppColors.textSecondary.withOpacity(0.8),
                            ),
                          )
                        else
                          Icon(
                            Icons.arrow_forward_ios,
                            size: 16,
                            color: AppColors.textSecondary.withOpacity(0.6),
                          ),
                      ],
                    ),

                    if (displayDesc != null) ...[
                      const SizedBox(height: 6),
                      ConstrainedBox(
                        constraints: BoxConstraints(minHeight: 13 * 1.35 * 2),
                        child: Text(
                          displayDesc,
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                            height: 1.35,
                          ),
                          maxLines:
                              (isExpanded || !shouldShowExpand) ? null : 2,
                          overflow:
                              (isExpanded || !shouldShowExpand)
                                  ? null
                                  : TextOverflow.ellipsis,
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

  /// 관리자 진입 처리 (PIN 없음)
  /// - 관리 플레이스가 있으면 → 어드민 화면(/admin)으로
  /// - 없으면 → 플레이스 등록 화면으로
  Future<void> _handleAdminLogin() async {
    try {
      String? phoneNumber;
      final firebaseUser = _authService.currentFirebaseUser;
      if (firebaseUser != null) {
        phoneNumber = firebaseUser.phoneNumber;
      }

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
            Navigator.of(
              context,
            ).pushNamedAndRemoveUntil('/phone-number', (route) => false);
          }
        }
        return;
      }

      phoneNumber = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
      if (phoneNumber.startsWith('82')) {
        phoneNumber = '0${phoneNumber.substring(2)}';
      } else if (!phoneNumber.startsWith('0')) {
        phoneNumber = '0$phoneNumber';
      }

      final admin = await _authService.findAdminByPhone(phoneNumber);
      final managedIds =
          admin != null
              ? await _firestoreService.getManagedPlaceIdsByAdminId(
                admin.userId,
              )
              : <String>[];

      if (!mounted) return;
      if (admin != null && managedIds.isNotEmpty) {
        final splashStartedAt = DateTime.now();
        setState(() => _isAdminLoading = true);

        final authProvider = Provider.of<AuthProvider>(context, listen: false);
        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final courseProvider = Provider.of<CourseProvider>(
          context,
          listen: false,
        );
        final storyProvider = Provider.of<StoryProvider>(
          context,
          listen: false,
        );
        final memberProvider = Provider.of<MemberProvider>(
          context,
          listen: false,
        );

        authProvider.setLinkedAdmin(admin);
        authProvider.setAdminManagedPlaceIds(managedIds);

        final lastPlaceId = await _authService.getLastAccessedPlaceId();
        final placeId =
            lastPlaceId != null && managedIds.contains(lastPlaceId)
                ? lastPlaceId
                : managedIds.first;

        try {
          await placeProvider.loadPlace(placeId);
          final place = placeProvider.currentPlace;
          if (place != null && mounted) {
            placeProvider.setCurrentPlace(place);
            await _authService.updateLastAccessedPlace(place.id);
            memberProvider.setPlaceId(place.id);
            await Future.wait([
              courseProvider.loadCourses(place.id),
              storyProvider.loadStories(place.id),
            ]);
          }
        } catch (e) {
          debugPrint('[PlaceWaitingScreen] 관리자 진입 데이터 로드 실패: $e');
        }

        if (!mounted) return;
        // 스플래시 최소 2초 보장
        final elapsed = DateTime.now().difference(splashStartedAt);
        if (elapsed < _adminSplashMinDuration) {
          await Future.delayed(_adminSplashMinDuration - elapsed);
        }
        if (!mounted) return;
        // 이미 렌더된 AdminScreen 위에 스플래시만 페이드아웃 (옆에서 슬라이드 없음)
        setState(() {
          _adminTargetScreen = const AdminScreen();
          _isAdminLoading = false;
        });
      } else {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder:
                (context) => AdminPlaceRegistrationScreen(
                  phoneNumber: phoneNumber,
                  isFromLogin: true,
                ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showInfo(context, '관리자 정보를 불러올 수 없습니다: $e');
      }
    }
  }
}
