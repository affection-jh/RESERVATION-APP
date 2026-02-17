import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
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
    } catch (e, stackTrace) {
      debugPrint('[NameInputScreen] 가입/인증 오류: $e');
      debugPrint('[NameInputScreen] 스택: $stackTrace');
      if (!mounted) return;
      String userMessage;
      if (e is firebase_auth.FirebaseAuthException) {
        if (e.code == 'invalid-verification-code') {
          userMessage = '인증번호가 올바르지 않습니다.';
        } else if (e.code == 'session-expired' ||
            e.code == 'invalid-verification-id') {
          userMessage = '인증 시간이 만료되었습니다. 인증번호를 다시 요청해주세요.';
          Navigator.of(context).pop();
          setState(() => _isSubmitting = false);
          return;
        } else {
          userMessage = '인증 중 오류가 발생했습니다. 다시 시도해주세요.';
        }
      } else if (e is FirebaseFunctionsException) {
        if (e.code == 'permission-denied' || e.code == 'unauthenticated') {
          userMessage = '일시적인 오류가 발생했습니다. 잠시 후 다시 시도해주세요.';
        } else if (e.code == 'invalid-argument') {
          userMessage = e.message ?? '입력값을 확인해주세요.';
        } else {
          userMessage = '처리 중 오류가 발생했습니다. 다시 시도해주세요.';
        }
      } else {
        final raw = e.toString();
        if (raw.contains('session-expired') ||
            raw.contains('만료되었습니다') ||
            raw.contains('만료되었거나')) {
          userMessage = '인증 코드가 만료되었습니다. 인증 코드를 다시 요청해주세요.';
          Navigator.of(context).pop();
          setState(() => _isSubmitting = false);
          return;
        }
        if (raw.contains('permission-denied') ||
            raw.contains('cloud_firestore')) {
          userMessage = '일시적인 오류가 발생했습니다. 잠시 후 다시 시도해주세요.';
        } else if (raw.contains('network') || raw.contains('Connection')) {
          userMessage = '네트워크 연결을 확인한 뒤 다시 시도해주세요.';
        } else {
          userMessage = '오류가 발생했습니다. 다시 시도해주세요.';
        }
      }
      setState(() {
        _errorMessage = userMessage;
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // 인증 완료 후 이름 입력 단계에서는 뒤로가기 차단
      child: Scaffold(
        backgroundColor: AppColors.backgroundWhite,
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 16),

              // 메인 콘텐츠
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 50),
                      // 제목
                      Text(
                        '이름을 입력해주세요',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.5,
                        ),
                      ),

                      const SizedBox(height: 10),

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
                        decoration: TextFieldDecorationUtil.defaultDecoration(
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
                          hintText: '이름을 입력해주세요',
                          errorText: _errorMessage,
                          hasError: _errorMessage != null,
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                        ),
                        onChanged: (_) => _onNameChanged(),
                      ),

                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ), // 완료 버튼
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed:
                        (_isFormValid() && !_isSubmitting) ? _onSubmit : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppColors.borderLight,
                      disabledForegroundColor: AppColors.textSecondary,
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
      ),
    );
  }
}
