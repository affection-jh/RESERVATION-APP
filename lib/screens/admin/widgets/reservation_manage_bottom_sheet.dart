import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/course.dart';
import '../../../models/reservation.dart';
import '../../../models/user.dart';
import '../../../theme/app_colors.dart';
import '../../../services/reservation_service.dart';
import '../../../providers/reservation_provider.dart';
import '../../../widgets/compact_calendar_widget.dart';
import 'admin_shared_widgets.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/format_utils.dart';
import '../../../widgets/common_dialog.dart';

/// 예약 관리 바텀시트 (예약 취소, 변경, 추가)
class ReservationManageBottomSheet extends StatefulWidget {
  final Course course;
  final CourseSession session;
  final DateTime date;
  final Reservation? reservation; // null이면 추가 모드
  final User? user; // 예약자 정보
  final VoidCallback? onReservationCancelled;
  final VoidCallback? onReservationChanged;
  final VoidCallback? onReservationAdded;

  const ReservationManageBottomSheet({
    super.key,
    required this.course,
    required this.session,
    required this.date,
    this.reservation,
    this.user,
    this.onReservationCancelled,
    this.onReservationChanged,
    this.onReservationAdded,
  });

  static void show({
    required BuildContext context,
    required Course course,
    required CourseSession session,
    required DateTime date,
    Reservation? reservation,
    User? user,
    VoidCallback? onReservationCancelled,
    VoidCallback? onReservationChanged,
    VoidCallback? onReservationAdded,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      builder: (context) => ReservationManageBottomSheet(
        course: course,
        session: session,
        date: date,
        reservation: reservation,
        user: user,
        onReservationCancelled: onReservationCancelled,
        onReservationChanged: onReservationChanged,
        onReservationAdded: onReservationAdded,
      ),
    );
  }

  @override
  State<ReservationManageBottomSheet> createState() =>
      _ReservationManageBottomSheetState();
}

