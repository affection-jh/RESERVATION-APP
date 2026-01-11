import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../widgets/compact_calendar_widget.dart';
import '../models/course.dart';
import '../models/reservation.dart';
import '../models/course_enrollment.dart';
import '../widgets/user_reservation_manage_bottom_sheet.dart';
import '../widgets/enrollment_detail_bottom_sheet.dart';
import '../widgets/profile_edit_bottom_sheet.dart';
import '../widgets/place_switch_widget.dart';
import '../widgets/profile_settings_widget.dart'
    show UserProfileInfoSection, SettingsItemsBuilder;
import '../widgets/notification_settings_dialog.dart';
import '../providers/reservation_provider.dart';
import '../providers/course_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/place_provider.dart';

import '../providers/enrollment_provider.dart';
import '../utils/snackbar_util.dart';
import '../widgets/cached_image_widget.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:async';

class MyPageScreen extends StatefulWidget {
  final Map<String, dynamic>? highlightReservation; // 강조할 예약 정보

  const MyPageScreen({super.key, this.highlightReservation});

  @override
  State<MyPageScreen> createState() => _MyPageScreenState();
}

class _MyPageScreenState extends State<MyPageScreen> {
  bool _shouldHighlightReservation = false;
  Reservation? _highlightedReservation;
  Course? _highlightedCourse;
  CourseSession? _highlightedSession;
  DateTime? _highlightedDate;
  // _isPlaceListExpanded: 현재 화면에서는 사용되지 않음 (필요 시 다시 추가)
  StreamSubscription<ReservationOperationEvent>? _reservationOpSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _init();
      _subscribeReservationOperationEvents();
    });
  }

  void _subscribeReservationOperationEvents() {
    _reservationOpSub?.cancel();
    final rp = Provider.of<ReservationProvider>(context, listen: false);
    _reservationOpSub = rp.operationEvents.listen((event) async {
      // 마이페이지에서는 특히 "취소 성공" 피드백이 중요 (바텀시트가 닫혀 있어도)
      if (event.type == ReservationOperationType.cancel &&
          event.success == true &&
          event.reservation != null) {
        if (!mounted) return;
        final r = event.reservation!;
        try {
          await Provider.of<EnrollmentProvider>(
            context,
            listen: false,
          ).loadUserEnrollments(userId: r.userId, placeId: r.placeId);
          await Provider.of<ReservationProvider>(
            context,
            listen: false,
          ).loadUserReservations(userId: r.userId, placeId: r.placeId);
        } catch (_) {}
        SnackbarUtil.showSuccess(context, '예약이 취소되었습니다.');
      }
    });
  }

  @override
  void dispose() {
    _reservationOpSub?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    await _loadData();
    if (!mounted) return;
    if (widget.highlightReservation != null) {
      _processHighlightReservationWithRetry();
    }
  }

  Future<void> _loadData() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );

    // 사용자 정보 확인
    if (authProvider.currentUser == null) return;

    // PlaceProvider에 현재 플레이스가 있는지 확인
    var currentPlace = placeProvider.currentPlace;

    // 플레이스가 없으면 placeMemberships에서 첫 번째 플레이스 로드
    if (currentPlace == null) {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final approvedPlaceIds = authProvider.approvedPlaceIds;
      if (approvedPlaceIds.isNotEmpty) {
        final firstPlaceId = approvedPlaceIds.first;
        await placeProvider.loadPlace(firstPlaceId);
        currentPlace = placeProvider.currentPlace;
      }
    }

    if (currentPlace == null) return;

    try {
      // 코스가 로드되지 않았으면 로드
      if (courseProvider.courses.isEmpty) {
        await courseProvider.loadCourses(currentPlace.id);
      }

      // 예약이 로드되지 않았으면 로드
      if (reservationProvider.reservations.isEmpty) {
        await reservationProvider.loadUserReservations(
          userId: authProvider.currentUser!.userId,
          placeId: currentPlace.id,
        );
      }

      // enrollment 로드 (정책 엔진에 반영)
      await enrollmentProvider.loadUserEnrollments(
        userId: authProvider.currentUser!.userId,
        placeId: currentPlace.id,
      );
    } catch (e) {
      // 에러 발생 시에도 계속 진행
    }
  }

  void _processHighlightReservationWithRetry([int attempt = 0]) {
    if (!mounted) return;
    if (widget.highlightReservation == null) return;
    if (attempt > 10) return; // 0.2s * 10 = 최대 ~2초 대기

    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final reservationInfo = widget.highlightReservation!;
    final userReservations = reservationProvider.reservations;

    final DateTime targetDate = reservationInfo['reservedDate'] as DateTime;
    final Reservation? match = userReservations.cast<Reservation?>().firstWhere(
      (r) =>
          r != null &&
          r.courseId == reservationInfo['courseId'] &&
          r.dayOfWeek == reservationInfo['dayOfWeek'] &&
          r.startTime == reservationInfo['startTime'] &&
          r.reservedDate.year == targetDate.year &&
          r.reservedDate.month == targetDate.month &&
          r.reservedDate.day == targetDate.day,
      orElse: () => null,
    );

    if (match == null) {
      Future.delayed(const Duration(milliseconds: 200), () {
        _processHighlightReservationWithRetry(attempt + 1);
      });
      return;
    }

    _processHighlightReservation();
  }

  // 사용자가 예약한 코스만 필터링
  List<Course> _getUserCourses(
    List<Reservation> reservations,
    List<Course> courses,
  ) {
    final reservedCourseIds = reservations.map((r) => r.courseId).toSet();

    // 예약한 코스만 필터링
    return courses.where((course) {
      return reservedCourseIds.contains(course.id);
    }).toList();
  }

  // 강조할 예약 처리
  void _processHighlightReservation() {
    if (widget.highlightReservation == null) return;

    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final userReservations = reservationProvider.reservations;
    final courses = courseProvider.courses;

    // 예약 찾기
    final reservationInfo = widget.highlightReservation!;
    final reservation = userReservations.firstWhere(
      (r) =>
          r.courseId == reservationInfo['courseId'] &&
          r.dayOfWeek == reservationInfo['dayOfWeek'] &&
          r.startTime == reservationInfo['startTime'] &&
          r.reservedDate.year ==
              (reservationInfo['reservedDate'] as DateTime).year &&
          r.reservedDate.month ==
              (reservationInfo['reservedDate'] as DateTime).month &&
          r.reservedDate.day ==
              (reservationInfo['reservedDate'] as DateTime).day,
      orElse: () => userReservations.isNotEmpty
          ? userReservations.first
          : Reservation(
              id: '',
              userId: '',
              courseId: '',
              placeId: '',
              dayOfWeek: 0,
              startTime: '',
              reservedAt: DateTime.now(),
              reservedDate: DateTime.now(),
            ),
    );

    final course = courses.firstWhere(
      (c) => c.id == reservation.courseId,
      orElse: () => courses.isNotEmpty
          ? courses.first
          : Course(
              description: '',
              id: reservation.courseId,
              name: '',
              color: 0xFF087044,
              sessions: [],
            ),
    );

    final session = course.findSession(
      reservation.dayOfWeek,
      reservation.startTime,
    );

    if (session == null) return;

    setState(() {
      _shouldHighlightReservation = true;
      _highlightedReservation = reservation;
      _highlightedCourse = course;
      _highlightedSession = session;
      _highlightedDate = reservation.reservedDate;
    });

    // 애니메이션 후 바텀시트 표시
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() {
          _shouldHighlightReservation = false;
        });
        _showReservationBottomSheet();
      }
    });
  }

  // 예약 바텀시트 표시
  void _showReservationBottomSheet() {
    if (_highlightedCourse == null ||
        _highlightedSession == null ||
        _highlightedDate == null)
      return;

    UserReservationManageBottomSheet.show(
      context: context,
      course: _highlightedCourse!,
      session: _highlightedSession!,
      date: _highlightedDate!,
      reservation: _highlightedReservation,
      onReservationCancelled: () {
        setState(() {});
      },
    );
  }

  // 세션 클릭 핸들러
  void _onSessionTap(Course course, CourseSession session, DateTime date) {
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    final userReservations = reservationProvider.reservations;

    // 해당 세션의 사용자 예약 찾기
    final reservation = userReservations.firstWhere(
      (r) =>
          r.courseId == course.id &&
          r.dayOfWeek == session.dayOfWeek &&
          r.startTime == session.startTime &&
          r.reservedDate.year == date.year &&
          r.reservedDate.month == date.month &&
          r.reservedDate.day == date.day,
      orElse: () {
        final placeId = placeProvider.currentPlace?.id ?? '';
        final userId = authProvider.currentUser?.userId ?? '';
        return Reservation(
          id: '',
          userId: userId,
          courseId: course.id,
          placeId: placeId,
          dayOfWeek: session.dayOfWeek,
          startTime: session.startTime,
          reservedAt: DateTime.now(),
          reservedDate: date,
        );
      },
    );

    // 예약 관리 바텀시트 표시
    UserReservationManageBottomSheet.show(
      context: context,
      course: course,
      session: session,
      date: date,
      reservation:
          userReservations.any(
            (r) =>
                r.courseId == course.id &&
                r.dayOfWeek == session.dayOfWeek &&
                r.startTime == session.startTime &&
                r.reservedDate.year == date.year &&
                r.reservedDate.month == date.month &&
                r.reservedDate.day == date.day,
          )
          ? reservation
          : null,
      onReservationCancelled: () {
        setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final reservationProvider = Provider.of<ReservationProvider>(context);
    final courseProvider = Provider.of<CourseProvider>(context);

    final userReservations = reservationProvider.reservations;
    final userCourses = _getUserCourses(
      userReservations,
      courseProvider.courses,
    );

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: SafeArea(
        child: Column(
          children: [
            // 메인 콘텐츠
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 플레이스 정보
                    _buildPlaceInfoSection(),

                    const SizedBox(height: 34),

                    // 제목
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Text(
                            '내 예약 현황',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryGreen,
                            ),
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // 예약이 없을 때
                    if (userReservations.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Container(
                          padding: const EdgeInsets.all(40),
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: AppColors.backgroundWhite,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            children: [
                              const SizedBox(height: 8),

                              Text(
                                '예약 내역이 없어요',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: AppColors.textSecondary.withOpacity(
                                    0.6,
                                  ),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      )
                    else
                      // 캘린더 위젯 (일정보기 모드) - 카드 스타일
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.backgroundWhite,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: CompactCalendarWidget(
                            courses: userCourses,
                            usage:
                                CompactCalendarUsage.userWeeklyReservationsView,
                            weekOffset: 0,
                            height: 500, // 마이페이지에서는 더 큰 높이
                            onSessionTap: _onSessionTap,
                            hideCourseSelector: true, // 일정보기 모드에서는 드롭다운 숨김
                            weeklyViewMode: true, // 일정보기 모드 활성화
                            userReservations: userReservations, // 사용자 예약 리스트 전달
                            highlightReservation:
                                _shouldHighlightReservation &&
                                    _highlightedReservation != null &&
                                    _highlightedCourse != null &&
                                    _highlightedSession != null &&
                                    _highlightedDate != null
                                ? {
                                    'reservationId':
                                        _highlightedReservation!.id,
                                    'courseId': _highlightedCourse!.id,
                                    'dayOfWeek': _highlightedSession!.dayOfWeek,
                                    'startTime': _highlightedSession!.startTime,
                                    'reservedDate': _highlightedDate!,
                                  }
                                : null,
                          ),
                        ),
                      ),

                    const SizedBox(height: 32),

                    // 수강 중인 코스 섹션
                    _buildEnrolledCoursesSection(),

                    const SizedBox(height: 32),

                    // 마이프로필 섹션
                    Builder(
                      builder: (context) {
                        final authProvider = Provider.of<AuthProvider>(context);
                        final user = authProvider.currentUser;
                        final isNotificationEnabled =
                            user?.notificationsEnabled ?? true;

                        return UserProfileInfoSection(
                          headerTitle: '마이프로필',
                          profileName: user?.name ?? '사용자',
                          profilePhoneNumber: user?.phoneNumber ?? '',
                          onProfileTap: () {
                            if (user != null) {
                              ProfileEditBottomSheet.show(
                                context: context,
                                currentName: user.name,
                              ).then((result) {
                                if (result == true && context.mounted) {
                                  // 정보 변경 후 화면 새로고침
                                  setState(() {});
                                }
                              });
                            }
                          },
                          profileBottomWidget: const PlaceSwitchWidget(),
                          settingsItems: SettingsItemsBuilder.buildSettingsItems(
                            context: context,
                            isNotificationEnabled: isNotificationEnabled,
                            onNotificationTap: () async {
                              final result =
                                  await NotificationSettingsDialog.show(
                                    context: context,
                                    initialValue: isNotificationEnabled,
                                  );
                              if (result == true && context.mounted) {
                                // 다이얼로그에서 설정이 변경되었으면 화면 새로고침
                                setState(() {});
                              }
                            },
                            onLogout: () async {
                              await authProvider.logout();
                            },
                            onWithdraw: () async {
                              try {
                                final authProvider = Provider.of<AuthProvider>(
                                  context,
                                  listen: false,
                                );
                                final user = authProvider.currentUser;

                                if (user == null) {
                                  SnackbarUtil.showError(
                                    context,
                                    '사용자 정보를 찾을 수 없습니다.',
                                  );
                                  return;
                                }

                                // 유저 계정 삭제 (모든 플레이스에서 제거 + Firebase Auth 삭제)
                                final functions = FirebaseFunctions.instance;
                                final deleteAccountCallable = functions
                                    .httpsCallable('deleteUserAccount');

                                await deleteAccountCallable.call({
                                  'userId': user.userId,
                                });

                                // 로그아웃 처리
                                await authProvider.logout();

                                if (context.mounted) {
                                  SnackbarUtil.showSuccess(
                                    context,
                                    '회원탈퇴가 완료되었습니다.',
                                  );
                                  Navigator.pushNamedAndRemoveUntil(
                                    context,
                                    '/',
                                    (route) => false,
                                  );
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  SnackbarUtil.showError(
                                    context,
                                    '회원탈퇴 중 오류가 발생했습니다.',
                                  );
                                }
                              }
                            },
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 플레이스 정보 섹션
  Widget _buildPlaceInfoSection() {
    return const PlaceSwitchWidget(enabled: true, showDescription: true);
  }

  // 수강 중인 코스 섹션
  Widget _buildEnrolledCoursesSection() {
    final courseProvider = Provider.of<CourseProvider>(context);
    final enrollmentProvider = Provider.of<EnrollmentProvider>(context);
    final courses = courseProvider.courses;

    // 유효기간 내 등록 정보만 표시 (남은 횟수 0이어도 "수강 중"은 유지되어야 함)
    final validEnrollments =
        enrollmentProvider.enrollments.where((e) => e.isValid).toList()
          ..sort((a, b) => a.validUntil.compareTo(b.validUntil));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 섹션 제목
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '수강 중인 코스',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryGreen,
            ),
          ),
        ),
        const SizedBox(height: 6),
        if (validEnrollments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: BoxDecoration(
                color: AppColors.backgroundWhite,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '수강 중인 코스가 없어요',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary.withOpacity(0.7),
                ),
              ),
            ),
          )
        else
          // 코스 카드 리스트
          ...validEnrollments.map((enrollment) {
            // 코스 정보 찾기 (데이터 정합성 보장)
            final course = courses.firstWhere(
              (c) => c.id == enrollment.courseId,
              orElse: () => Course(
                id: enrollment.courseId,
                name: '알 수 없는 코스',
                description: '',
                color: 0xFF087044,
                sessions: [],
              ),
            );
            return _buildEnrolledCourseCard(course, enrollment);
          }).toList(),
      ],
    );
  }

  // 수강 중인 코스 카드
  Widget _buildEnrolledCourseCard(Course course, CourseEnrollment enrollment) {
    // 재등록 필요 여부 확인
    final needsReenrollment =
        enrollment.isExpired || enrollment.remainingReservations == 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            _showEnrollmentDetailBottomSheet(course, enrollment);
          },
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    // 코스 이미지
                    CourseImageWidget(
                      imageUrl: course.imageUrl,
                      width: 100,
                      height: 100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    const SizedBox(width: 16),
                    // 코스 정보
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 코스 이름
                          SizedBox(height: 6),
                          Text(
                            course.name,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryGreen,
                              letterSpacing: -0.5,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),

                          // 코스 설명
                          Padding(
                            padding: const EdgeInsets.only(right: 10, top: 4),
                            child: Text(
                              course.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                color: AppColors.primaryGreen.withOpacity(0.8),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 재등록 필요 칩 (오른쪽 상단)
              if (needsReenrollment)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.reservedGrey.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '재등록 필요',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.reservedTextGrey,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // 등록 상세 정보 바텀시트 표시
  void _showEnrollmentDetailBottomSheet(
    Course course,
    CourseEnrollment enrollment,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      builder: (context) => EnrollmentDetailBottomSheet(
        course: course,
        enrollment: enrollment,
        onExtensionRequested: () {
          setState(() {});
        },
      ),
    );
  }
}
