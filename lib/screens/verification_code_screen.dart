import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../utils/snackbar_util.dart';
import '../utils/text_field_decoration_util.dart';
import '../services/auth_service.dart';
import '../providers/auth_provider.dart';

/// 인증번호 입력 화면
class VerificationCodeScreen extends StatefulWidget {
  final String phoneNumber;
  final bool isPlaceRegistrationFlow; // 플레이스 추가 플로우인지 여부

  const VerificationCodeScreen({
    super.key,
    required this.phoneNumber,
    this.isPlaceRegistrationFlow = false,
  });

  @override
  State<VerificationCodeScreen> createState() => _VerificationCodeScreenState();
}

class _VerificationCodeScreenState extends State<VerificationCodeScreen> {
  final TextEditingController _codeController = TextEditingController();
  final FocusNode _codeFocusNode = FocusNode();
  final AuthService _authService = AuthService();
  Timer? _timer;
  int _remainingSeconds = 300; // 5분 (Firebase Phone Auth 표준 만료 시간)
  bool _isButtonEnabled = false;
  bool _isResending = false;
  bool _isVerifying = false;
  String? _errorMessage; // 에러 메시지

  @override
  void initState() {
    super.initState();
    _codeController.addListener(_onCodeChanged);
    _startTimer();
    // 화면 진입 시 자동으로 키보드 포커스
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _codeFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.removeListener(_onCodeChanged);
    _codeController.dispose();
    _codeFocusNode.dispose();
    super.dispose();
  }

  void _onCodeChanged() {
    setState(() {
      _isButtonEnabled = _codeController.text.length == 6;
      // 인증번호 입력 시 에러 메시지 초기화
      if (_errorMessage != null) {
        _errorMessage = null;
      }
    });
  }

