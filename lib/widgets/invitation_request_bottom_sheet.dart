import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:reservation/utils/text_field_decoration_util.dart';
import '../theme/app_colors.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';

/// 초대요청 바텀시트
class InvitationRequestBottomSheet extends StatefulWidget {
  final String userId;

  const InvitationRequestBottomSheet({super.key, required this.userId});

  static Future<void> show({
    required BuildContext context,
    required String userId,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => InvitationRequestBottomSheet(userId: userId),
    );
  }

  @override
  State<InvitationRequestBottomSheet> createState() =>
      _InvitationRequestBottomSheetState();
}

class _InvitationRequestBottomSheetState
    extends State<InvitationRequestBottomSheet> {
  final TextEditingController _phoneController = TextEditingController();
  final FocusNode _phoneFocusNode = FocusNode();
  bool _isSubmitting = false;
  bool _isButtonEnabled = false; // 버튼 활성화 상태
  String? _errorMessage; // 에러 메시지

  @override
  void initState() {
    super.initState();
    _phoneController.addListener(_onPhoneChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _phoneFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _phoneController.removeListener(_onPhoneChanged);
    _phoneController.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  void _onPhoneChanged() {
    final phone = _phoneController.text.replaceAll(RegExp(r'[^\d]'), '');
    setState(() {
      _isButtonEnabled = phone.length >= 10;
      // 전화번호 입력 시 에러 메시지 초기화
      if (_errorMessage != null) {
        _errorMessage = null;
      }
    });
  }

  String _formatPhoneNumber(String phone) {
    // 숫자만 추출
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length <= 3) return digits;
    if (digits.length <= 7) {
      return '${digits.substring(0, 3)}-${digits.substring(3)}';
    }
    return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7, digits.length > 11 ? 11 : digits.length)}';
  }

  Future<void> _onSubmit() async {
    final phoneNumber = _phoneController.text.replaceAll(RegExp(r'[^\d]'), '');

    if (phoneNumber.length < 10) {
      setState(() {
        _errorMessage = '올바른 전화번호를 입력해주세요.';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null; // 에러 메시지 초기화
    });

    try {
      // 관리자 전화번호로 플레이스 찾기
      final firestoreService = FirestoreService();
      final authService = AuthService();

      // 관리자 조회
      final adminSnapshot = await firestoreService.firestore
          .collection('adminUsers')
          .where('phoneNumber', isEqualTo: phoneNumber)
          .limit(1)
          .get();

      if (adminSnapshot.docs.isEmpty) {
        setState(() {
          _errorMessage = '해당 전화번호의 관리자를 찾을 수 없습니다.';
          _isSubmitting = false;
        });
        return;
      }

      final adminId = adminSnapshot.docs.first.reference.id;

      // 관리자의 플레이스 찾기
      final placeSnapshot = await firestoreService.firestore
          .collection('places')
          .where('adminId', isEqualTo: adminId)
          .limit(1)
          .get();

      if (placeSnapshot.docs.isEmpty) {
        setState(() {
          _errorMessage = '해당 관리자의 플레이스를 찾을 수 없습니다.';
          _isSubmitting = false;
        });
        return;
      }

      final placeId = placeSnapshot.docs.first.reference.id;

      // 초대요청 보내기
      await authService.requestPlaceMembership(
        userId: widget.userId,
        placeId: placeId,
      );

      if (mounted) {
        // 성공 시 바텀시트 닫기
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        // 에러 메시지 정리
        String errorMessage = e.toString();
        if (errorMessage.contains('Exception: ')) {
          errorMessage = errorMessage.replaceAll('Exception: ', '');
        } else {
          errorMessage = '초대요청 전송에 실패했습니다.';
        }
        setState(() {
          _errorMessage = errorMessage;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 헤더
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '초대요청 보내기',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close, color: AppColors.textSecondary),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            // 설명
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                '관리자의 번호로 초대요청을 보낼 수 있습니다.',
                style: TextStyle(
                  fontSize: 16,
                  color: AppColors.textSecondary,
                  height: 1.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 30),
            // 전화번호 입력 필드
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TextField(
                controller: _phoneController,
                focusNode: _phoneFocusNode,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(11),
                  TextInputFormatter.withFunction((oldValue, newValue) {
                    final formatted = _formatPhoneNumber(newValue.text);
                    return TextEditingValue(
                      text: formatted,
                      selection: TextSelection.collapsed(
                        offset: formatted.length,
                      ),
                    );
                  }),
                ],
                style: TextStyle(
                  fontSize: 18,
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
                decoration: TextFieldDecorationUtil.defaultDecoration(
                  hintText: '010-1234-5678',
                  errorText: _errorMessage,
                  hasError: _errorMessage != null,
                  floatingLabelBehavior: FloatingLabelBehavior.always,

                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(
                      top: 10,
                      left: 12,
                      right: 6,
                      bottom: 6,
                    ),
                    child: SvgPicture.asset(
                      'assets/icons/phone-icon.svg',
                      width: 20,
                      height: 20,
                      colorFilter: ColorFilter.mode(
                        AppColors.textSecondary,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
            // 제출 버튼
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_isButtonEnabled && !_isSubmitting)
                      ? _onSubmit
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.borderLight,
                    disabledForegroundColor: AppColors.textLight,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.primaryGreen,
                            ),
                          ),
                        )
                      : const Text(
                          '초대요청 보내기',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
