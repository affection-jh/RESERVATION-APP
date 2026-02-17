import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../../theme/app_colors.dart';
import '../../../widgets/cached_image_widget.dart';
import '../../../services/storage_service.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/text_field_decoration_util.dart';
import '../../../widgets/common_dialog.dart';
import 'greeting_massage_setting_screen.dart';

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
  final TextEditingController _descriptionController = TextEditingController();
  final FocusNode _nameFocusNode = FocusNode();
  final FocusNode _descriptionFocusNode = FocusNode();
  File? _selectedImage;
  String? _uploadedImageUrl; // 업로드된 이미지 URL
  bool _isUploading = false; // 업로드 중 여부
  Future<String?>? _uploadFuture; // 업로드 중 뒤로갈 때 완료 후 삭제용
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _nameFocusNode.addListener(_onFocusChange);
    _descriptionFocusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _nameFocusNode.removeListener(_onFocusChange);
    _descriptionFocusNode.removeListener(_onFocusChange);
    _nameController.dispose();
    _descriptionController.dispose();
    _nameFocusNode.dispose();
    _descriptionFocusNode.dispose();
    super.dispose();
  }

  void _removeFocus() {
    _nameFocusNode.unfocus();
    _descriptionFocusNode.unfocus();
  }

  bool _hasChanges() {
    return _nameController.text.trim().isNotEmpty ||
        _descriptionController.text.trim().isNotEmpty ||
        _uploadedImageUrl != null ||
        _selectedImage != null;
  }

  bool _isFormValid() {
    // 이미지가 선택되어 있거나 업로드 완료되어 있어야 함 (선택 사항으로 변경 가능)
    final hasImage = _selectedImage != null || _uploadedImageUrl != null;
    // 이름과 설명이 입력되어 있어야 함
    final hasName = _nameController.text.trim().isNotEmpty;
    final hasDescription = _descriptionController.text.trim().isNotEmpty;

    // 이미지는 선택 사항으로 변경 (이름과 설명만 필수)
    final isValid = hasName && hasDescription;

    // 디버깅용 로그
    debugPrint(
      '[AdminPlaceRegistration] _isFormValid: hasImage=$hasImage, hasName=$hasName, hasDescription=$hasDescription, isValid=$isValid',
    );
    debugPrint(
      '[AdminPlaceRegistration] _selectedImage: ${_selectedImage != null}, _uploadedImageUrl: ${_uploadedImageUrl != null}',
    );

    return isValid;
  }

  /// 갤러리에서 이미지 선택 또는 교체 (기존 업로드 이미지 삭제 포함)
  Future<void> _pickOrReplaceImage() async {
    final pickedFile = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 85,
    );
    if (pickedFile == null) return;

    final oldUrl = _uploadedImageUrl;
    setState(() {
      _selectedImage = File(pickedFile.path);
      _uploadedImageUrl = null;
    });
    if (oldUrl != null) {
      StorageService.deleteImagesInBackground([oldUrl]);
    }
    _uploadFuture = _uploadImage();
    await _uploadFuture;
  }

  /// 이미지 업로드. 성공 시 URL 반환, 실패 시 null.
  Future<String?> _uploadImage() async {
    if (_selectedImage == null) return null;

    setState(() {
      _isUploading = true;
    });

    try {
      final storageService = StorageService();
      final imageUrl = await storageService.uploadImage(
        imageFile: _selectedImage!,
        folder: 'places',
      );

      if (!mounted) return imageUrl;
      setState(() {
        _uploadedImageUrl = imageUrl;
        _isUploading = false;
      });
      return imageUrl;
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
        SnackbarUtil.showInfo(context, '이미지 업로드에 실패했습니다: ${e.toString()}');
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasChanges(),
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        _handleBackButton();
      },
      child: Scaffold(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 4,
                ),
                child: _buildBottomButtons(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 뒤로가기 처리 (변경사항 있으면 확인 다이얼로그, 확인 시 업로드 이미지 백그라운드 삭제 후 이동)
  Future<void> _handleBackButton() async {
    _removeFocus();

    if (_hasChanges()) {
      final confirmed = await CommonDialog.show(
        context: context,
        title:
            widget.isFromRegistration || widget.isFromLogin
                ? '플레이스 등록 취소'
                : '변경사항이 있습니다',
        message:
            widget.isFromRegistration || widget.isFromLogin
                ? '플레이스 등록을 취소하시겠습니까?'
                : '입력한 내용이 사라집니다.\n나가시겠습니까?',
        secondaryMessage:
            widget.isFromRegistration ? '취소하시면 관리자 등록이 완료되지 않습니다.' : null,
        cancelText: '계속하기',
        confirmText: '나가기',
        confirmButtonColor: Colors.red,
      );

      if (confirmed != true) return;

      // 이미 업로드 완료된 URL이 있으면 즉시 삭제
      if (_uploadedImageUrl != null) {
        StorageService.deleteImagesInBackground([_uploadedImageUrl!]);
      } else if (_isUploading && _uploadFuture != null) {
        // 업로드 중이면 완료 후 삭제 (뒤로가기 시 고아 이미지 방지)
        _uploadFuture!.then((url) {
          if (url != null && url.isNotEmpty) {
            StorageService.deleteImagesInBackground([url]);
          }
        });
      }
    }

    if (!mounted) return;

    if (widget.isFromRegistration || widget.isFromLogin) {
      final phoneNumber = widget.phoneNumber ?? '';
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/place-waiting',
        (route) => false,
        arguments: phoneNumber,
      );
      return;
    }

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
            fontSize: 24,
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
          onTap: _pickOrReplaceImage,
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
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _pickOrReplaceImage,
              child: CachedImageWidget(
                imageUrl: _uploadedImageUrl!,
                width: 150,
                height: 150,
                fit: BoxFit.cover,
                borderRadius: BorderRadius.circular(15),
                errorWidget:
                    _selectedImage != null
                        ? Image.file(
                          _selectedImage!,
                          width: 150,
                          height: 150,
                          fit: BoxFit.cover,
                        )
                        : null,
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () {
                final url = _uploadedImageUrl;
                setState(() {
                  _selectedImage = null;
                  _uploadedImageUrl = null;
                });
                if (url != null) {
                  StorageService.deleteImagesInBackground([url]);
                }
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
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
          ),
        ],
      );
    }

    // 로컬 이미지만 있는 경우 (업로드 실패 또는 업로드 전)
    if (_selectedImage != null) {
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _pickOrReplaceImage,
              child: Image.file(
                _selectedImage!,
                width: 150,
                height: 150,
                fit: BoxFit.cover,
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () {
                final url = _uploadedImageUrl;
                setState(() {
                  _selectedImage = null;
                  _uploadedImageUrl = null;
                });
                if (url != null) {
                  StorageService.deleteImagesInBackground([url]);
                }
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
            _descriptionFocusNode.requestFocus();
          },
          decoration: TextFieldDecorationUtil.defaultDecoration(
            hintText: '플레이스 이름을 입력하세요',
            floatingLabelBehavior: FloatingLabelBehavior.always,
            hasFocus: _nameFocusNode.hasFocus,
          ),
          style: TextStyle(
            fontSize: 16,
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  // 설명 입력
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
          style: TextStyle(
            fontSize: 16,
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
          controller: _descriptionController,
          focusNode: _descriptionFocusNode,
          textInputAction: TextInputAction.done,
          maxLines: null,
          minLines: 3,
          decoration: TextFieldDecorationUtil.defaultDecoration(
            hintText: '플레이스 설명을 입력하세요',
            floatingLabelBehavior: FloatingLabelBehavior.always,
            hasFocus: _descriptionFocusNode.hasFocus,
          ),

          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  // 하단 버튼
  Widget _buildBottomButtons() {
    // 플레이스 추가 플로우에서는 hasPlace 체크 무시 (기존 관리자가 추가 플레이스를 등록하는 경우 허용)
    final isValid = _isFormValid();
    // 이미지 등록 중에는 다음 버튼 비활성화
    final canProceed = isValid && !_isUploading;

    debugPrint(
      '[AdminPlaceRegistration] 버튼 상태: isValid=$isValid, canProceed=$canProceed',
    );

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
            onPressed:
                canProceed
                    ? () {
                      _removeFocus();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder:
                              (context) => AdminGreetingSettingScreen(
                                placeName: _nameController.text.trim(),
                                placeDescription:
                                    _descriptionController.text.trim(),
                                placeImage:
                                    _uploadedImageUrl == null
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
              disabledForegroundColor: AppColors.textSecondary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              '계속하기',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}
