import 'package:flutter/material.dart';
import 'package:reservation/utils/text_field_decoration_util.dart';
import '../models/course.dart';
import '../models/course_enrollment.dart';
import '../services/enrollment_service.dart';
import '../theme/app_colors.dart';
import '../utils/snackbar_util.dart';
import '../utils/timezone_utils.dart';

/// 연장 요청 바텀시트 (일반 유저용)
class ExtensionRequestBottomSheet extends StatefulWidget {
  final String enrollmentId;
  final CourseEnrollment enrollment;
  final Course course;
  final VoidCallback? onRequestSubmitted;

  const ExtensionRequestBottomSheet({
    super.key,
    required this.enrollmentId,
    required this.enrollment,
    required this.course,
    this.onRequestSubmitted,
  });

  static Future<void> show({
    required BuildContext context,
    required String enrollmentId,
    required CourseEnrollment enrollment,
    required Course course,
    VoidCallback? onRequestSubmitted,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.5),
      isDismissible: true,
      enableDrag: true,
      builder: (context) => ExtensionRequestBottomSheet(
        enrollmentId: enrollmentId,
        enrollment: enrollment,
        course: course,
        onRequestSubmitted: onRequestSubmitted,
      ),
    );
  }

  @override
  State<ExtensionRequestBottomSheet> createState() =>
      _ExtensionRequestBottomSheetState();
}

class _ExtensionRequestBottomSheetState
    extends State<ExtensionRequestBottomSheet> {
  final TextEditingController _reasonController = TextEditingController();
  final EnrollmentService _enrollmentService = EnrollmentService();
  bool _isRequesting = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submitExtensionRequest() async {
    if (_reasonController.text.trim().isEmpty) {
      SnackbarUtil.showError(context, '사유를 입력해주세요');
      return;
    }

    if (widget.enrollmentId.isEmpty) {
      SnackbarUtil.showError(context, '등록 정보를 찾을 수 없습니다.');
      return;
    }

    setState(() {
      _isRequesting = true;
    });

    try {
      final request = ExtensionRequest(
        id: 'req_${DateTime.now().microsecondsSinceEpoch}',
        requestedAt: TimezoneUtils.getSeoulDateTime(),
        reason: _reasonController.text.trim(),
        status: ExtensionRequestStatus.pending,
      );

      await _enrollmentService.addExtensionRequestWithEnrollmentMarker(
        enrollmentId: widget.enrollmentId,
        request: request,
      );

      if (!mounted) return;
      _reasonController.clear();
      widget.onRequestSubmitted?.call();
      Navigator.of(context).pop();
      SnackbarUtil.showSuccess(context, '연장 요청이 접수되었습니다.');
    } catch (e) {
      if (!mounted) return;
      SnackbarUtil.showError(context, '연장 요청 중 오류가 발생했습니다: $e');
    } finally {
      if (!mounted) return;
      setState(() {
        _isRequesting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canRequest =
        widget.enrollment.remainingReservations > 0 &&
        !widget.enrollment.isExpired;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.transparent,
      body: Container(
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
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final mediaQuery = MediaQuery.of(context);
                    final screenHeight = mediaQuery.size.height;
                    final keyboardHeight = mediaQuery.viewInsets.bottom;
                    final statusBarHeight = mediaQuery.padding.top;
                    final safeAreaBottom = mediaQuery.padding.bottom;

                    // 동적 높이 계산: 화면 높이 - 상태바 - 키보드 - 하단 SafeArea - 여유 공간
                    final maxHeight =
                        screenHeight -
                        statusBarHeight -
                        keyboardHeight -
                        safeAreaBottom -
                        16; // 상단 여유 공간

                    return Container(
                      constraints: BoxConstraints(
                        maxHeight: maxHeight.clamp(200.0, screenHeight * 0.9),
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundWhite,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(24),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 헤더
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                            child: Row(
                              children: [
                                Text(
                                  '연장 요청',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                Spacer(),
                                IconButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  icon: Icon(
                                    Icons.close,
                                    color: AppColors.textSecondary,
                                    size: 24,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Flexible(
                            child: SingleChildScrollView(
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              child: Padding(
                                padding: EdgeInsets.only(
                                  left: 24,
                                  right: 24,
                                  bottom:
                                      MediaQuery.of(context).viewInsets.bottom +
                                      24,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (!canRequest) ...[
                                      Container(
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: AppColors.backgroundLight,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.info_outline,
                                              color: AppColors.textSecondary,
                                              size: 20,
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                widget.enrollment.isExpired
                                                    ? '만료된 등록은 연장 요청을 할 수 없습니다.'
                                                    : '남은 횟수가 없어 연장 요청을 할 수 없습니다.',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color:
                                                      AppColors.textSecondary,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                    ],
                                    if (canRequest) ...[
                                      TextField(
                                        controller: _reasonController,
                                        maxLines: 6,
                                        decoration:
                                            TextFieldDecorationUtil.defaultDecoration(
                                              hintText: '연장이 필요한 사유를 입력해주세요',
                                              contentPadding:
                                                  const EdgeInsets.all(16),
                                            ),
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton(
                                          onPressed: _isRequesting
                                              ? null
                                              : _submitExtensionRequest,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor:
                                                AppColors.primaryGreen,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 18,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                            ),
                                            elevation: 0,
                                          ),
                                          child: _isRequesting
                                              ? const SizedBox(
                                                  height: 20,
                                                  width: 20,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    valueColor:
                                                        AlwaysStoppedAnimation<
                                                          Color
                                                        >(Colors.white),
                                                  ),
                                                )
                                              : const Text(
                                                  '요청하기',
                                                  style: TextStyle(
                                                    fontSize: 17,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
