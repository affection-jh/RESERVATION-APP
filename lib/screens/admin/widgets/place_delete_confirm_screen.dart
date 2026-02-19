import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../services/user_service.dart';
import '../../../utils/navigator_key.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/firestore_utils.dart';
import '../../../models/place.dart';
import '../../../utils/text_field_decoration_util.dart';
import '../../../widgets/common_dialog.dart';

/// 플레이스 삭제 확인 화면 (로그인된 매니저/소유자 인증 + 플레이스 이름 입력 확인)
class PlaceDeleteConfirmScreen extends StatefulWidget {
  final Place place;

  const PlaceDeleteConfirmScreen({super.key, required this.place});

  @override
  State<PlaceDeleteConfirmScreen> createState() =>
      _PlaceDeleteConfirmScreenState();
}

class _PlaceDeleteConfirmScreenState extends State<PlaceDeleteConfirmScreen> {
  final TextEditingController _placeNameController = TextEditingController();
  final FocusNode _placeNameFocusNode = FocusNode();

  bool _isLoading = false;
  bool _leaveRequested = false;
  String _placeNameErrorMessage = '';

  @override
  void initState() {
    super.initState();
    _placeNameController.addListener(_onPlaceNameChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _placeNameFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _placeNameController.dispose();
    _placeNameFocusNode.dispose();
    super.dispose();
  }

  void _onPlaceNameChanged() {
    setState(() {
      if (_placeNameErrorMessage.isNotEmpty) {
        _placeNameErrorMessage = '';
      }
    });
  }

  bool _isPlaceNameValid() {
    return _placeNameController.text.trim() == widget.place.name;
  }

  bool _canDelete() {
    return _isPlaceNameValid() && !_isLoading;
  }

  Future<void> _handleDelete() async {
    if (!_canDelete()) return;

    setState(() {
      _isLoading = true;
    });
    if (_leaveRequested) return;

    FocusScope.of(context).unfocus();

    try {
      if (!await FirestoreUtils.canReachFirestoreForSave(
        probeCollection: 'places',
        probeDocId: widget.place.id,
      )) {
        if (mounted) {
          setState(() => _isLoading = false);
          SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요. ');
        }
        return;
      }
      // 나가기 후에도 요청이 이미 나간 상태면 로딩 스낵바로 진행 중임을 표시 (완료 시 success/error로 대체됨)
      final loadCtx = navigatorKey.currentContext;
      if (loadCtx != null) SnackbarUtil.showLoading(loadCtx, '삭제 중…');

      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final userService = UserService();
      final currentAdmin = authProvider.currentAdmin;
      final phoneNumberForWaiting = currentAdmin?.phoneNumber ?? '';

      await placeProvider.deletePlace(widget.place.id);

      if (currentAdmin != null) {
        final updatedAdmin = currentAdmin.removePlace(widget.place.id);
        await userService.updateAdmin(updatedAdmin);
        if (authProvider.currentAdmin?.userId == updatedAdmin.userId) {
          authProvider.setCurrentAdmin(updatedAdmin);
        }
      }

      // 삭제 성공 시 항상 PlaceWaiting으로 이동 (나가기 후 백그라운드 완료여도 동일)
      final navContext = mounted ? context : navigatorKey.currentContext;
      if (navContext != null) {
        Navigator.of(navContext).pushNamedAndRemoveUntil(
          '/place-waiting',
          (route) => false,
          arguments: {
            'phoneNumber': phoneNumberForWaiting,
            'skipAutoEnter': true,
          },
        );
        SnackbarUtil.showSuccess(navContext, '플레이스가 삭제되었습니다.');
      }
    } catch (e) {
      // 나가기한 뒤 실패한 경우에도 결과 알림
      final resultCtx = mounted ? context : navigatorKey.currentContext;
      if (resultCtx != null) {
        SnackbarUtil.showInfoFromError(
          resultCtx,
          e,
          fallback: '플레이스 삭제에 실패했습니다. 잠시 후 다시 시도해주세요.',
        );
      }
    } finally {
      SnackbarUtil.dismissLoading();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        SnackbarUtil.dismissLoading();
      });
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleBackDuringDelete() async {
    if (!_isLoading) return;
    final leave = await CommonDialog.showSavingLeaveConfirm(
      context: context,
      title: '삭제 중입니다',
      onLeave: () => _leaveRequested = true,
    );
    if (leave && mounted) {
      setState(() => _isLoading = false);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isLoading,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_isLoading) await _handleBackDuringDelete();
      },
      child: Scaffold(
        backgroundColor: AppColors.backgroundWhite,
        body: SafeArea(
          child: Column(
            children: [
              // 헤더
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 0,
                ),
                child: Row(
                  children: [
                    IconButton(
                      onPressed:
                          _isLoading
                              ? _handleBackDuringDelete
                              : () => Navigator.of(context).pop(),
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
                          borderRadius: BorderRadius.circular(18),
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
                                '이 작업은 되돌릴 수 없습니다.',
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

                      // 플레이스 이름 확인 (삭제 방지용)
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
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                width: double.infinity,
                child: FilledButton(
                  onPressed: _canDelete() ? _handleDelete : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    disabledBackgroundColor: AppColors.borderLight,
                    disabledForegroundColor: AppColors.textSecondary,
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
                                AppColors.textPrimary,
                              ),
                            ),
                          )
                          : Text(
                            '플레이스 삭제',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color:
                                  _canDelete()
                                      ? Colors.white
                                      : AppColors.textSecondary,
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
