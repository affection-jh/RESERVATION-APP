import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../../theme/app_colors.dart';
import '../../../widgets/cached_image_widget.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/storage_service.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/text_field_decoration_util.dart';
import '../../../widgets/common_dialog.dart';
import 'admin_greeting_setting_screen.dart';

class AdminPlaceRegistrationScreen extends StatefulWidget {
  final String? phoneNumber;
  final String? verificationCode;
  final bool isFromRegistration; // 회원가입 플로우인지 여부
  final bool isFromLogin; // 로그인 플로우인지 여부

  const AdminPlaceRegistrationScreen({
    super.key,
    this.phoneNumber,
    this.verificationCode,
    this.isFromRegistration = false,
    this.isFromLogin = false,
  });

  @override
  State<AdminPlaceRegistrationScreen> createState() =>
      _AdminPlaceRegistrationScreenState();
}

class _AdminPlaceRegistrationScreenState
    extends State<AdminPlaceRegistrationScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  final FocusNode _nameFocusNode = FocusNode();
  final FocusNode _locationFocusNode = FocusNode();
  File? _selectedImage;
  String? _uploadedImageUrl; // 업로드된 이미지 URL
  bool _isUploading = false; // 업로드 중 여부
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _nameFocusNode.addListener(() {
      setState(() {});
    });
    _locationFocusNode.addListener(() {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    _nameFocusNode.dispose();
    _locationFocusNode.dispose();
    super.dispose();
  }

  void _removeFocus() {
    _nameFocusNode.unfocus();
    _locationFocusNode.unfocus();
  }

  bool _isFormValid() {
    return (_selectedImage != null || _uploadedImageUrl != null) &&
        _nameController.text.trim().isNotEmpty &&
        _locationController.text.trim().isNotEmpty;
  }

  /// 이미지 업로드
  Future<void> _uploadImage() async {
    if (_selectedImage == null) return;

    setState(() {
      _isUploading = true;
    });

    try {
      final storageService = StorageService();
      final imageUrl = await storageService.uploadImage(
        imageFile: _selectedImage!,
        folder: 'places',
      );

      setState(() {
        _uploadedImageUrl = imageUrl;
        _isUploading = false;
        // 업로드 완료 후 로컬 이미지는 유지 (네트워크 이미지가 로드될 때까지)
      });
    } catch (e) {
      setState(() {
        _isUploading = false;
      });
      if (mounted) {
        SnackbarUtil.showError(context, '이미지 업로드에 실패했습니다: ${e.toString()}');
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
      ),

      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView(
                children: [
                  const SizedBox(height: 12),

                  // 제목
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(height: 20),
                        _buildTitle(),

                        SizedBox(height: 10),

                        // 플레이스 이미지 업로드
                        _buildImageUpload(),

                        const SizedBox(height: 32),

                        // 플레이스 이름 입력
                        _buildNameInput(),

                        const SizedBox(height: 24),

                        // 위치 입력
                        _buildLocationInput(),

                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 하단 버튼
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: _buildBottomButtons(),
            ),
          ],
        ),
      ),
    );
  }

  // 뒤로가기 처리
  Future<void> _handleBackButton() async {
    _removeFocus();

    // 회원가입 또는 로그인 플로우인 경우: 확인 다이얼로그 표시 후 waiting_screen으로 이동
    if (widget.isFromRegistration || widget.isFromLogin) {
      final confirmed = await CommonDialog.show(
        context: context,
        title: '플레이스 등록 취소',
        message: widget.isFromRegistration
            ? '플레이스 등록을 취소하시겠습니까?'
            : '플레이스 등록을 취소하시겠습니까?',
        secondaryMessage: widget.isFromRegistration
            ? '취소하시면 관리자 등록이 완료되지 않습니다.'
            : null,
        cancelText: '계속하기',
        confirmText: '취소하기',
        confirmButtonColor: Colors.red,
      );

      if (confirmed != true) {
        // 취소하지 않으면 그대로 유지
        return;
      }

      // waiting_screen으로 이동
      if (mounted) {
        // adminUsers 조회는 권한/쿼리 제약으로 실패할 수 있으므로(특히 온보딩 중),
        // 여기서는 전달받은 phoneNumber로 바로 이동한다.
        final phoneNumber = widget.phoneNumber ?? '';

        Navigator.of(context).pushNamedAndRemoveUntil(
          '/place-waiting',
          (route) => false,
          arguments: phoneNumber,
        );
      }
      return;
    }

    // 기존 관리자가 플레이스 추가하는 경우: 관리자 홈으로 이동
    // ✅ 모든 이전 화면을 제거하고 AdminScreen으로 이동
    Navigator.of(context).pushNamedAndRemoveUntil('/admin', (route) => false);
  }

  // 제목
  Widget _buildTitle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '플레이스를 등록해 볼까요?',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }

  // 플레이스 이미지 업로드
  Widget _buildImageUpload() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () async {
            final pickedFile = await _imagePicker.pickImage(
              source: ImageSource.gallery,
              maxWidth: 800,
              maxHeight: 800,
              imageQuality: 85,
            );
            if (pickedFile != null) {
              setState(() {
                _selectedImage = File(pickedFile.path);
                _uploadedImageUrl = null; // 새 이미지 선택 시 기존 URL 초기화
              });
              // 이미지 선택 시 자동 업로드
              await _uploadImage();
            }
          },
          child: Container(
            width: 150,
            height: 150,
            decoration: BoxDecoration(
              color: AppColors.backgroundLight,
              borderRadius: BorderRadius.circular(16),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: _buildImageContent(),
            ),
          ),
        ),
      ],
    );
  }

  /// 이미지 콘텐츠 빌드
  Widget _buildImageContent() {
    // 업로드된 이미지 URL이 있으면 네트워크 이미지 표시
    if (_uploadedImageUrl != null) {
      return Stack(
        children: [
          CachedImageWidget(
            imageUrl: _uploadedImageUrl!,
            width: 150,
            height: 150,
            fit: BoxFit.cover,
            borderRadius: BorderRadius.circular(15),
            errorWidget: _selectedImage != null
                ? Image.file(
                    _selectedImage!,
                    width: 150,
                    height: 150,
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _selectedImage = null;
                  _uploadedImageUrl = null;
                });
              },
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 18),
              ),
            ),
          ),
        ],
      );
    }

    // 업로드 중이면 로컬 이미지 + 로딩 표시
    if (_isUploading && _selectedImage != null) {
      return Stack(
        children: [
          Image.file(
            _selectedImage!,
            width: 150,
            height: 150,
            fit: BoxFit.cover,
          ),
          // 로딩 오버레이
          Container(
            width: 150,
            height: 150,
            color: Colors.black.withOpacity(0.5),
            child: const Center(
              child: CircularProgressIndicator(
                color: AppColors.primaryGreen,
                strokeWidth: 2,
              ),
            ),
          ),
        ],
      );
    }

    // 로컬 이미지만 있는 경우
    if (_selectedImage != null) {
      return Stack(
        children: [
          Image.file(
            _selectedImage!,
            width: 150,
            height: 150,
            fit: BoxFit.cover,
          ),
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _selectedImage = null;
                  _uploadedImageUrl = null;
                });
              },
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 18),
              ),
            ),
          ),
        ],
      );
    }

    // 이미지가 없는 경우
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SvgPicture.asset(
          'assets/icons/gallery-icon.svg',
          width: 32,
          height: 32,
          colorFilter: ColorFilter.mode(
            AppColors.textSecondary,
            BlendMode.srcIn,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '이미지 추가',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  // 플레이스 이름 입력
  Widget _buildNameInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '플레이스 이름',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _nameController,
          focusNode: _nameFocusNode,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) {
            _locationFocusNode.requestFocus();
          },
          decoration: TextFieldDecorationUtil.defaultDecoration(
            hintText: '플레이스 이름을 입력하세요',
            floatingLabelBehavior: FloatingLabelBehavior.always,
            hasFocus: _nameFocusNode.hasFocus,
          ),
          style: TextStyle(fontSize: 16, color: AppColors.textPrimary),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  // 위치 및 설명 입력
  Widget _buildLocationInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '플레이스 설명',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _locationController,
          focusNode: _locationFocusNode,
          textInputAction: TextInputAction.done,
          maxLines: null,
          minLines: 3,
          decoration: TextFieldDecorationUtil.defaultDecoration(
            hintText: '플레이스 설명을 입력하세요',
            floatingLabelBehavior: FloatingLabelBehavior.always,
            hasFocus: _locationFocusNode.hasFocus,
          ),
          style: TextStyle(fontSize: 16, color: AppColors.textPrimary),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  // 하단 버튼
  Widget _buildBottomButtons() {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, child) {
        final admin = authProvider.currentAdmin;
        final hasPlace = admin != null && admin.placeIds.isNotEmpty;
        final canProceed = _isFormValid() && !hasPlace;

        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => _handleBackButton(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  side: BorderSide(color: AppColors.borderLight),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  '이전으로',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: canProceed
                    ? () {
                        _removeFocus();
                        if (hasPlace) {
                          SnackbarUtil.showError(
                            context,
                            '베타 버전에서는 전화번호 하나당 플레이스 하나만 등록할 수 있습니다.',
                          );
                          return;
                        }
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => AdminGreetingSettingScreen(
                              placeName: _nameController.text.trim(),
                              placeLocation: _locationController.text.trim(),
                              placeImage: _uploadedImageUrl == null
                                  ? _selectedImage
                                  : null, // 업로드 완료된 경우 null
                              placeImageUrl: _uploadedImageUrl, // 업로드된 URL 전달
                            ),
                          ),
                        );
                      }
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primaryGreen,
                  disabledBackgroundColor: AppColors.borderLight,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  '계속하기',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryGreen,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
