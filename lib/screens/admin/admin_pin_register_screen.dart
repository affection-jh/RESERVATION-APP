import 'package:flutter/material.dart';
import 'package:pinput/pinput.dart';
import 'package:provider/provider.dart';
import '../../theme/app_colors.dart';
import '../../services/auth_service.dart';
import '../../providers/auth_provider.dart';
import 'widgets/admin_place_registration_screen.dart';

/// 관리자 PIN 등록 화면 (회원가입 시)
class AdminPinRegisterScreen extends StatefulWidget {
  final String phoneNumber;
  final String verificationCode;

  const AdminPinRegisterScreen({
    super.key,
    required this.phoneNumber,
    required this.verificationCode,
  });

  @override
  State<AdminPinRegisterScreen> createState() => _AdminPinRegisterScreenState();
}

class _AdminPinRegisterScreenState extends State<AdminPinRegisterScreen> {
  final TextEditingController _pinController = TextEditingController();
  final FocusNode _pinFocusNode = FocusNode();
  bool _isLoading = false;
  String? _userName; // 사용자 이름 (조회해서 표시)
  String _errorMessage = '';
  String? _firstPin; // 첫 번째 입력된 PIN
  bool _isConfirming = false; // 두 번째 입력 중인지 여부
  bool _isPinVerified = false; // 재검증에서 PIN이 일치(정상)인지 여부

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
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
    final pin = _pinController.text;

