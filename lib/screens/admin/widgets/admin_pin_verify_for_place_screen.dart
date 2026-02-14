import 'package:flutter/material.dart';
import 'package:pinput/pinput.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../services/auth_service.dart';
import '../../../providers/auth_provider.dart';
import 'admin_place_registration_screen.dart';

/// 플레이스 추가를 위한 관리자 PIN 확인 화면
class AdminPinVerifyForPlaceScreen extends StatefulWidget {
  const AdminPinVerifyForPlaceScreen({super.key});

  @override
  State<AdminPinVerifyForPlaceScreen> createState() =>
      _AdminPinVerifyForPlaceScreenState();
}

class _AdminPinVerifyForPlaceScreenState
    extends State<AdminPinVerifyForPlaceScreen> {
  final TextEditingController _pinController = TextEditingController();
  final FocusNode _pinFocusNode = FocusNode();
  bool _isLoading = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _pinController.addListener(_onPinChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pinFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _pinController.dispose();
    _pinFocusNode.dispose();
    super.dispose();
  }

  void _onPinChanged() {
    setState(() {
      if (_errorMessage.isNotEmpty) {
        _errorMessage = '';
      }
    });
  }

  bool _isFormValid() {
    return _pinController.text.length == 6;
  }

  Future<void> _onVerify() async {
    if (!_isFormValid() || _isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final admin = authProvider.currentAdmin;

      if (admin == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = '관리자 정보를 찾을 수 없습니다.';
        });
        return;
      }

      final authService = AuthService();

      // 관리자 인증 (현재 관리자 전화번호 + 빈 인증코드 + PIN)
      await authService.authenticateAdmin(
        phoneNumber: admin.phoneNumber,
        verificationCode: '', // 플레이스 추가 플로우에서는 인증코드 불필요
        pin: _pinController.text,
      );

      // 핀 확인 성공 후 플레이스 등록 화면으로 이동
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => const AdminPlaceRegistrationScreen(),
          ),
        );
      }
    } catch (e) {
      debugPrint('error: $e');
      if (mounted) {
        final errorMessage = e.toString().replaceAll('Exception: ', '');
        setState(() {
          _isLoading = false;
          _errorMessage = errorMessage;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundWhite,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 메인 콘텐츠
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 제목
                    Text(
                      '관리자 인증 PIN을 입력해주세요',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // 안내 문구
                    Text(
                      '플레이스 추가를 위해 관리자 PIN을 입력해주세요.',
                      style: TextStyle(
                        fontSize: 16,
                        color: AppColors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 28),

                    // 6자리 PIN 입력
                    _buildPinInput(),

                    if (_errorMessage.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage,
                        style: TextStyle(
                          fontSize: 15,
                          color: Colors.red,
                          height: 1.4,
                        ),
                        textAlign: TextAlign.start,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // 확인 버튼 (6자리 입력 시에만 표시)
            if (_isFormValid())
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed:
                        (_isFormValid() && !_isLoading && _errorMessage.isEmpty)
                            ? _onVerify
                            : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppColors.borderLight,
                      disabledForegroundColor: AppColors.textLight,
                      padding: const EdgeInsets.symmetric(vertical: 18),
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
                              '확인',
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

  /// 토스 스타일 6자리 PIN 입력 위젯
  Widget _buildPinInput() {
    final defaultPinTheme = PinTheme(
      width: 70,
      height: 72,
      textStyle: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderLight, width: 1),
      ),
    );

    final focusedPinTheme = defaultPinTheme.copyWith(
      decoration: defaultPinTheme.decoration!.copyWith(
        border: Border.all(color: AppColors.primaryGreen, width: 2),
      ),
    );

    final filledPinTheme = defaultPinTheme.copyWith(
      decoration: defaultPinTheme.decoration!.copyWith(
        border: Border.all(color: AppColors.primaryGreen, width: 2),
      ),
    );

    final errorPinTheme = defaultPinTheme.copyWith(
      decoration: defaultPinTheme.decoration!.copyWith(
        border: Border.all(color: Colors.red, width: 2),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 0),
      child: Column(
        children: [
          Pinput(
            length: 6,
            controller: _pinController,
            focusNode: _pinFocusNode,
            defaultPinTheme:
                _errorMessage.isNotEmpty ? errorPinTheme : defaultPinTheme,
            focusedPinTheme:
                _errorMessage.isNotEmpty ? errorPinTheme : focusedPinTheme,
            submittedPinTheme:
                _errorMessage.isNotEmpty ? errorPinTheme : filledPinTheme,
            errorPinTheme: errorPinTheme,
            pinputAutovalidateMode: PinputAutovalidateMode.onSubmit,
            showCursor: true,
            keyboardType: TextInputType.number,
            onCompleted: (pin) {
              setState(() {});
            },
          ),
        ],
      ),
    );
  }
}
