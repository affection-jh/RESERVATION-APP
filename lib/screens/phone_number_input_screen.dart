import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_colors.dart';
import '../services/auth_service.dart';
import '../constants/app_constants.dart';
import '../utils/text_field_decoration_util.dart';

/// 전화번호 입력 화면
class PhoneNumberInputScreen extends StatefulWidget {
  const PhoneNumberInputScreen({super.key});

  @override
  State<PhoneNumberInputScreen> createState() => _PhoneNumberInputScreenState();
}

class _PhoneNumberInputScreenState extends State<PhoneNumberInputScreen> {
  final TextEditingController _phoneController = TextEditingController();
  final AuthService _authService = AuthService();
  bool _isButtonEnabled = false;
  bool _isLoading = false;
  bool _isDisposed = false; // 화면이 dispose되었는지 추적
  String? _errorMessage; // 에러 메시지

  @override
  void initState() {
    super.initState();
    _phoneController.addListener(_onPhoneChanged);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _phoneController.removeListener(_onPhoneChanged);
    _phoneController.dispose();
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

  String _formatPhoneNumber(String value) {
    final digits = value.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length <= 3) {
      return digits;
    } else if (digits.length <= 7) {
      return '${digits.substring(0, 3)}-${digits.substring(3)}';
    } else if (digits.length <= 11) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7)}';
    } else {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7, 11)}';
    }
  }

  Future<void> _onGetVerificationCode() async {
    if (_isLoading) return;

    final phone = _phoneController.text.replaceAll(RegExp(r'[^\d]'), '');
    if (phone.length < 10) return;

    setState(() {
      _isLoading = true;
      _isButtonEnabled = false;
      _errorMessage = null; // 에러 메시지 초기화
    });

    // 일반 인증 플로우 (Firebase Console의 테스트용 전화번호 기능 사용)
    try {
      // Firebase Auth를 통해 인증 코드 발송
      await _authService.sendVerificationCode(phone);

      // 화면이 dispose되었거나 뒤로가기로 취소된 경우 처리하지 않음
      if (_isDisposed || !mounted) {
        // 인증 정보 초기화
        await _authService.clearVerificationData();
        return;
      }

      Navigator.of(context).pushNamed('/verification-code', arguments: phone);
    } catch (e) {
      // 화면이 dispose되었거나 뒤로가기로 취소된 경우 에러 표시하지 않음
      if (_isDisposed || !mounted) {
        return;
      }

      // 에러 메시지 정리 (Firebase/플랫폼 응답 기반, 기술 문구 노출 최소화)
      String errorMessage =
          e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '').trim();
      if (errorMessage.contains('캡챠') ||
          errorMessage.contains('reCAPTCHA') ||
          errorMessage.contains('팝업')) {
        // AuthService에서 이미 사용자 친화 메시지로 변환된 케이스
      } else if (errorMessage.contains('channel-error') ||
          errorMessage.contains('PlatformException')) {
        errorMessage = '인증 서비스 초기화 중입니다.\n앱을 완전히 재시작하거나 잠시 후 다시 시도해주세요.';
      } else if (errorMessage.contains('too-many-requests') ||
          errorMessage.contains('너무 많은 요청')) {
        errorMessage = '인증번호 발송 횟수 제한을 초과했습니다.\n잠시 후 다시 시도해주세요.';
      } else if (errorMessage.isEmpty) {
        errorMessage = '인증번호 발송에 실패했습니다.';
      }
      setState(() {
        _errorMessage = errorMessage;
      });
    } finally {
      if (mounted && !_isDisposed) {
        setState(() {
          _isLoading = false;
          _isButtonEnabled = phone.length >= 10;
        });
      }
    }
  }

  Future<void> _onBackPressed() async {
    // 인증 코드 요청 중인 경우 취소 처리
    if (_isLoading) {
      _isDisposed = true;
      // 인증 정보 초기화
      await _authService.clearVerificationData();
      setState(() {
        _isLoading = false;
        _isButtonEnabled =
            _phoneController.text.replaceAll(RegExp(r'[^\d]'), '').length >= 10;
      });
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: AppColors.backgroundWhite,
        elevation: 0,
        leading:
            Navigator.of(context).canPop()
                ? IconButton(
                  onPressed: _onBackPressed,
                  icon: const Icon(
                    Icons.arrow_back_ios,
                    color: AppColors.textPrimary,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                )
                : null,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 메인 콘텐츠
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 20),
                    // 제목
                    Text(
                      '휴대폰 번호를 입력해주세요.',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // 안내 문구
                    Text.rich(
                      TextSpan(
                        text: '인증을 요청하면 14세 이상이며,\n',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.textSecondary,
                          height: 1.5,
                        ),
                        children: [
                          TextSpan(
                            text: '개인정보처리방침',
                            style: TextStyle(
                              color: AppColors.primaryGreen,
                              decoration: TextDecoration.underline,
                              fontWeight: FontWeight.w600,
                            ),
                            recognizer:
                                TapGestureRecognizer()
                                  ..onTap = () {
                                    Navigator.of(context).pushNamed(
                                      '/webview',
                                      arguments: {
                                        'url': AppConstants.termsAndPrivacyUrl,
                                        'title': '개인정보처리방침 및 이용약관',
                                      },
                                    );
                                  },
                          ),
                          const TextSpan(
                            text: ' 및 ',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                          TextSpan(
                            text: '이용약관',
                            style: TextStyle(
                              color: AppColors.primaryGreen,
                              decoration: TextDecoration.underline,
                              fontWeight: FontWeight.w600,
                            ),
                            recognizer:
                                TapGestureRecognizer()
                                  ..onTap = () {
                                    Navigator.of(context).pushNamed(
                                      '/webview',
                                      arguments: {
                                        'url': AppConstants.termsAndPrivacyUrl,
                                        'title': '개인정보처리방침 및 이용약관',
                                      },
                                    );
                                  },
                          ),
                          const TextSpan(
                            text: '에 동의합니다.',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 30),

                    // 전화번호 입력 필드
                    Stack(
                      children: [
                        // 입력 필드
                        TextField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(11),
                          ],
                          style: TextStyle(
                            fontSize: 18,
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w500,
                          ),

                          decoration: TextFieldDecorationUtil.defaultDecoration(
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

                            hintText: '휴대폰 번호를 입력해주세요',
                            errorText: _errorMessage,
                            hasError: _errorMessage != null,
                            floatingLabelBehavior: FloatingLabelBehavior.always,
                          ),
                          onChanged: (value) {
                            final formatted = _formatPhoneNumber(value);
                            if (formatted != value) {
                              _phoneController.value = TextEditingValue(
                                text: formatted,
                                selection: TextSelection.collapsed(
                                  offset: formatted.length,
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ), // 인증번호 받기 버튼
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      (_isButtonEnabled && !_isLoading)
                          ? _onGetVerificationCode
                          : null,
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
                  child:
                      _isLoading
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
                            '인증번호 받기',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
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
}
