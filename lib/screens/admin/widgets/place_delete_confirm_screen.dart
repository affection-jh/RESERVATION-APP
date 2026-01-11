import 'package:flutter/material.dart';
import 'package:pinput/pinput.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../services/auth_service.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/admin_provider.dart';
import '../../../services/user_service.dart';
import '../../../utils/snackbar_util.dart';
import '../../../models/place.dart';
import '../../../utils/text_field_decoration_util.dart';

/// 플레이스 삭제 확인 화면 (2중 안전장치)
class PlaceDeleteConfirmScreen extends StatefulWidget {
  final Place place;

  const PlaceDeleteConfirmScreen({super.key, required this.place});

  @override
  State<PlaceDeleteConfirmScreen> createState() =>
      _PlaceDeleteConfirmScreenState();
}

class _PlaceDeleteConfirmScreenState extends State<PlaceDeleteConfirmScreen> {
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _placeNameController = TextEditingController();
  final FocusNode _pinFocusNode = FocusNode();
  final FocusNode _placeNameFocusNode = FocusNode();

  bool _isLoading = false;
  bool _isPinVerified = false;
  String _pinErrorMessage = '';
  String _placeNameErrorMessage = '';

  @override
  void initState() {
    super.initState();
    _pinController.addListener(_onPinChanged);
    _placeNameController.addListener(_onPlaceNameChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pinFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _pinController.dispose();
    _placeNameController.dispose();
    _pinFocusNode.dispose();
    _placeNameFocusNode.dispose();
    super.dispose();
  }

  void _onPinChanged() {
    setState(() {
      if (_pinErrorMessage.isNotEmpty) {
        _pinErrorMessage = '';
      }
    });
  }

  void _onPlaceNameChanged() {
    setState(() {
      if (_placeNameErrorMessage.isNotEmpty) {
        _placeNameErrorMessage = '';
      }
    });
  }

  bool _isPinValid() {
    return _pinController.text.length == 6;
  }

  bool _isPlaceNameValid() {
    return _placeNameController.text.trim() == widget.place.name;
  }

  bool _canDelete() {
    return _isPinVerified && _isPlaceNameValid() && !_isLoading;
  }

  Future<void> _verifyPin() async {
    if (!_isPinValid() || _isLoading) return;

    setState(() {
      _isLoading = true;
      _pinErrorMessage = '';
    });

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final adminProvider = Provider.of<AdminProvider>(context, listen: false);
      final currentAdmin =
          authProvider.currentAdmin ?? adminProvider.currentAdmin;

      if (currentAdmin == null) {
        throw Exception('관리자 정보를 찾을 수 없습니다.');
      }

      final authService = AuthService();

      // PIN 인증 (verificationCode는 빈 문자열로 전달)
      await authService.authenticateAdmin(
        phoneNumber: currentAdmin.phoneNumber,
        verificationCode: '', // 삭제 확인용이므로 빈 문자열
        pin: _pinController.text,
      );

      if (mounted) {
        setState(() {
          _isPinVerified = true;
          _isLoading = false;
          _pinErrorMessage = '';
        });
        // PIN 인증 성공 후 플레이스 이름 입력 필드로 포커스 이동
        _placeNameFocusNode.requestFocus();
      }
    } catch (e) {
      if (mounted) {
        final errorMessage = e.toString().replaceAll('Exception: ', '');
        setState(() {
          _isLoading = false;
          _isPinVerified = false;
          _pinErrorMessage = errorMessage;
        });
      }
    }
  }

  Future<void> _handleDelete() async {
    if (!_canDelete()) return;

    // 마지막 확인 다이얼로그
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('최종 확인'),
          content: Text(
            '"${widget.place.name}" 플레이스를 정말로 삭제하시겠습니까?\n\n이 작업은 되돌릴 수 없습니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('삭제'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final adminProvider = Provider.of<AdminProvider>(context, listen: false);
      final userService = UserService();

      final currentAdmin =
          authProvider.currentAdmin ?? adminProvider.currentAdmin;
      final phoneNumberForWaiting = currentAdmin?.phoneNumber ?? '';

      // 플레이스 삭제
      await placeProvider.deletePlace(widget.place.id);

      // Admin의 placeIds에서 제거
      if (currentAdmin != null) {
        final updatedAdmin = currentAdmin.removePlace(widget.place.id);
        await userService.updateAdmin(updatedAdmin);

        // Provider 업데이트
        if (authProvider.currentAdmin?.userId == updatedAdmin.userId) {
          authProvider.setCurrentAdmin(updatedAdmin);
        }
        if (adminProvider.currentAdmin?.userId == updatedAdmin.userId) {
          adminProvider.setCurrentAdmin(updatedAdmin);
        }

        // PlaceSwitchWidget 등에서 사용하는 관리 플레이스 캐시도 즉시 반영
        final updatedManagedIds = authProvider.adminManagedPlaceIds
            .where((id) => id != widget.place.id)
            .toList();
        authProvider.setAdminManagedPlaceIds(updatedManagedIds);
      }

      if (mounted) {
        // 완료되면 waiting_screen으로 이동 (기존 화면 스택 제거)
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/place-waiting',
          (route) => false,
          arguments: phoneNumberForWaiting,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        SnackbarUtil.showError(
          context,
          '플레이스 삭제 중 오류가 발생했습니다: ${e.toString()}',
        );
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.arrow_back_ios,
                      color: AppColors.primaryGreen,
                      size: 24,
                    ),
                  ),
                  Text(
                    '플레이스 삭제',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),

            // 메인 콘텐츠
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 22),

