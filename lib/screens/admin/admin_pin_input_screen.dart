import 'package:flutter/material.dart';
import 'package:pinput/pinput.dart';
import 'package:provider/provider.dart';
import '../../theme/app_colors.dart';
import '../../services/auth_service.dart';
import '../../services/admin_service.dart';
import '../../models/admin_user.dart';
import '../../providers/auth_provider.dart';
import '../admin_screen.dart';
import 'widgets/admin_place_registration_screen.dart';

/// 관리자 PIN 입력 화면 (기존 관리자 로그인 시)
class AdminPinInputScreen extends StatefulWidget {
  final String phoneNumber;
  final String verificationCode;

  const AdminPinInputScreen({
    super.key,
    required this.phoneNumber,
    required this.verificationCode,
  });

  @override
  State<AdminPinInputScreen> createState() => _AdminPinInputScreenState();
}

class _AdminPinInputScreenState extends State<AdminPinInputScreen> {
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

  Future<void> _onLogin() async {
    if (!_isFormValid() || _isLoading) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final authService = AuthService();

      // 디버깅: 전달되는 값 확인
      debugPrint(
        '[AdminPinInput] phoneNumber: "${widget.phoneNumber}" (length: ${widget.phoneNumber.length})',
      );
      debugPrint(
        '[AdminPinInput] verificationCode: "${widget.verificationCode}" (length: ${widget.verificationCode.length})',
      );
      debugPrint(
        '[AdminPinInput] pin: "${_pinController.text}" (length: ${_pinController.text.length})',
      );

      // 관리자 인증 (전화번호 + 인증번호 + PIN)
      final authResult = await authService.authenticateAdmin(
        phoneNumber: widget.phoneNumber,
        verificationCode: widget.verificationCode,
        pin: _pinController.text,
      );

      debugPrint('[AdminPinInput] authResult: $authResult');

      // authenticateAdmin 내부에서 AdminService.loginWithAdmin(admin) 호출됨 → placeIds 포함
      final adminService = AdminService();
      final currentAdmin = adminService.currentAdmin;

      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      if (currentAdmin != null) {
        authProvider.setCurrentAdmin(currentAdmin);
      } else {
        authProvider.setCurrentAdmin(
          AdminUser(
            userId: authResult.user.userId,
            name: authResult.user.name,
            phoneNumber: authResult.user.phoneNumber,
            placeIds: [],
            createdAt: authResult.user.createdAt,
            updatedAt: authResult.user.updatedAt,
          ),
        );
      }

      if (!mounted) return;
      await authService.clearRequireManualEntrySelection();
      if (!mounted) return;

      // 이미 플레이스가 있으면 관리자 홈(들어가기), 없을 때만 플레이스 등록 플로우
      final adminPlaceIds = authProvider.currentAdmin?.placeIds ?? [];
      debugPrint('[AdminPinInput] adminPlaceIds: $adminPlaceIds (count: ${adminPlaceIds.length})');
      if (adminPlaceIds.isEmpty) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder:
                (context) => AdminPlaceRegistrationScreen(
                  isFromLogin: true,
                ),
          ),
          (route) => false,
        );
        return;
      }

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const AdminScreen()),
        (route) => false,
      );
    } catch (e) {
      debugPrint('error: $e');
      if (mounted) {
        final errorMessage = e.toString().replaceAll('Exception: ', '');
        setState(() {
          _isLoading = false;
          _errorMessage = errorMessage;
          // PIN은 지우지 않고 에러만 표시
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
            // 헤더
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () {
                      Navigator.of(context).pushNamedAndRemoveUntil(
                        '/place-waiting',
                        (route) => false,
                        arguments: widget.phoneNumber,
                      );
                    },
                    icon: Icon(
                      Icons.arrow_back_ios,
                      color: AppColors.textPrimary,
                      size: 24,
                    ),
                  ),
                ],
              ),
            ),

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
                      '관리자 인증을 위해 PIN을 입력해주세요.',
                      style: TextStyle(
                        fontSize: 16,
                        color: AppColors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 28),

                    // 6자리 PIN 입력 (토스 스타일)
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
                  horizontal: 24,
                  vertical: 12,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed:
                        (_isFormValid() && !_isLoading && _errorMessage.isEmpty)
                            ? _onLogin
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
              // 6자리 입력 완료 시 확인 버튼이 나타나도록 setState 호출
              setState(() {});
            },
          ),
        ],
      ),
    );
  }
}
