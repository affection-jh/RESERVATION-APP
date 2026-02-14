import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../utils/text_field_decoration_util.dart';
import '../services/auth_service.dart';
import '../providers/auth_provider.dart';
import 'package:provider/provider.dart';

/// 신규 사용자 이름 입력 화면
class NameInputScreen extends StatefulWidget {
  final String phoneNumber;
  final String smsCode;

  const NameInputScreen({
    super.key,
    required this.phoneNumber,
    required this.smsCode,
  });

  @override
  State<NameInputScreen> createState() => _NameInputScreenState();
}

class _NameInputScreenState extends State<NameInputScreen> {
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocusNode = FocusNode();
  final AuthService _authService = AuthService();
  bool _isSubmitting = false;
  String? _errorMessage; // 에러 메시지

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_onNameChanged);
    // 화면 진입 시 자동으로 키보드 포커스
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  void _onNameChanged() {
    setState(() {
      // 이름 입력 시 에러 메시지 초기화
      if (_errorMessage != null) {
        _errorMessage = null;
      }
    });
  }

  bool _isFormValid() {
    return _nameController.text.trim().isNotEmpty;
  }

  Future<void> _onSubmit() async {
    if (!_isFormValid() || _isSubmitting) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);

      // Firebase Auth를 통해 인증 코드 확인 및 회원가입
      final result = await _authService.verifyCodeAndSignIn(
        smsCode: widget.smsCode,
        name: name,
        phoneNumber: widget.phoneNumber,
      );

      // ✅ 명시적 재로그인(전화번호 인증) 직후에는 자동 분기 금지:
      // - 관리자 등록 여부가 있어도 관리자 등록/PIN으로 자동 이동하지 않음
      // - 승인된 플레이스가 있어도 /main으로 자동 이동하지 않음
      await _authService.setRequireManualEntrySelection(true);

      // 사용자 정보 설정
      authProvider.setCurrentUser(result.user);

      if (mounted) {
        // 항상 Waiting으로 이동해서 플레이스/역할을 명시적으로 선택하게 한다.
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/place-waiting',
          (route) => false,
          arguments: widget.phoneNumber,
        );
      }
    } catch (e) {
      if (mounted) {
        // 세션 만료 에러인 경우 더 친화적인 메시지
        String errorMessage = e.toString();
        if (errorMessage.contains('session-expired') ||
            errorMessage.contains('만료되었거나')) {
          errorMessage = '인증 코드가 만료되었습니다. 인증 코드를 다시 요청해주세요.';
          // 인증 코드 입력 화면으로 돌아가기
          Navigator.of(context).pop();
        } else {
          errorMessage = errorMessage.replaceAll('Exception: ', '');
          // TextField에 에러 표시
          setState(() {
            _errorMessage = errorMessage;
            _isSubmitting = false;
          });
        }
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

            // 메인 콘텐츠
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 20),
                    // 제목
                    Text(
                      '이름을 입력해주세요',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),

                    const SizedBox(height: 20),

                    TextField(
                      controller: _nameController,
                      focusNode: _nameFocusNode,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _onSubmit(),
                      inputFormatters: [LengthLimitingTextInputFormatter(20)],
                      style: TextStyle(
                        fontSize: 18,
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                      decoration: InputDecoration(
                        prefixIcon: Padding(
                          padding: const EdgeInsets.only(
                            top: 10,
                            left: 12,
                            right: 6,
                            bottom: 6,
                          ),
                          child: Icon(
                            Icons.person,
                            color: AppColors.textSecondary,
                            size: 20,
                          ),
                        ),
                        labelText: '이름',
                        labelStyle: TextStyle(
                          fontSize: 18,
                          color:
                              _errorMessage != null
                                  ? Colors.red
                                  : AppColors.primaryGreen,
                          fontWeight: FontWeight.w500,
                        ),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        hintText: '이름을 입력해주세요',
                        hintStyle: TextStyle(
                          fontSize: 18,
                          color: AppColors.textLight,
                        ),
                        errorText: _errorMessage,
                        errorStyle: TextFieldDecorationUtil.defaultErrorStyle(),
                        filled: true,
                        fillColor: AppColors.backgroundWhite,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(
                            color:
                                _errorMessage != null
                                    ? Colors.red
                                    : AppColors.primaryGreen,
                            width: 1,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(
                            color:
                                _errorMessage != null
                                    ? Colors.red
                                    : AppColors.primaryGreen,
                            width: 1,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(
                            color:
                                _errorMessage != null
                                    ? Colors.red
                                    : AppColors.primaryGreen,
                            width: 1,
                          ),
                        ),
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.red, width: 1),
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.red, width: 1),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 18,
                        ),
                      ),
                      onChanged: (_) => _onNameChanged(),
                    ),

                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ), // 완료 버튼
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      (_isFormValid() && !_isSubmitting) ? _onSubmit : null,
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
                      _isSubmitting
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
                            '완료',
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
