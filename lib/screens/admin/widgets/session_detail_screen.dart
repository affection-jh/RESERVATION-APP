import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:provider/provider.dart';
import 'package:reservation/services/user_service.dart';
import '../../../models/course.dart';
import '../../../models/reservation.dart';
import '../../../models/user.dart';
import '../../../theme/app_colors.dart';
import '../../../services/firestore_service.dart';
import '../../../providers/auth_provider.dart';
import '../../../widgets/common_dialog.dart';
import 'reservation_manage_bottom_sheet.dart';
import 'member_selection_side_panel.dart';
import '../../../utils/snackbar_util.dart';
import 'dart:async';

/// 세션 상세보기 화면
class SessionDetailScreen extends StatefulWidget {
  final Course course;
  final CourseSession session;
  final DateTime date;
  final String placeId;

  const SessionDetailScreen({
    super.key,
    required this.course,
    required this.session,
    required this.date,
    required this.placeId,
  });

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  Map<String, User> _userCache = {};
  bool _isLoading = false;
  Map<String, bool> _copiedPhones = {}; // 전화번호 복사 상태 관리
  List<Reservation> _dateReservations = [];
  StreamSubscription<List<Reservation>>? _reservationsSub;
  bool _adminForceAddApproved = false; // 강제 추가를 한 번 승인하면 같은 화면에서는 재확인 최소화

  @override
  void initState() {
    super.initState();
    _listenReservations();
  }

  @override
  void dispose() {
    _reservationsSub?.cancel();
    super.dispose();
  }

  void _listenReservations() {
    _reservationsSub?.cancel();
    _reservationsSub = _firestoreService
        .watchSessionReservations(
          placeId: widget.placeId,
          courseId: widget.course.id,
          dayOfWeek: widget.session.dayOfWeek,
          startTime: widget.session.startTime,
          date: widget.date,
        )
        .listen((reservations) async {
          if (!mounted) return;
          setState(() {
            _dateReservations = reservations
              ..sort((a, b) => a.reservedAt.compareTo(b.reservedAt));
          });
          await _loadUserDataFor(_dateReservations);
        });
  }

