import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../utils/format_utils.dart';
import '../utils/snackbar_util.dart';
import '../utils/text_field_decoration_util.dart';
import 'keyboard_bleed_fill.dart';

/// 전화번호(·선택 시 이름) 직접 입력 공통 바텀시트.
///
/// [title] 제목, [submitButtonText] 버튼 문구.
/// [showNameField] true면 이름 필드 표시.
/// [checkPhoneError] 11자리 입력 시 실시간 검사(예: 중복), non-null 반환 시 에러 문구 표시.
/// [onSubmit] 정규화된 전화번호와 이름(showNameField일 때) 전달. null 반환 시 성공으로 닫고 [onSuccess] 호출, 문자열 반환 시 해당 문구 표시.
typedef DirectPhoneSubmitCallback =
    Future<String?> Function(
      BuildContext context,
      String normalizedPhone,
      String? name,
    );
typedef DirectPhoneCheckErrorCallback =
    String? Function(String normalizedPhone);

class DirectPhoneInputBottomSheet extends StatefulWidget {
  final String title;
  final String submitButtonText;
  final bool showNameField;
  final DirectPhoneCheckErrorCallback? checkPhoneError;
  final DirectPhoneSubmitCallback onSubmit;
  final VoidCallback? onSuccess;

  const DirectPhoneInputBottomSheet({
    super.key,
    required this.title,
    required this.submitButtonText,
    this.showNameField = false,
    this.checkPhoneError,
    required this.onSubmit,
    this.onSuccess,
  });

  static void show({
    required BuildContext context,
    required String title,
    required String submitButtonText,
    bool showNameField = false,
    DirectPhoneCheckErrorCallback? checkPhoneError,
    required DirectPhoneSubmitCallback onSubmit,
    VoidCallback? onSuccess,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      builder:
          (ctx) => DirectPhoneInputBottomSheet(
            title: title,
            submitButtonText: submitButtonText,
            showNameField: showNameField,
            checkPhoneError: checkPhoneError,
            onSubmit: onSubmit,
            onSuccess: onSuccess,
          ),
    );
  }

  @override
  State<DirectPhoneInputBottomSheet> createState() =>
      _DirectPhoneInputBottomSheetState();
}

class _DirectPhoneInputBottomSheetState
    extends State<DirectPhoneInputBottomSheet> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isSubmitting = false;
  String? _phoneDuplicateError;

  void _onFieldChanged() => setState(() {});

  bool get _canSubmit {
    if (_isSubmitting) return false;
    if (widget.showNameField && _nameController.text.trim().isEmpty)
      return false;
    final norm = FormatUtils.normalizePhoneForCompare(
      _phoneController.text.trim(),
    );
    if (norm.length != 11) return false;
    if (_phoneDuplicateError != null) return false;
    return true;
  }

  /// 코스 매니저 초대 시트와 동일: 상단 닫기 버튼 원형 칩
  Widget _buildCircleChipClose() {
    final color = AppColors.textPrimary;
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          shape: BoxShape.circle,
        ),
        child: Center(child: Icon(Icons.close, size: 20, color: color)),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_onFieldChanged);
    _phoneController.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _nameController.removeListener(_onFieldChanged);
    _phoneController.removeListener(_onFieldChanged);
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _applyPhoneFormat(String value) {
    final digits = value.replaceAll(RegExp(r'[^\d]'), '');
    final formatted = FormatUtils.formatPhoneInput(digits);
    if (_phoneController.text != formatted) {
      _phoneController.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
    }
    if (widget.checkPhoneError != null) {
      final normalized = FormatUtils.normalizePhoneForCompare(formatted);
      final next =
          normalized.length == 11 ? widget.checkPhoneError!(normalized) : null;
      if (_phoneDuplicateError != next) {
        setState(() => _phoneDuplicateError = next);
      }
    }
  }

  Future<void> _submit() async {
    if (_formKey.currentState?.validate() != true) return;
    final raw = _phoneController.text.trim();
    final normalized = FormatUtils.normalizePhoneForCompare(raw);
    if (normalized.length != 11) return;
    final name = widget.showNameField ? _nameController.text.trim() : null;

    setState(() => _isSubmitting = true);
    try {
      final error = await widget.onSubmit(context, normalized, name);
      if (!mounted) return;
      if (error == null) {
        Navigator.of(context).pop();
        widget.onSuccess?.call();
      } else {
        setState(() => _isSubmitting = false);
        SnackbarUtil.showInfo(context, error);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        SnackbarUtil.showInfoFromError(
          context,
          e,
          fallback: '처리 중 오류가 발생했습니다.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: KeyboardBleedFill(
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.backgroundWhite,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: 24 + mq.padding.bottom,
          ),
          child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    _buildCircleChipClose(),
                  ],
                ),
                const SizedBox(height: 20),
                if (widget.showNameField) ...[
                  TextFormField(
                    controller: _nameController,
                    decoration: TextFieldDecorationUtil.defaultDecoration(
                      hintText: '이름',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (v) {
                      if ((v ?? '').trim().isEmpty) return '이름을 입력해주세요';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                TextFormField(
                  controller: _phoneController,
                  decoration: TextFieldDecorationUtil.defaultDecoration(
                    hintText: '전화번호',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    errorText: _phoneDuplicateError,
                  ),
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(13),
                  ],
                  onChanged: _applyPhoneFormat,
                  validator: (v) {
                    final raw = (v ?? '').trim();
                    if (raw.isEmpty) return '전화번호를 입력해주세요';
                    if (FormatUtils.normalizePhoneForCompare(raw).length !=
                        11) {
                      return '올바른 전화번호를 입력해주세요 (010-0000-0000)';
                    }
                    if (_phoneDuplicateError != null)
                      return _phoneDuplicateError;
                    return null;
                  },
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _canSubmit ? _submit : null,
                    style: FilledButton.styleFrom(
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
                        _isSubmitting
                            ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.primaryGreen,
                              ),
                            )
                            : Text(
                              widget.submitButtonText,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}