    // 6자리 모두 입력되었을 때
    if (pin.length == 6) {
      if (!_isConfirming) {
        // 첫 번째 입력 완료 - PIN 저장하고 비우기
        setState(() {
          _firstPin = pin;
          _isConfirming = true;
          _isPinVerified = false;
          _errorMessage = '';
        });
        // 입력 필드 비우기
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            _pinController.clear();
            _pinFocusNode.requestFocus();
          }
        });
      } else {
        // 두 번째 입력 완료 - PIN 비교
        if (_firstPin == pin) {
          // PIN이 일치하면 등록 버튼 활성화
          setState(() {
            _errorMessage = '';
            _isPinVerified = true;
          });
        } else {
          // PIN이 다르면 초기화
          setState(() {
            _firstPin = null;
            _isConfirming = false;
            _isPinVerified = false;
            _errorMessage = 'PIN이 일치하지 않습니다. 다시 입력해주세요.';
          });
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted) {
              _pinController.clear();
              _pinFocusNode.requestFocus();
            }
          });
        }
      }
    } else {
      // 입력 중일 때 에러 메시지 초기화
      setState(() {
        if (_isConfirming) _isPinVerified = false;
        if (_errorMessage.isNotEmpty &&
            _errorMessage != 'PIN이 일치하지 않습니다. 다시 입력해주세요.') {
          _errorMessage = '';
        }
      });
    }
  }

  /// 사용자 정보 로드
  Future<void> _loadUserInfo() async {
    try {
      final authService = AuthService();
      // 전화번호로 사용자 정보 조회
      final user = await authService.findUserByPhone(widget.phoneNumber);
      if (mounted) {
        setState(() {
          _userName = user?.name;
        });
      }
    } catch (e) {
      // 에러 무시
    }
  }

  bool _isFormValid() {
    // 두 번째 입력이 완료되고 PIN이 일치해야 함
    return _isConfirming &&
        _pinController.text.length == 6 &&
        _firstPin != null &&
        _firstPin == _pinController.text;
  }

  Future<void> _onRegister() async {
    debugPrint('onRegister');
    if (!_isFormValid() || _isLoading) {
      debugPrint('isFormValid: ${_isFormValid()}');
      debugPrint('isLoading: $_isLoading');
      return;
    }

    // PIN 확인
    if (_firstPin == null || _pinController.text != _firstPin) {
      setState(() {
        _errorMessage = 'PIN이 일치하지 않습니다.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final authService = AuthService();
      debugPrint('authService: $authService');

      // 관리자 회원가입 (이름은 사용자 정보에서 가져옴)
      final userName = _userName ?? '관리자'; // 사용자 정보가 없으면 기본값 사용
      final admin = await authService.registerAdmin(
        phoneNumber: widget.phoneNumber,
        verificationCode: widget.verificationCode,
        name: userName,
        pin: _firstPin ?? _pinController.text, // 첫 번째 입력된 PIN 사용
      );

      debugPrint('admin: $admin');
      // AuthProvider에 관리자 정보 설정
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      authProvider.setCurrentAdmin(admin);

      // 플레이스가 없으면 플레이스 등록 화면으로 이동
      if (mounted) {
        // 모든 이전 화면을 제거하고 플레이스 등록 화면으로 이동
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder:
                (context) => AdminPlaceRegistrationScreen(
                  phoneNumber: widget.phoneNumber,
                  verificationCode: widget.verificationCode,
                  isFromRegistration: true, // 회원가입 플로우
                ),
          ),
          (route) => false, // 모든 이전 화면 제거
        );
      }
    } catch (e) {
      if (mounted) {
        debugPrint('e: $e');
        final msg = e.toString().replaceAll('Exception: ', '');

        // 이미 등록된 관리자인 경우: 1단계로 리셋하지 말고 PIN 입력으로 보낸다
        if (msg.contains('이미 등록된 관리자')) {
          Navigator.of(context).pushNamedAndRemoveUntil(
            '/admin-pin-input',
            (route) => false,
            arguments: {
              'phoneNumber': widget.phoneNumber,
              'verificationCode': widget.verificationCode,
            },
          );
          return;
        }

        // 실패 시에도 1단계로 리셋하지 않고(무한루프처럼 보이는 원인),
        // 에러만 보여주고 재시도 가능하게 유지
        setState(() {
          _isLoading = false;
          _errorMessage =
              msg.isNotEmpty
                  ? msg
                  : msg.contains('이미 등록된')
                  ? '이미 등록된 관리자입니다. 이전 화면으로 돌아가서 다시 시도해주세요.'
                  : '관리자 코드 등록에 실패했습니다. 다시 시도해주세요.';
          _isPinVerified = false;
        });
        _pinController.clear();
        _pinFocusNode.requestFocus();

        // Firestore 미구현 에러는 무시하고 계속 진행
        if (msg.contains('UnimplementedError')) {
          // UnimplementedError는 무시하고 플레이스 생성 화면으로 이동
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder:
                  (context) => AdminPlaceRegistrationScreen(
                    phoneNumber: widget.phoneNumber,
                    verificationCode: widget.verificationCode,
                    isFromRegistration: true,
                  ),
            ),
            (route) => false, // 모든 이전 화면 제거
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            // 헤더
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.arrow_back_ios_rounded,
                      color: AppColors.textPrimary,
                      size: 24,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            // 스크롤 가능한 콘텐츠
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 제목
                    _isConfirming
                        ? Text(
                          '다시 한번 입력해주세요',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.5,
                          ),
                        )
                        : Text(
                          '관리자코드를 설정합니다',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.5,
                          ),
                        ),

                    const SizedBox(height: 4),
                    Text(
                      _isConfirming
                          ? '확인을 위해 동일한 코드를 다시 입력해주세요.'
                          : '다음 접속시 이 코드로 관리자임을 인증합니다.',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textSecondary,
                      ),
                    ),

                    const SizedBox(height: 28),

                    // 6자리 PIN 입력 (토스 스타일)
                    _buildPinInput(),

                    const SizedBox(height: 60),
                  ],
                ),
              ),
            ),
            // 하단 버튼 (키보드 위에 붙음)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      (_isFormValid() && !_isLoading) ? _onRegister : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    disabledBackgroundColor: AppColors.borderLight,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
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
                          : Text(
                            _isConfirming ? '관리자 코드 등록' : '다음',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
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
    // 재검증 단계(다시 입력)에서는 기본 테두리를 초록색으로,
    // "일치"까지 완료되면 더 확실한 초록(굵게) 느낌
    final isConfirming = _isConfirming;
    final isCorrect = _isPinVerified;
    final showGreenBorder = isConfirming || isCorrect;

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
        border: Border.all(
          color:
              showGreenBorder ? AppColors.primaryGreen : AppColors.borderLight,
          width: showGreenBorder ? 2 : 1,
        ),
      ),
    );

    final focusedPinTheme = defaultPinTheme.copyWith(
      decoration: defaultPinTheme.decoration!.copyWith(
        border: Border.all(color: AppColors.primaryGreen, width: 2),
      ),
    );

    final filledPinTheme = defaultPinTheme.copyWith(
      decoration: defaultPinTheme.decoration!.copyWith(
        border: Border.all(
          color:
              showGreenBorder ? AppColors.primaryGreen : AppColors.borderLight,
          width: 2,
        ),
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
        crossAxisAlignment: CrossAxisAlignment.start,
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
              // 6자리 입력 완료 시 상태 업데이트만 (자동 등록 안 함)
              setState(() {});
            },
          ),
          if (_errorMessage.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage,
              style: TextStyle(fontSize: 14, color: Colors.red, height: 1.4),
              textAlign: TextAlign.start,
            ),
          ],
        ],
      ),
    );
  }
}
