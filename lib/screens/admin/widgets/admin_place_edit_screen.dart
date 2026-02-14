import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:reservation/utils/text_field_decoration_util.dart';
import '../../../theme/app_colors.dart';
import '../../../models/place.dart';
import '../../../utils/snackbar_util.dart';
import '../../../widgets/cached_image_widget.dart' show PlaceImageWidget;
import '../../../widgets/story_card.dart';
import '../../../services/storage_service.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/admin_provider.dart';
import '../../../services/user_service.dart';
import 'place_delete_confirm_screen.dart';

class AdminPlaceEditScreen extends StatefulWidget {
  final Place? place; // null이면 새로 등록, 있으면 수정

  const AdminPlaceEditScreen({super.key, this.place});

  @override
  State<AdminPlaceEditScreen> createState() => _AdminPlaceEditScreenState();
}

class _AdminPlaceEditScreenState extends State<AdminPlaceEditScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _appBarTextController = TextEditingController();
  final TextEditingController _greetingTextController = TextEditingController();

  final FocusNode _nameFocusNode = FocusNode();
  final FocusNode _locationFocusNode = FocusNode();
  final FocusNode _descriptionFocusNode = FocusNode();
  final FocusNode _appBarFocusNode = FocusNode();
  final FocusNode _greetingFocusNode = FocusNode();

  // 이미지 관련
  final ImagePicker _imagePicker = ImagePicker();
  File? _selectedImage;
  String? _uploadedImageUrl;
  String? _existingImageUrl;
  bool _isUploadingImage = false;

  // 저장 관련
  bool _isSaving = false;

  // 초기값 저장 (변경사항 추적용)
  String _initialName = '';
  String _initialLocation = '';
  String _initialDescription = '';
  String _initialAppBarText = '';
  String _initialGreetingText = '';

  @override
  void initState() {
    super.initState();
    // 기존 플레이스 정보가 있으면 초기값 설정
    if (widget.place != null) {
      _initialName = widget.place!.name;
      _initialLocation = widget.place!.location ?? '';
      _initialDescription = widget.place!.description ?? '';
      _existingImageUrl = widget.place!.imageUrl;
      _initialAppBarText = widget.place!.appBarText ?? '';
      _initialGreetingText = widget.place!.greetingText ?? '';

      // 모든 컨트롤러에 현재 값 설정
      _nameController.text = _initialName;
      _locationController.text = _initialLocation;
      _descriptionController.text = _initialDescription;
      _appBarTextController.text = _initialAppBarText;
      _greetingTextController.text = _initialGreetingText;
    } else {
      // 새로 등록하는 경우 기본값 설정
      _initialAppBarText = '';
      _initialGreetingText = '';
      _initialLocation = '';

      // 모든 컨트롤러에 기본값 설정
      _nameController.text = '';
      _locationController.text = _initialLocation;
      _descriptionController.text = '';
      _appBarTextController.text = _initialAppBarText;
      _greetingTextController.text = _initialGreetingText;
    }

    // 모든 컨트롤러에 리스너 추가하여 변경사항 추적
    _nameController.addListener(() => setState(() {}));
    _locationController.addListener(() => setState(() {}));
    _descriptionController.addListener(() => setState(() {}));
    _appBarTextController.addListener(() => setState(() {}));
    _greetingTextController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    _appBarTextController.dispose();
    _greetingTextController.dispose();
    _nameFocusNode.dispose();
    _locationFocusNode.dispose();
    _descriptionFocusNode.dispose();
    _appBarFocusNode.dispose();
    _greetingFocusNode.dispose();
    super.dispose();
  }

  void _removeFocus() {
    _nameFocusNode.unfocus();
    _locationFocusNode.unfocus();
    _descriptionFocusNode.unfocus();
    _appBarFocusNode.unfocus();
    _greetingFocusNode.unfocus();
  }

  bool _isFormValid() {
    return _nameController.text.trim().isNotEmpty &&
        _locationController.text.trim().isNotEmpty &&
        _appBarTextController.text.trim().isNotEmpty &&
        _greetingTextController.text.trim().isNotEmpty;
  }

  // 변경사항이 있는지 확인
  bool _hasChanges() {
    if (widget.place == null) {
      // 새로 등록하는 경우 항상 활성화
      return _isFormValid();
    }
    // 수정하는 경우 변경사항이 있을 때만 활성화
    return _nameController.text.trim() != _initialName ||
        _locationController.text.trim() != _initialLocation ||
        _descriptionController.text.trim() != _initialDescription ||
        _appBarTextController.text.trim() != _initialAppBarText ||
        _greetingTextController.text.trim() != _initialGreetingText ||
        _uploadedImageUrl != null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      body: SafeArea(
        child: Column(
          children: [
            // 헤더
            _buildHeader(),

            // 메인 콘텐츠
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 32),

                    // 플레이스 기본 정보 섹션
                    _buildBasicInfoSection(),

                    const SizedBox(height: 32),

                    // 인사말 설정 섹션
                    _buildGreetingSection(),

                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),

            // 하단 버튼
            _buildBottomButtons(),
          ],
        ),
      ),
    );
  }

  // 헤더
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              _removeFocus();
              Navigator.of(context).pop();
            },
            icon: Icon(
              Icons.arrow_back_ios,
              size: 24,
              color: AppColors.primaryGreen,
            ),
          ),
          Text(
            '플레이스 정보',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const Spacer(),
          // 삭제 버튼 (수정 모드일 때만 표시)
          if (widget.place != null)
            IconButton(
              onPressed: () {
                _showDeleteDialog(context);
              },
              icon: SvgPicture.asset(
                'assets/icons/delete.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  AppColors.textSecondary.withOpacity(0.75),
                  BlendMode.srcIn,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // 삭제 확인 다이얼로그
  void _showDeleteDialog(BuildContext context) async {
    if (widget.place == null) return;

    // 2중 안전장치를 위한 삭제 확인 화면으로 이동
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PlaceDeleteConfirmScreen(place: widget.place!),
      ),
    );
  }

  // 이미지 선택
  Future<void> _pickImage() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _selectedImage = File(image.path);
          _isUploadingImage = true;
        });

        // 이미지 업로드
        await _uploadImage();
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '이미지를 선택할 수 없습니다');
      }
    }
  }

  // 이미지 업로드
  Future<void> _uploadImage() async {
    if (_selectedImage == null) return;

    try {
      final storageService = StorageService();

      // 기존 이미지가 있으면 삭제
      if (_existingImageUrl != null && _existingImageUrl!.isNotEmpty) {
        try {
          await storageService.deleteImage(_existingImageUrl!);
        } catch (e) {
          debugPrint('기존 이미지 삭제 실패: $e');
        }
      }

      // 새 이미지 업로드
      final imageUrl = await storageService.uploadImage(
        imageFile: _selectedImage!,
        folder: 'places',
      );

      if (mounted) {
        setState(() {
          _uploadedImageUrl = imageUrl;
          _existingImageUrl = imageUrl;
          _selectedImage = null;
          _isUploadingImage = false;
        });
        SnackbarUtil.showSuccess(context, '이미지가 업로드되었습니다');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUploadingImage = false;
        });
        SnackbarUtil.showError(context, '이미지 업로드에 실패했습니다');
      }
    }
  }

  // 기본 정보 섹션
  Widget _buildBasicInfoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 플레이스 이름 입력
        _buildNameInput(),
        const SizedBox(height: 20),

        // 설명 입력
        _buildDescriptionInput(),
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
            fontWeight: FontWeight.w500,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          style: TextStyle(
            fontSize: 16,
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
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
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  // 설명 입력
  Widget _buildDescriptionInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '설명',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.textPrimary,
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
          textInputAction: TextInputAction.next,
          onSubmitted: (_) {
            _appBarFocusNode.requestFocus();
          },
          decoration: TextFieldDecorationUtil.defaultDecoration(
            hintText: '플레이스에 대한 설명을 입력하세요',
            floatingLabelBehavior: FloatingLabelBehavior.always,
            hasFocus: _descriptionFocusNode.hasFocus,
          ),
          maxLines: 3,
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  // 인사말 설정 섹션
  Widget _buildGreetingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '홈 화면에 표시될 텍스트를 수정할 수 있습니다',
          style: TextStyle(
            fontSize: 14,
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 16),
        // 미리보기 섹션
        _buildPreviewSection(),
      ],
    );
  }

  // 미리보기 섹션
  Widget _buildPreviewSection() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, Colors.white.withOpacity(0.0)],
          stops: const [0.0, 0.2, 0.8],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: _buildHomePreview(),
      ),
    );
  }

  // 홈 화면 미리보기
  Widget _buildHomePreview() {
    return ShaderMask(
      shaderCallback: (Rect bounds) {
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, Colors.white.withOpacity(0.0)],
          stops: const [0.0, 0.4, 0.8],
        ).createShader(bounds);
      },
      blendMode: BlendMode.dstIn,
      child: Container(
        color: AppColors.backgroundLight,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 헤더
            _buildPreviewHeader(),
            // 제목 섹션
            _buildPreviewTitleSection(),
            const SizedBox(height: 20),
            // 탭
            _buildPreviewTabs(),
            const SizedBox(height: 10),
            // 프로모션 카드
            _buildPreviewPromotionCard(),
          ],
        ),
      ),
    );
  }

  // 미리보기 헤더 (이미지와 플레이스 설명)
  Widget _buildPreviewHeader() {
    final currentImageUrl = _uploadedImageUrl ?? _existingImageUrl;
    final placeName =
        _nameController.text.trim().isEmpty
            ? (widget.place?.name ?? '플레이스 이름')
            : _nameController.text.trim();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      color: AppColors.backgroundLight,
      child: Row(
        children: [
          // 플레이스 이미지
          GestureDetector(
            onTap: _isUploadingImage ? null : _pickImage,
            child: Stack(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: AppColors.backgroundLight,
                  ),
                  child:
                      _selectedImage != null
                          ? ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Image.file(
                              _selectedImage!,
                              fit: BoxFit.cover,
                            ),
                          )
                          : (currentImageUrl != null &&
                              currentImageUrl.isNotEmpty)
                          ? PlaceImageWidget(
                            imageUrl: currentImageUrl,
                            width: 46,
                            height: 46,
                            borderRadius: BorderRadius.circular(16),
                          )
                          : Icon(
                            Icons.add_photo_alternate_outlined,
                            size: 24,
                            color: AppColors.textSecondary,
                          ),
                ),
                if (_isUploadingImage)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: Colors.black.withOpacity(0.5),
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.primaryGreen,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 플레이스 이름
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  placeName,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Stack(
            children: [
              IconButton(
                icon: SvgPicture.asset(
                  'assets/icons/notifiction-icon.svg',
                  width: 20,
                  height: 20,
                  colorFilter: ColorFilter.mode(
                    AppColors.textPrimary,
                    BlendMode.srcIn,
                  ),
                ),
                onPressed: () {},
              ),
              Positioned(
                top: 12,
                right: 10,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 미리보기 제목 섹션 (인라인 편집)
  Widget _buildPreviewTitleSection() {
    final placeName =
        _nameController.text.trim().isEmpty
            ? (widget.place?.name ?? '플레이스 이름')
            : _nameController.text.trim();
    final currentGreeting = widget.place?.greetingText ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextField(
          controller: _greetingTextController,
          focusNode: _greetingFocusNode,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          maxLines: null,
          minLines: 2,
          textAlign: TextAlign.left,
          textAlignVertical: TextAlignVertical.top,
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
            height: 1.4,
          ),
          decoration: InputDecoration(
            hintText:
                currentGreeting.isNotEmpty
                    ? currentGreeting
                    : '안녕하세요,\n$placeName입니다',
            hintStyle: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: AppColors.textLight,
              height: 1.4,
            ),
            border: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.zero,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
    );
  }

  // 미리보기 탭
  Widget _buildPreviewTabs() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Column(
            children: [
              Text(
                '스토리',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: AppColors.primaryGreen,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
          const SizedBox(width: 24),
          Text(
            '추천',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.normal,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  // 미리보기 프로모션 카드
  Widget _buildPreviewPromotionCard() {
    return SizedBox(
      height: 200,
      child: PageView(
        children: [StoryCard(title: '', content: '', date: '', imageUrls: [])],
      ),
    );
  }

  // 하단 버튼
  Widget _buildBottomButtons() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: (_hasChanges() && !_isSaving) ? _handleSave : null,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primaryGreen,
            disabledBackgroundColor: AppColors.borderLight,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child:
              _isSaving
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
                    widget.place != null ? '수정 완료' : '등록 완료',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
        ),
      ),
    );
  }

  // 저장 처리
  Future<void> _handleSave() async {
    if (_isSaving) return;

    _removeFocus();

    setState(() {
      _isSaving = true;
    });

    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final adminProvider = Provider.of<AdminProvider>(context, listen: false);
    final userService = UserService();

    final currentAdmin =
        authProvider.currentAdmin ?? adminProvider.currentAdmin;
    if (currentAdmin == null) {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
        SnackbarUtil.showError(context, '관리자 정보를 찾을 수 없습니다.');
      }
      return;
    }

    try {
      if (widget.place == null) {
        // 새로 등록
        final newPlace = await placeProvider.createPlace(
          name: _nameController.text.trim(),
          description:
              _descriptionController.text.trim().isEmpty
                  ? null
                  : _descriptionController.text.trim(),
          appBarText:
              _appBarTextController.text.trim().isEmpty
                  ? null
                  : _appBarTextController.text.trim(),
          greetingText:
              _greetingTextController.text.trim().isEmpty
                  ? null
                  : _greetingTextController.text.trim(),
          imageUrl: _uploadedImageUrl,
          adminId: currentAdmin.userId,
        );

        // Admin의 placeIds에 추가
        final updatedAdmin = currentAdmin.addPlace(newPlace.id);
        await userService.updateAdmin(updatedAdmin);

        // Provider 업데이트
        if (authProvider.currentAdmin?.userId == updatedAdmin.userId) {
          authProvider.setCurrentAdmin(updatedAdmin);
        }
        if (adminProvider.currentAdmin?.userId == updatedAdmin.userId) {
          adminProvider.setCurrentAdmin(updatedAdmin);
        }

        if (mounted) {
          Navigator.of(context).pop(newPlace);
          SnackbarUtil.showSuccess(context, '플레이스가 등록되었습니다.');
        }
      } else {
        // 수정
        final updatedPlace = widget.place!.copyWith(
          name: _nameController.text.trim(),
          location: _locationController.text.trim(),
          description:
              _descriptionController.text.trim().isEmpty
                  ? null
                  : _descriptionController.text.trim(),
          appBarText:
              _appBarTextController.text.trim().isEmpty
                  ? null
                  : _appBarTextController.text.trim(),
          greetingText:
              _greetingTextController.text.trim().isEmpty
                  ? null
                  : _greetingTextController.text.trim(),
          imageUrl: _uploadedImageUrl ?? widget.place!.imageUrl,
        );

        await placeProvider.updatePlace(updatedPlace);

        if (mounted) {
          Navigator.of(context).pop(updatedPlace);
          SnackbarUtil.showSuccess(context, '플레이스 정보가 수정되었습니다.');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
        SnackbarUtil.showError(context, '저장 중 오류가 발생했습니다: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }
}
