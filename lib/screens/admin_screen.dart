import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../widgets/admin_bottom_nav_bar.dart';
import 'admin/admin_home_screen.dart';
import 'admin/admin_member_screen.dart';
import 'admin/admin_my_page_screen.dart';
import '../providers/auth_provider.dart';
import '../providers/place_provider.dart';
import '../providers/course_provider.dart';
import '../providers/story_provider.dart';
import '../services/auth_service.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  int _currentIndex = 0;
  bool _isInitialDataLoaded = false;

  final List<Widget> _tabs = const [
    AdminHomeScreen(),
    AdminMemberScreen(),
    AdminMyPageScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // 빌드 완료 후 데이터 로드 (setState during build 에러 방지)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadInitialData();
    });
  }

  /// 초기 데이터 일괄 로드
  Future<void> _loadInitialData() async {
    if (_isInitialDataLoaded) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final storyProvider = Provider.of<StoryProvider>(context, listen: false);

    if (authProvider.currentAdmin == null) return;

    try {
      await authProvider.loadPlaceMembershipsForCurrentUser();
      final placeIds =
          authProvider.placeAccessEntries
              .where((e) => e.isAdmin)
              .map((e) => e.placeId)
              .toSet()
              .toList();
      if (placeIds.isEmpty) return;

      // PlaceSwitch 전환 시 이미 설정된 currentPlace 우선 (마지막 접속으로 롤백 방지)
      final existingPlace = placeProvider.currentPlace;
      String placeId;
      if (existingPlace != null &&
          authProvider.hasAdminAccessToPlace(existingPlace.id)) {
        placeId = existingPlace.id;
      } else {
        final lastPlaceId = await AuthService().getLastAccessedPlaceId();
        placeId = authProvider.currentAdmin?.currentPlaceId ??
            lastPlaceId ??
            placeIds.first;
      }

      // 플레이스 로드 (이미 있으면 loadPlace가 동일 ID로 처리)
      await placeProvider.loadPlace(placeId);

      final currentPlace = placeProvider.currentPlace;
      if (currentPlace == null) return;

      // MemberProvider 구독은 AdminMemberScreen 등 멤버 목록 필요한 화면에서만 시작 (비용 절감)
      // 모든 데이터를 병렬로 로드
      await Future.wait([
        courseProvider.loadCourses(currentPlace.id),
        storyProvider.loadStories(currentPlace.id),
      ]);

      _isInitialDataLoaded = true;
    } catch (e) {
      // 에러 발생 시에도 계속 진행 (각 화면에서 개별 처리)
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: SafeArea(
        // IndexedStack을 사용하여 모든 탭의 상태를 유지 (탭 전환 시 재생성 방지)
        child: IndexedStack(index: _currentIndex, children: _tabs),
      ),
      bottomNavigationBar: AdminBottomNavBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
      ),
    );
  }
}