  void _startTimer() {
    _timer?.cancel();
    _remainingSeconds = 300; // 5분 (Firebase Phone Auth 표준 만료 시간)
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingSeconds > 0) {
        setState(() {
          _remainingSeconds--;
          // 타이머가 0이 되면 인증 버튼 비활성화
          if (_remainingSeconds == 0) {
            _isButtonEnabled = false;
          }
        });
      } else {
        timer.cancel();
      }
    });
  }

  String _formatTime(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(1, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String _formatPhoneNumber(String phone) {
    if (phone.length == 11) {
      return '${phone.substring(0, 3)}-${phone.substring(3, 7)}-${phone.substring(7)}';
    }
    return phone;
  }

  Future<void> _onVerify() async {
    if (_isVerifying) return;

    // 타이머가 만료된 경우 인증 불가
    if (_remainingSeconds <= 0) {
      setState(() {
        _errorMessage = '인증 시간이 만료되었습니다. 인증번호를 다시 요청해주세요.';
      });
      return;
    }

    final code = _codeController.text;
    if (code.length != 6) return;

    debugPrint('[VerificationCodeScreen._onVerify] 인증 시작');
    debugPrint('[VerificationCodeScreen._onVerify] 입력된 코드: "$code"');
    debugPrint(
      '[VerificationCodeScreen._onVerify] 전화번호: "${widget.phoneNumber}"',
    );

    setState(() {
      _isVerifying = true;
      _isButtonEnabled = false;
      _errorMessage = null; // 에러 메시지 초기화
    });

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);

      // Firebase Auth를 통해 인증 코드 확인 및 로그인
      try {
        debugPrint(
          '[VerificationCodeScreen._onVerify] verifyCodeAndSignIn 호출 시작',
        );
        final result = await _authService.verifyCodeAndSignIn(
          smsCode: code,
          phoneNumber: widget.phoneNumber,
        );
        debugPrint(
          '[VerificationCodeScreen._onVerify] ✅ verifyCodeAndSignIn 성공',
        );

        // ✅ 명시적 재로그인(전화번호 인증) 직후에는 자동 분기 금지:
        // - 관리자 등록 여부가 있어도 PIN 입력으로 자동 이동하지 않음
        // - 승인된 플레이스가 있어도 /main으로 자동 이동하지 않음
        // - Waiting에서 멈춘 뒤 사용자가 플레이스/역할을 명시적으로 선택
        await _authService.setRequireManualEntrySelection(true);

        // 사용자 정보 설정 (관리자도 멤버로 로그인할 수 있으므로 일단 user 세팅)
        authProvider.setCurrentUser(result.user);
        // ✅ 인증 직후에는 무조건 일반(멤버) 모드로 진입 (이전 세션의 관리자 선택이 남지 않도록)
        authProvider.clearCurrentAdmin();

        if (mounted) {
          // 플레이스 추가 플로우인 경우 관리자 등록 여부 확인
          if (widget.isPlaceRegistrationFlow) {
            final authService = AuthService();
            final existingAdmin = await authService.findAdminByPhone(
              widget.phoneNumber,
            );

            if (existingAdmin != null) {
              // 이미 관리자로 등록되어 있으면 핀 입력 화면으로
              Navigator.of(context).pushNamedAndRemoveUntil(
                '/admin-pin-input',
                (route) => false,
                arguments: {
                  'phoneNumber': widget.phoneNumber,
                  'verificationCode': code,
                },
              );
            } else {
              // 관리자로 등록되지 않았으면 핀 등록 화면으로
              Navigator.of(context).pushNamedAndRemoveUntil(
                '/admin-pin-register',
                (route) => false,
                arguments: {
                  'phoneNumber': widget.phoneNumber,
                  'verificationCode': code,
                },
              );
            }
            return;
          }

          // ✅ 모든 이전 화면을 제거하고 PlaceWaitingScreen으로 이동
          Navigator.of(context).pushNamedAndRemoveUntil(
            '/place-waiting',
            (route) => false,
            arguments: widget.phoneNumber,
          );
        }
      } catch (e, stackTrace) {
        debugPrint(
          '[VerificationCodeScreen._onVerify] ❌ verifyCodeAndSignIn 내부 catch',
        );
        debugPrint(
          '[VerificationCodeScreen._onVerify] 에러 타입: ${e.runtimeType}',
        );
        debugPrint('[VerificationCodeScreen._onVerify] 에러 내용: $e');
        debugPrint('[VerificationCodeScreen._onVerify] 스택 트레이스: $stackTrace');

        // 이름이 필요하다는 에러인 경우 (신규 사용자)
        if (e.toString().contains('이름이 필요') ||
            e.toString().contains('회원가입을 위해')) {
          debugPrint('[VerificationCodeScreen._onVerify] 이름 입력 화면으로 이동');
          if (mounted) {
            // 이름 입력 화면으로 이동
            Navigator.of(context).pushNamed(
              '/name-input',
              arguments: {'phoneNumber': widget.phoneNumber, 'smsCode': code},
            );
          }
        } else {
          rethrow;
        }
      }
    } catch (e, stackTrace) {
      debugPrint('[VerificationCodeScreen._onVerify] ❌ 최종 catch');
      debugPrint('[VerificationCodeScreen._onVerify] 에러 타입: ${e.runtimeType}');
      debugPrint('[VerificationCodeScreen._onVerify] 에러 내용: $e');
      debugPrint('[VerificationCodeScreen._onVerify] 스택 트레이스: $stackTrace');

      if (mounted) {
        // 에러 메시지 정리
        String errorMessage = e.toString();
        debugPrint(
          '[VerificationCodeScreen._onVerify] 원본 에러 메시지: $errorMessage',
        );

        if (errorMessage.contains('session-expired') ||
            errorMessage.contains('만료되었거나') ||
            errorMessage.contains('invalid-verification-code')) {
          errorMessage = '인증번호가 올바르지 않거나 만료되었습니다.';
        } else if (errorMessage.contains('Exception: ')) {
          errorMessage = errorMessage.replaceAll('Exception: ', '');
        } else {
          errorMessage = '인증에 실패했습니다.';
        }

        debugPrint(
          '[VerificationCodeScreen._onVerify] 최종 에러 메시지: $errorMessage',
        );
        setState(() {
          _errorMessage = errorMessage;
          _isButtonEnabled = code.length == 6;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isVerifying = false;
        });
      }
    }
  }

  Future<void> _onResendCode() async {
    if (_isResending) return;

    debugPrint('[VerificationCodeScreen._onResendCode] 재발송 시작');
    debugPrint(
      '[VerificationCodeScreen._onResendCode] 전화번호: "${widget.phoneNumber}"',
    );

    setState(() {
      _isResending = true;
    });

    try {
      // Firebase Auth를 통해 인증 코드 재발송
      debugPrint(
        '[VerificationCodeScreen._onResendCode] sendVerificationCode 호출',
      );
      await _authService.sendVerificationCode(widget.phoneNumber);
      debugPrint('[VerificationCodeScreen._onResendCode] ✅ 재발송 성공');

      if (mounted) {
        setState(() {
          _isResending = false;
        });
        _startTimer();
        _codeController.clear();
        SnackbarUtil.showSuccess(context, '인증번호가 재발송되었습니다.');
      }
    } catch (e, stackTrace) {
      debugPrint('[VerificationCodeScreen._onResendCode] ❌ 재발송 실패');
      debugPrint(
        '[VerificationCodeScreen._onResendCode] 에러 타입: ${e.runtimeType}',
      );
      debugPrint('[VerificationCodeScreen._onResendCode] 에러 내용: $e');
      debugPrint('[VerificationCodeScreen._onResendCode] 스택 트레이스: $stackTrace');

      if (mounted) {
        // 에러 메시지를 사용자 친화적인 에러 텍스트로 통일
        final raw =
            e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '').trim();
        String message;
        if (raw.contains('캡챠') ||
            raw.contains('reCAPTCHA') ||
            raw.contains('팝업') ||
            raw.contains('인증이 취소') ||
            raw.contains('취소되었습니다')) {
          // AuthService에서 이미 사용자 친화 메시지로 변환된 케이스
          message = raw;
        } else if (raw.contains('too-many-requests') ||
            raw.contains('너무 많은 요청')) {
          message =
              '인증번호 발송 횟수 제한을 초과했습니다. 잠시 후 다시 시도해주세요.';
        } else if (raw.contains('internal-error') ||
            raw.contains('internal error') ||
            raw.contains('An internal error has occurred')) {
          message = '일시적인 오류가 발생했습니다. 잠시 후 다시 시도해주세요.';
        } else if (raw.isEmpty) {
          message = '인증번호 재발송에 실패했습니다.';
        } else {
          message = '인증번호 재발송에 실패했습니다. 잠시 후 다시 시도해주세요.';
        }
        setState(() {
          _isResending = false;
          _errorMessage = message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      body: SafeArea(
        child: Column(
          children: [
            // 뒤로가기 버튼
            Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.arrow_back_ios,
                    color: AppColors.textPrimary,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ),
            ),

            // 메인 콘텐츠 (스크롤 가능)
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 제목
                    Text(
                      '인증번호를 입력해주세요.',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),

                    // 안내 문구
                    Text(
                      '휴대폰 번호로 발송된 인증번호를 입력해주세요.',
                      style: TextStyle(
                        fontSize: 16,
                        color: AppColors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 30),
                    // 전화번호 표시 필드 (읽기 전용)
                    TextField(
                      readOnly: true,
                      controller: TextEditingController(
                        text: _formatPhoneNumber(widget.phoneNumber),
                      ),
                      style: TextStyle(
                        fontSize: 18,
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                      decoration: TextFieldDecorationUtil.readOnlyDecoration(
                        prefixIcon: Padding(
                          padding: const EdgeInsets.only(
                            top: 10,
                            left: 12,
                            right: 6,
                            bottom: 6,
                          ),
                          child: SvgPicture.asset(
                            'assets/icons/phone-icon.svg',
                            width: 24,
                            height: 24,
                            colorFilter: ColorFilter.mode(
                              AppColors.textSecondary,
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      ).copyWith(
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),

                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    // 인증번호 입력 필드
                    TextField(
                      controller: _codeController,
                      focusNode: _codeFocusNode,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      style: TextStyle(
                        fontSize: 18,
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 4,
                      ),
                      textAlign: TextAlign.start,
                      decoration: TextFieldDecorationUtil.defaultDecoration(
                        hintText: '6자리 인증번호 입력',
                        errorText: _errorMessage,
                        hasError: _errorMessage != null,
                        hasFocus: _codeFocusNode.hasFocus,
                        prefixIcon: Padding(
                          padding: const EdgeInsets.only(
                            top: 12,
                            left: 14,
                            right: 6,
                            bottom: 10,
                          ),
                          child: SvgPicture.asset(
                            'assets/icons/lock.svg',
                            width: 18,
                            height: 18,
                            colorFilter: ColorFilter.mode(
                              AppColors.textSecondary.withOpacity(0.8),
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 타이머 및 재발송
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Text(
                                _formatTime(_remainingSeconds),
                                style: TextStyle(
                                  fontSize: 16,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: _isResending ? null : _onResendCode,

                          label: Text(
                            ' 인증번호 재발송',
                            style: TextStyle(
                              fontSize: 14,
                              color:
                                  _isResending
                                      ? AppColors.textLight
                                      : Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _isResending
                                    ? AppColors.borderLight
                                    : AppColors.primaryGreen,
                            disabledBackgroundColor: AppColors.borderLight,
                            foregroundColor: Colors.white,
                            disabledForegroundColor: AppColors.textLight,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(13),
                            ),
                            elevation: 0,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),

            // 인증하기 버튼 (하단 고정)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      (_isButtonEnabled &&
                              !_isVerifying &&
                              _remainingSeconds > 0)
                          ? _onVerify
                          : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.borderLight,
                    disabledForegroundColor: AppColors.textLight,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 0,
                  ),
                  child:
                      _isVerifying
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
                            '인증하기',
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