                    // 경고 메시지
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.red,
                            size: 24,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '이 작업은 되돌릴 수 없습니다.\n모든 데이터가 영구적으로 삭제됩니다.',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.red.shade700,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 42),

                    // 1단계: PIN 인증
                    Text(
                      '관리자 인증을 위해 PIN을 입력해주세요.',
                      style: TextStyle(
                        fontSize: 15,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // PIN 입력
                    _buildPinInput(),

                    if (_pinErrorMessage.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        _pinErrorMessage,
                        style: TextStyle(fontSize: 14, color: Colors.red),
                      ),
                    ],

                    // PIN 인증 버튼
                    if (!_isPinVerified && _isPinValid())
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _verifyPin,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryGreen,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: AppColors.borderLight,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: _isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  )
                                : const Text(
                                    'PIN 인증',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                        ),
                      ),

                    const SizedBox(height: 62),

                    // 2단계: 플레이스 이름 확인
                    if (_isPinVerified) ...[
                      Text(
                        '아래에 플레이스 이름을 정확히 입력해주세요.',
                        style: TextStyle(
                          fontSize: 15,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '플레이스 이름: "${widget.place.name}"',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // 플레이스 이름 입력
                      TextField(
                        controller: _placeNameController,
                        focusNode: _placeNameFocusNode,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) {
                          if (_canDelete()) {
                            _handleDelete();
                          }
                        },
                        decoration: TextFieldDecorationUtil.defaultDecoration(
                          hintText: '플레이스 이름을 입력하세요',

                          fillColor: AppColors.backgroundLight,
                          hasError: _placeNameErrorMessage.isNotEmpty,

                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.textPrimary,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),

                      if (_placeNameErrorMessage.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          _placeNameErrorMessage,
                          style: TextStyle(fontSize: 13, color: Colors.red),
                        ),
                      ],

                      const SizedBox(height: 62),

                      // 삭제 버튼
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _canDelete() ? _handleDelete : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red,
                            disabledBackgroundColor: AppColors.borderLight,
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                )
                              : const Text(
                                  '플레이스 삭제',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// PIN 입력 위젯
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
        border: Border.all(
          color: _pinErrorMessage.isNotEmpty
              ? Colors.red
              : (_isPinVerified
                    ? AppColors.primaryGreen
                    : AppColors.borderLight),
          width: _isPinVerified ? 2 : 1,
        ),
      ),
    );

    final focusedPinTheme = defaultPinTheme.copyWith(
      decoration: defaultPinTheme.decoration!.copyWith(
        border: Border.all(
          color: _pinErrorMessage.isNotEmpty
              ? Colors.red
              : AppColors.primaryGreen,
          width: 2,
        ),
      ),
    );

    final filledPinTheme = defaultPinTheme.copyWith(
      decoration: defaultPinTheme.decoration!.copyWith(
        border: Border.all(
          color: _isPinVerified
              ? AppColors.primaryGreen
              : (_pinErrorMessage.isNotEmpty
                    ? Colors.red
                    : AppColors.borderLight),
          width: 2,
        ),
      ),
    );

    return Pinput(
      length: 6,
      controller: _pinController,
      focusNode: _pinFocusNode,
      enabled: !_isPinVerified,
      defaultPinTheme: _pinErrorMessage.isNotEmpty
          ? defaultPinTheme.copyWith(
              decoration: defaultPinTheme.decoration!.copyWith(
                border: Border.all(color: Colors.red, width: 2),
              ),
            )
          : (_isPinVerified ? filledPinTheme : defaultPinTheme),
      focusedPinTheme: _pinErrorMessage.isNotEmpty
          ? focusedPinTheme.copyWith(
              decoration: focusedPinTheme.decoration!.copyWith(
                border: Border.all(color: Colors.red, width: 2),
              ),
            )
          : focusedPinTheme,
      submittedPinTheme: _isPinVerified ? filledPinTheme : defaultPinTheme,
      showCursor: !_isPinVerified,
      keyboardType: TextInputType.number,
      onCompleted: (pin) {
        if (!_isPinVerified) {
          _verifyPin();
        }
      },
    );
  }
}
