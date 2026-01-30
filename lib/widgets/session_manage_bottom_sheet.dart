import 'package:flutter/material.dart';
import 'package:reservation/utils/snackbar_util.dart';
import 'package:reservation/utils/text_field_decoration_util.dart';
import '../models/course.dart';
import '../theme/app_colors.dart';

/// 세션 관리 바텀시트 (수용인원 변경, 세션 취소)
///
/// 재사용 가능한 공통 위젯으로, 여러 화면에서 사용됩니다.
class SessionManageBottomSheet extends StatefulWidget {
  final Course course;
  final String dateString; // "2026-02-04" 형식
  final String startTime;
  final String endTime;
  final int currentCapacity;
  final int reservedCount;
  final Future<void> Function(int newCapacity)?
  onCapacityChanged; // 수용인원 변경 후 콜백 (새 수용인원을 받아서 처리)
  final VoidCallback onCancelSession; // 세션 취소 버튼 클릭 시 콜백

  const SessionManageBottomSheet({
    super.key,
    required this.course,
    required this.dateString,
    required this.startTime,
    required this.endTime,
    required this.currentCapacity,
    required this.reservedCount,
    this.onCapacityChanged,
    required this.onCancelSession,
  });

  @override
  State<SessionManageBottomSheet> createState() =>
      _SessionManageBottomSheetState();
}

class _SessionManageBottomSheetState extends State<SessionManageBottomSheet> {
  late TextEditingController _capacityController;
  String? _errorText;
  bool _isApplyButtonEnabled = false;

  @override
  void initState() {
    super.initState();
    _capacityController = TextEditingController(
      text: widget.currentCapacity.toString(),
    );
  }

  @override
  void dispose() {
    _capacityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 핸들 바
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderLight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 세션 정보 헤더
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.course.name,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.start,
                    crossAxisAlignment: WrapCrossAlignment.start,
                    children: [
                      // 날짜/시간 칩
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.backgroundLight,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.access_time,
                              size: 14,
                              color: AppColors.textSecondary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${widget.dateString} ${widget.startTime} - ${widget.endTime}',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 예약/수용 칩
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.backgroundLight,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '예약: ${widget.reservedCount}명 / ${widget.currentCapacity}명',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // 수용인원 변경 섹션
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '수용인원 변경',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),

                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _capacityController,
                          keyboardType: TextInputType.number,
                          decoration: TextFieldDecorationUtil.defaultDecoration(
                            hintText: '수용인원을 입력하세요',
                            hasFocus: false,
                            borderRadius: 12,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ).copyWith(
                            errorText: _errorText,
                            errorStyle: TextStyle(
                              fontSize: 12,
                              color: Colors.red,
                            ),
                          ),
                          onChanged: (value) {
                            // 입력값 실시간 검증
                            setState(() {
                              if (value.isEmpty) {
                                _errorText = null;
                                _isApplyButtonEnabled = false;
                              } else {
                                final inputCapacity = int.tryParse(value);
                                if (inputCapacity == null ||
                                    inputCapacity <= 0) {
                                  _errorText = '올바른 수용인원을 입력하세요.';
                                  _isApplyButtonEnabled = false;
                                } else if (inputCapacity <
                                    widget.reservedCount) {
                                  _errorText =
                                      '현재 예약자 수(${widget.reservedCount}명)보다 작을 수 없습니다.';
                                  _isApplyButtonEnabled = false;
                                } else {
                                  _errorText = null;
                                  // 원래 값과 다를 때만 활성화
                                  _isApplyButtonEnabled =
                                      inputCapacity != widget.currentCapacity;
                                }
                              }
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed:
                            _isApplyButtonEnabled
                                ? () => _handleApplyCapacity(context)
                                : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryGreen,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: AppColors.borderLight,
                          disabledForegroundColor: AppColors.textSecondary,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 14,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          '적용',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: AppColors.borderLight),
            // 세션 취소 버튼
            InkWell(
              onTap: () {
                Navigator.of(context).pop({'action': 'cancel'});
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
                child: Center(
                  child: Text(
                    '세션 취소하기',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: Colors.red,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
          ],
        ),
      ),
    );
  }

  Future<void> _handleApplyCapacity(BuildContext context) async {
    final inputCapacity = int.tryParse(_capacityController.text);

    // 유효성 검증
    if (inputCapacity == null || inputCapacity <= 0) {
      setState(() {
        _errorText = '올바른 수용인원을 입력하세요.';
      });
      return;
    }

    if (inputCapacity < widget.reservedCount) {
      setState(() {
        _errorText = '현재 예약자 수(${widget.reservedCount}명)보다 작을 수 없습니다.';
      });
      return;
    }

    // 에러가 없으면 초기화
    setState(() {
      _errorText = null;
    });

    // 수용인원 변경은 부모 위젯에서 처리하도록 콜백 호출
    if (widget.onCapacityChanged != null) {
      try {
        await widget.onCapacityChanged!(inputCapacity);
        if (context.mounted) {
          Navigator.of(
            context,
          ).pop({'action': 'changeCapacity', 'capacity': inputCapacity});
        }
      } catch (e) {
        if (context.mounted) {
          SnackbarUtil.showError(context, '수용인원 변경 중 오류가 발생했습니다.');
        }
      }
    } else {
      // 콜백이 없으면 그냥 닫기
      if (context.mounted) {
        Navigator.of(
          context,
        ).pop({'action': 'changeCapacity', 'capacity': inputCapacity});
      }
    }
  }
}

/// 세션 관리 바텀시트를 표시하는 헬퍼 함수
///
/// 사용 예시:
/// ```dart
/// final result = await showSessionManageBottomSheet(
///   context: context,
///   course: course,
///   dateString: '2026-02-04',
///   startTime: '09:30',
///   endTime: '12:00',
///   currentCapacity: 4,
///   reservedCount: 0,
///   onCapacityChanged: (newCapacity) async {
///     // 수용인원 변경 로직
///   },
///   onCancelSession: () async {
///     // 세션 취소 로직
///   },
/// );
/// ```
Future<Map<String, dynamic>?> showSessionManageBottomSheet({
  required BuildContext context,
  required Course course,
  required String dateString,
  required String startTime,
  required String endTime,
  required int currentCapacity,
  required int reservedCount,
  Future<void> Function(int newCapacity)? onCapacityChanged,
  required VoidCallback onCancelSession,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.6),
    isDismissible: true,
    enableDrag: true,
    builder:
        (context) => SessionManageBottomSheet(
          course: course,
          dateString: dateString,
          startTime: startTime,
          endTime: endTime,
          currentCapacity: currentCapacity,
          reservedCount: reservedCount,
          onCapacityChanged: onCapacityChanged,
          onCancelSession: onCancelSession,
        ),
  );
}