  Future<void> _loadUserDataFor(List<Reservation> reservations) async {
    setState(() => _isLoading = true);
    for (final reservation in reservations) {
      if (_userCache.containsKey(reservation.userId)) continue;
      try {
        final userService = UserService();
        final user = await userService.getUser(reservation.userId);
        if (mounted) {
          setState(() {
            _userCache[reservation.userId] = user;
          });
        }
      } catch (_) {
        // ignore
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  void _refreshReservations() {
    // watchSessionReservations가 최신 상태를 반영하므로 별도 처리 불필요
  }

  @override
  Widget build(BuildContext context) {
    final totalCapacity = widget.session.getCapacityForDate(widget.date);
    final dateReservations = _dateReservations;
    final reservedCount = _dateReservations.length;
    final progress = totalCapacity > 0 ? reservedCount / totalCapacity : 0.0;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.backgroundWhite,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            // 날짜/요일/시간 칩 섹션
            _buildChipSection(),

            const SizedBox(height: 16),

            // 예약 상세 정보 (게이지)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _buildInfoItem(
                          label: '수용 인원',
                          value: '$totalCapacity명',
                        ),
                      ),
                      Expanded(
                        child: _buildInfoItem(
                          label: '예약 현황',
                          value: '$reservedCount명 / $totalCapacity명',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 13),
                  // 진행 바
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                      backgroundColor: AppColors.borderLight,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Color(widget.course.color),
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),

            // 예약자 명단
            Expanded(
              child: Container(
                width: double.infinity,
                color: AppColors.backgroundWhite,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 16),
                    Expanded(
                      child: _isLoading
                          ? Center(child: CircularProgressIndicator())
                          : dateReservations.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '아직 예약자가 없어요',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              itemCount: dateReservations.length,
                              separatorBuilder: (context, index) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final reservation = dateReservations[index];
                                return _buildReservistItem(
                                  index: index + 1,
                                  reservation: reservation,
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final totalCapacity = widget.session.getCapacityForDate(widget.date);
    final reservedCount = _dateReservations.length;

    return AppBar(
      backgroundColor: AppColors.backgroundWhite,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios, color: AppColors.primaryGreen),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: Text(
        widget.course.name,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: AppColors.textPrimary,
        ),
      ),
      actions: [
        // 세션 취소 버튼 (관리자만)
        if (Provider.of<AuthProvider>(context, listen: false).currentAdmin !=
            null)
          IconButton(
            icon: Icon(Icons.cancel, color: Colors.red, size: 32),
            onPressed: () => _cancelSession(),
            tooltip: '세션 취소',
          ),
        // 예약자 추가 버튼
        IconButton(
          icon: Icon(Icons.add_circle, color: AppColors.primaryGreen, size: 32),
          onPressed: () => MemberSelectionSidePanel.show(
            context: context,
            course: widget.course,
            totalCapacity: totalCapacity,
            reservedCount: reservedCount,
            existingReservationUserIds: _dateReservations
                .map((r) => r.userId)
                .toList(),
            onMembersSelected: (users) {
              // 여러 명 선택 시에도 네트워크 호출/다이얼로그가 겹치지 않게 순차 처리
              () async {
                await _addReservationsForUsers(users);
              }();
            },
          ),
          tooltip: '예약자 추가',
        ),
        SizedBox(width: 16),
      ],
    );
  }

  Widget _buildChipSection() {
    final dateText = '${widget.date.month}월 ${widget.date.day}일';
    final dayName = widget.session.dayName;
    final timeRange = '${widget.session.startTime} - ${widget.session.endTime}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildWhiteChip('$dateText $dayName요일'),
          const SizedBox(width: 8),
          _buildWhiteChip(timeRange),
        ],
      ),
    );
  }

  Widget _buildWhiteChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildInfoItem({required String label, required String value}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.primaryGreen,
          ),
        ),
      ],
    );
  }

  Widget _buildReservistItem({
    required int index,
    required Reservation reservation,
  }) {
    final user = _userCache[reservation.userId];
    final userName = user?.name ?? '예약자 $index';
    final phoneNumber = user?.phoneNumber ?? '010-0000-0000';

    return InkWell(
      onTap: () =>
          _showReservationManageBottomSheet(context, reservation, user),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            // 예약자 정보
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    userName,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        phoneNumber,
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          // 클립보드에 복사
                          Clipboard.setData(ClipboardData(text: phoneNumber));
                          setState(() {
                            _copiedPhones[reservation.id] = true;
                          });
                          // 2초 후 다시 복사 아이콘으로 변경
                          Future.delayed(const Duration(seconds: 2), () {
                            if (mounted) {
                              setState(() {
                                _copiedPhones[reservation.id] = false;
                              });
                            }
                          });
                        },
                        child: Icon(
                          _copiedPhones[reservation.id] == true
                              ? Icons.check
                              : Icons.copy_all,
                          size: 18,
                          color: _copiedPhones[reservation.id] == true
                              ? AppColors.primaryGreen
                              : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.primaryGreen, size: 30),
          ],
        ),
      ),
    );
  }

  void _showReservationManageBottomSheet(
    BuildContext context,
    Reservation reservation,
    User? user,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      builder: (context) => ReservationManageBottomSheet(
        course: widget.course,
        session: widget.session,
        date: widget.date,
        reservation: reservation,
        user: user,
        onReservationCancelled: () {
          _refreshReservations();
          Navigator.of(context).pop();
        },
        onReservationChanged: () {
          _refreshReservations();
          Navigator.of(context).pop();
        },
      ),
    );
  }

  Future<bool> _addReservationForUser(User user, {bool force = false}) async {
    try {
      final newReservation = Reservation(
        id: '',
        userId: user.userId,
        courseId: widget.course.id,
        placeId: widget.placeId,
        dayOfWeek: widget.session.dayOfWeek,
        startTime: widget.session.startTime,
        reservedAt: DateTime.now(),
        reservedDate: widget.date,
      );

      await _firestoreService.createReservation(newReservation, force: force);
      return true;
    } on FirebaseFunctionsException catch (e) {
      final details = e.details;
      final detailsMap = details is Map
          ? Map<String, dynamic>.from(details)
          : null;
      final requiresForce = detailsMap?['requiresForce'] == true;

      if (requiresForce) {
        // 한 번 승인했으면 같은 화면에서는 재확인 최소화
        if (_adminForceAddApproved && !force) {
          return await _addReservationForUser(user, force: true);
        }

        final reason = (detailsMap?['reason'] as String?) ?? '';
        final openAt = (detailsMap?['openAt'] as String?) ?? '';
        final capacity = detailsMap?['capacity'];
        final reservedCount = detailsMap?['reservedCount'];
        final closeBeforeMinutes = detailsMap?['closeBeforeMinutes'];

        String message = e.message ?? '정책상 예약이 제한됩니다.';
        if (reason == 'full') {
          message =
              '정원 마감 상태입니다. 관리자 권한으로 강제 추가하시겠습니까?\n\n현재: $reservedCount / $capacity';
        } else if (reason == 'notOpenedYet') {
          message =
              '아직 예약 오픈 전입니다. 관리자 권한으로 강제 추가하시겠습니까?'
              '${openAt.isNotEmpty ? '\n\n오픈 예정: $openAt' : ''}';
        } else if (reason == 'closedBeforeStart') {
          message =
              '세션 시작 임박으로 예약이 마감되었습니다. 관리자 권한으로 강제 추가하시겠습니까?\n\n마감 기준: 시작 ${closeBeforeMinutes ?? 60}분 전';
        }

        final confirmed = await CommonDialog.show(
          context: context,
          title: '관리자 강제 추가',
          message: message,
          cancelText: '취소',
          confirmText: '강제 추가',
          confirmButtonColor: Colors.red,
        );

        if (confirmed == true) {
          _adminForceAddApproved = true;
          return await _addReservationForUser(user, force: true);
        }
        return false;
      }

      if (mounted) {
        SnackbarUtil.showError(context, e.message ?? '예약 추가에 실패했습니다.');
      }
      return false;
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '예약 추가 중 오류가 발생했습니다: $e');
      }
      return false;
    }
  }

  Future<void> _addReservationsForUsers(List<User> users) async {
    if (users.isEmpty) return;
    setState(() => _isLoading = true);
    int success = 0;
    for (final user in users) {
      if (!mounted) break;
      final ok = await _addReservationForUser(user);
      if (ok) success++;
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
    if (success > 0) {
      SnackbarUtil.showSuccess(context, '$success명 예약이 추가되었습니다.');
    }
  }

  /// 세션 취소 (관리자)
  Future<void> _cancelSession() async {
    final reservedCount = _dateReservations.length;
    final courseName = widget.course.name;
    final dayName = widget.session.dayName;
    final timeRange = '${widget.session.startTime} - ${widget.session.endTime}';
    final dateText = '${widget.date.month}월 ${widget.date.day}일';

    // 예약자가 있는 경우 확인
    if (reservedCount > 0) {
      final confirmed = await CommonDialog.show(
        context: context,
        title: '세션 취소',
        message:
            '$dateText $dayName요일 $timeRange\n$courseName\n\n$reservedCount명의 기존 예약자에게 알림이 발송됩니다.',
        cancelText: '취소',
        confirmText: '세션 취소',
        confirmButtonColor: Colors.red,
      );

      if (confirmed != true) {
        return;
      }
    } else {
      // 예약자가 없는 경우에도 확인
      final confirmed = await CommonDialog.show(
        context: context,
        title: '세션 취소',
        message:
            '$dateText $dayName요일 $timeRange\n$courseName\n\n이 세션을 취소하시겠습니까?',
        cancelText: '취소',
        confirmText: '세션 취소',
        confirmButtonColor: Colors.red,
      );

      if (confirmed != true) {
        return;
      }
    }

    setState(() => _isLoading = true);
    try {
      await _firestoreService.cancelSession(
        placeId: widget.placeId,
        courseId: widget.course.id,
        dayOfWeek: widget.session.dayOfWeek,
        startTime: widget.session.startTime,
        reservedDate: widget.date,
      );

      if (mounted) {
        SnackbarUtil.showSuccess(context, '세션이 취소되었습니다. 모든 예약자에게 알림이 전송되었습니다.');
        Navigator.of(context).pop(true); // 세션 취소 후 화면 닫기
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '세션 취소 중 오류가 발생했습니다: $e');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}