class _ReservationManageBottomSheetState
    extends State<ReservationManageBottomSheet> {
  final ReservationService _reservationService = ReservationService();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  List<User> _availableUsers = [];
  User? _selectedUser;
  bool _isLoading = false;
  bool _isAddingMode = false;
  bool _isChangingMode = false; // 예약 변경 모드
  CourseSession? _selectedNewSession; // 새로 선택된 세션
  DateTime? _selectedNewDate; // 새로 선택된 날짜

  @override
  void initState() {
    super.initState();
    _isAddingMode = widget.reservation == null;
    if (_isAddingMode) {
      _loadAvailableUsers();
    } else {
      _nameController.text = widget.user?.name ?? '';
      _phoneController.text = widget.user?.phoneNumber ?? '';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _loadAvailableUsers() async {
    setState(() => _isLoading = true);
    try {
      // TODO: 플레이스 ID를 가져와서 해당 플레이스의 사용자만 로드
      // 현재는 모든 사용자를 로드 (실제로는 플레이스별로 필터링 필요)
      // final users = await _firestoreService.watchUsersByPlace(placeId).first;
      // setState(() {
      //   _availableUsers = users;
      // });
    } catch (e) {
      // 에러 처리
    }
    setState(() => _isLoading = false);
  }

  Future<void> _cancelReservation() async {
    if (widget.reservation == null) return;

    // 바텀시트 먼저 닫기
    Navigator.of(context).pop();

    // 다이얼로그 띄우기
    final confirmed = await CommonDialog.show(
      context: context,
      title: '예약 취소',
      message: '${widget.user?.name ?? "예약자"}님의 예약을 취소하시겠습니까?',
      cancelText: '취소',
      confirmText: '예약 취소',
      confirmButtonColor: Colors.red,
    );

    // 취소 시 바텀시트 다시 열기 (롤백)
    if (confirmed != true) {
      if (mounted) {
        ReservationManageBottomSheet.show(
          context: context,
          course: widget.course,
          session: widget.session,
          date: widget.date,
          reservation: widget.reservation,
          user: widget.user,
          onReservationCancelled: widget.onReservationCancelled,
          onReservationChanged: widget.onReservationChanged,
          onReservationAdded: widget.onReservationAdded,
        );
      }
      return;
    }

    // 확인 시 예약 취소 처리
    // 바텀시트를 닫은 후 context 사용을 위해 rootContext 저장
    final rootContext = context;

    try {
      // 예약 취소 진행 중 로딩 다이얼로그
      showDialog(
        context: rootContext,
        barrierDismissible: false,
        builder: (_) {
          return WillPopScope(
            onWillPop: () async => false,
            child: const Center(
              child: CircularProgressIndicator(color: AppColors.primaryGreen),
            ),
          );
        },
      );

      final success = await _reservationService.deleteReservation(
        reservationId: widget.reservation!.id,
        placeId: widget.reservation!.placeId,
      );

      // 로딩 다이얼로그 닫기
      if (mounted) {
        Navigator.of(rootContext, rootNavigator: true).pop();
      }

      if (success) {
        widget.onReservationCancelled?.call();
        if (mounted) {
          SnackbarUtil.showSuccess(rootContext, '예약이 취소되었습니다.');
        }
      } else {
        if (mounted) {
          SnackbarUtil.showError(rootContext, '예약 취소 중 오류가 발생했습니다.');
          // 에러 발생 시 바텀시트 다시 열기
          ReservationManageBottomSheet.show(
            context: rootContext,
            course: widget.course,
            session: widget.session,
            date: widget.date,
            reservation: widget.reservation,
            user: widget.user,
            onReservationCancelled: widget.onReservationCancelled,
            onReservationChanged: widget.onReservationChanged,
            onReservationAdded: widget.onReservationAdded,
          );
        }
      }
    } catch (e) {
      // 로딩 다이얼로그가 떠있으면 닫기
      if (mounted) {
        Navigator.of(rootContext, rootNavigator: true).pop();
      }

      if (mounted) {
        SnackbarUtil.showError(rootContext, '예약 취소 중 오류가 발생했습니다: $e');
        // 에러 발생 시 바텀시트 다시 열기
        ReservationManageBottomSheet.show(
          context: rootContext,
          course: widget.course,
          session: widget.session,
          date: widget.date,
          reservation: widget.reservation,
          user: widget.user,
          onReservationCancelled: widget.onReservationCancelled,
          onReservationChanged: widget.onReservationChanged,
          onReservationAdded: widget.onReservationAdded,
        );
      }
    }
  }

  void _enterChangeMode() {
    setState(() {
      _isChangingMode = true;
      _selectedNewSession = null;
      _selectedNewDate = null;
    });
  }

  void _onSessionSelected(Course course, CourseSession session, DateTime date) {
    setState(() {
      // 이미 선택된 세션이면 취소
      if (_selectedNewSession != null &&
          _selectedNewDate != null &&
          _selectedNewSession!.dayOfWeek == session.dayOfWeek &&
          _selectedNewSession!.startTime == session.startTime &&
          _selectedNewDate!.year == date.year &&
          _selectedNewDate!.month == date.month &&
          _selectedNewDate!.day == date.day) {
        _selectedNewSession = null;
        _selectedNewDate = null;
      } else {
        _selectedNewSession = session;
        _selectedNewDate = date;
      }
    });
  }

  bool get _hasChanges {
    if (_selectedNewSession == null || _selectedNewDate == null) {
      return false;
    }
    // 원래 세션과 날짜와 다른지 확인
    final originalDayOfWeek = widget.session.dayOfWeek;
    final originalStartTime = widget.session.startTime;
    final originalDate = DateTime(
      widget.date.year,
      widget.date.month,
      widget.date.day,
    );
    final newDate = DateTime(
      _selectedNewDate!.year,
      _selectedNewDate!.month,
      _selectedNewDate!.day,
    );

    return _selectedNewSession!.dayOfWeek != originalDayOfWeek ||
        _selectedNewSession!.startTime != originalStartTime ||
        newDate != originalDate;
  }

  Future<void> _completeChange() async {
    if (!_hasChanges ||
        _selectedNewSession == null ||
        _selectedNewDate == null) {
      return;
    }

    final confirmed = await CommonDialog.show(
      context: context,
      title: '예약 변경',
      message: '예약을 변경하시겠습니까?',
      cancelText: '취소',
      confirmText: '확인',
      confirmButtonColor: AppColors.primaryGreen,
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      // ✅ Provider 기반으로 처리(in-flight 상태 유지 + 캘린더 UI에서 처리 중 표시)
      await Provider.of<ReservationProvider>(
        context,
        listen: false,
      ).moveReservationWithinCourse(
        reservation: widget.reservation!,
        newDayOfWeek: _selectedNewSession!.dayOfWeek,
        newStartTime: _selectedNewSession!.startTime,
        newReservedDate: _selectedNewDate!,
      );
      widget.onReservationChanged?.call();
      if (mounted) {
        Navigator.of(context).pop();
        SnackbarUtil.showSuccess(context, '예약이 변경되었습니다.');
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '예약 변경 중 오류가 발생했습니다: $e');
      }
    }
    setState(() => _isLoading = false);
  }

  Future<void> _addReservation() async {
    if (_selectedUser == null && _nameController.text.trim().isEmpty) {
      SnackbarUtil.showError(context, '예약자 정보를 입력해주세요');
      return;
    }

    setState(() => _isLoading = true);
    try {
      // TODO: 실제 예약 추가 로직 구현
      // 새 예약 생성
      // final newReservation = Reservation(
      //   id: DateTime.now().millisecondsSinceEpoch.toString(),
      //   userId: _selectedUser?.userId ?? '',
      //   courseId: widget.course.id,
      //   placeId: '', // TODO: 플레이스 ID 가져오기
      //   dayOfWeek: widget.session.dayOfWeek,
      //   startTime: widget.session.startTime,
      //   reservedAt: DateTime.now(),
      //   reservedDate: widget.date,
      // );
      // await _firestoreService.addReservation(newReservation);

      widget.onReservationAdded?.call();
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '예약 추가 중 오류가 발생했습니다: $e');
      }
    }
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Stack(
        children: [
          // 배경 탭 시 닫기
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(color: Colors.transparent),
            ),
          ),
          // 바텀시트 컨텐츠
          Align(
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {},
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: BorderRadius.circular(30),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 헤더
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _isAddingMode ? '예약자 추가' : '예약 관리',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                          color: AppColors.textSecondary,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    if (_isAddingMode) ...[
                      // 예약자 선택/입력
                      Text(
                        '예약자 선택',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // 사용자 목록이 있으면 드롭다운, 없으면 직접 입력
                      if (_availableUsers.isNotEmpty) ...[
                        DropdownButtonFormField<User>(
                          value: _selectedUser,
                          decoration: InputDecoration(
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          hint: const Text('예약자 선택'),
                          items: _availableUsers.map((user) {
                            return DropdownMenuItem<User>(
                              value: user,
                              child: Text(
                                '${user.name} (${FormatUtils.formatPhoneNumber(user.phoneNumber)})',
                              ),
                            );
                          }).toList(),
                          onChanged: (user) {
                            setState(() {
                              _selectedUser = user;
                              if (user != null) {
                                _nameController.text = user.name;
                                _phoneController.text = user.phoneNumber;
                              }
                            });
                          },
                        ),
                        const SizedBox(height: 16),
                        const Divider(),
                        const SizedBox(height: 16),
                        Text(
                          '또는 직접 입력',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      AdminTextField(label: '이름', controller: _nameController),
                      const SizedBox(height: 12),
                      AdminTextField(
                        label: '전화번호',
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                      ),
                    ] else ...[
                      // 예약 정보 표시 (모두 칩셋으로)
                      _buildInfoChip(
                        '예약자',
                        widget.user?.name ?? '알 수 없음',
                        AppColors.primaryGreen,
                      ),

                      const SizedBox(height: 6),
                      _buildInfoChip(
                        '예약 시간',
                        _formatDateTime(
                          widget.reservation?.reservedAt ?? DateTime.now(),
                        ),
                        AppColors.primaryGreen,
                      ),
                      const SizedBox(height: 20),

                      // 예약 변경 모드일 때 캘린더 표시
                      if (_isChangingMode) ...[
                        const SizedBox(height: 16),
                        Text(
                          '변경할 시간대를 선택하세요',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primaryGreen,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          height: 300,
                          decoration: BoxDecoration(
                            color: AppColors.backgroundLight,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: CompactCalendarWidget(
                              courses: [widget.course],
                              usage: CompactCalendarUsage.adminSelectNewSlot,
                              weekOffset: 0,
                              height: 300,
                              onSessionTap: _onSessionSelected,
                              hideCourseSelector: true,
                              adminSelectionMode: true,
                              currentReservationDayOfWeek:
                                  widget.session.dayOfWeek,
                              currentReservationStartTime:
                                  widget.session.startTime,
                              currentReservationDate: widget.date,
                            ),
                          ),
                        ),

                        const SizedBox(height: 20),
                      ],
                    ],

                    const SizedBox(height: 24),

                    // 액션 버튼
                    if (_isAddingMode)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _addReservation,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryGreen,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            elevation: 0,
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      AppColors.primaryGreen,
                                    ),
                                  ),
                                )
                              : const Text(
                                  '예약 추가',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      )
                    else if (_isChangingMode)
                      // 변경 모드일 때 변경 완료 버튼
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: (_isLoading || !_hasChanges)
                              ? null
                              : _completeChange,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryGreen,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: AppColors.backgroundLight,
                            disabledForegroundColor: AppColors.textSecondary,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            elevation: 0,
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      AppColors.primaryGreen,
                                    ),
                                  ),
                                )
                              : Text(
                                  _getChangeButtonText(),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      )
                    else
                      // 기본 모드: 취소/변경
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _isLoading ? null : _cancelReservation,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red,
                                side: const BorderSide(color: Colors.red),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                              child: const Text(
                                '예약 취소',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _enterChangeMode,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryGreen,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                elevation: 0,
                              ),
                              child: const Text(
                                '예약 변경시키기',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }

  String _getChangeButtonText() {
    // 선택된 세션이 없거나 원래 예약과 같을 때
    if (_selectedNewSession == null ||
        _selectedNewDate == null ||
        !_hasChanges) {
      final userName = widget.user?.name ?? '예약자';
      return '현재 $userName님의 예약';
    }

    // 다른 세션으로 변경하는 경우
    final weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final weekday = weekdays[_selectedNewDate!.weekday - 1];
    final startTime = _selectedNewSession!.startTime.split(
      ':',
    )[0]; // "13:00" -> "13"
    final endTime = _selectedNewSession!.endTime.split(
      ':',
    )[0]; // "14:00" -> "14"

    return '$startTime-$endTime($weekday)으로 변경시키기';
  }
}
