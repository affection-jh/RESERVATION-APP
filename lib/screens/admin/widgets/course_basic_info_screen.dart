import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import '../../../theme/app_colors.dart';
import '../../../models/course.dart' as reservation_models;
import '../../../utils/text_field_decoration_util.dart';
import '../../../services/storage_service.dart';
import '../../../utils/snackbar_util.dart';
import '../../../widgets/cached_image_widget.dart';
import '../../../widgets/common_dialog.dart';
import '../../../providers/course_provider.dart';

/// 코스 기본 정보 입력 화면 (1단계)
class CourseBasicInfoScreen extends StatefulWidget {
  final reservation_models.Course? existingCourse;
  final CourseBasicInfoData? savedBasicInfo;
  final Function(CourseBasicInfoData) onNext;

  const CourseBasicInfoScreen({
    super.key,
    this.existingCourse,
    this.savedBasicInfo,
    required this.onNext,
  });

  @override
  State<CourseBasicInfoScreen> createState() => _CourseBasicInfoScreenState();
}

class CourseBasicInfoData {
  final String name;
  final String description;
  final String? imageUrl;

  CourseBasicInfoData({
    required this.name,
    required this.description,
    this.imageUrl,
  });
}

class _CourseBasicInfoScreenState extends State<CourseBasicInfoScreen> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _nameFocusNode = FocusNode();
  final _descriptionFocusNode = FocusNode();
  File? _selectedImage;
  String? _uploadedImageUrl; // 업로드된 이미지 URL
  String? _existingImageUrl; // 기존 코스의 원본 이미지 URL (Storage 삭제용)
  bool _isUploading = false; // 업로드 중 여부
  Future<String?>? _uploadFuture; // 업로드 중 뒤로갈 때 완료 후 삭제용
  final ImagePicker _imagePicker = ImagePicker();
  String? _nameErrorText; // 코스명 에러 메시지

  @override
  void initState() {
    super.initState();
    // 저장된 데이터가 있으면 우선 사용 (뒤로 갔다 온 경우)
    if (widget.savedBasicInfo != null) {
      _nameController.text = widget.savedBasicInfo!.name;
      _descriptionController.text = widget.savedBasicInfo!.description;
      _uploadedImageUrl = widget.savedBasicInfo!.imageUrl;
      _existingImageUrl = widget.savedBasicInfo!.imageUrl;
    } else if (widget.existingCourse != null) {
      // 기존 코스 편집인 경우
      _nameController.text = widget.existingCourse!.name;
      _descriptionController.text = widget.existingCourse!.description;
      // 기존 코스의 이미지 URL이 있다면 로드
      _uploadedImageUrl = widget.existingCourse!.imageUrl;
      _existingImageUrl = widget.existingCourse!.imageUrl; // 원본 URL 저장 (삭제용)
    }
    // 코스명 입력 시 버튼 상태 업데이트 및 중복 체크
    _nameController.addListener(() {
      _checkCourseNameDuplicate();
      setState(() {});
    });
    // 포커스 상태 변경 시 UI 업데이트 및 다른 필드 포커스 해제
    _nameFocusNode.addListener(() {
      if (_nameFocusNode.hasFocus) {
        _descriptionFocusNode.unfocus();
      }
      setState(() {});
    });
    _descriptionFocusNode.addListener(() {
      if (_descriptionFocusNode.hasFocus) {
        _nameFocusNode.unfocus();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _nameFocusNode.dispose();
    _descriptionFocusNode.dispose();
    super.dispose();
  }

  /// 코스명 중복 체크
  void _checkCourseNameDuplicate() {
    final courseName = _nameController.text.trim();
    if (courseName.isEmpty) {
      setState(() {
        _nameErrorText = null;
      });
      return;
    }

    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final courses = courseProvider.courses;

    // 기존 코스 편집 시 자기 자신은 제외
    final existingCourseId = widget.existingCourse?.id;
    final hasDuplicate = courses.any(
      (course) =>
          course.name.trim().toLowerCase() == courseName.toLowerCase() &&
          (existingCourseId == null || course.id != existingCourseId),
    );

    if (hasDuplicate) {
      setState(() {
        _nameErrorText = '이미 존재하는 코스명입니다.';
      });
    } else {
      setState(() {
        _nameErrorText = null;
      });
    }
  }

  bool _isFormValid() {
    return _nameController.text.trim().isNotEmpty && _nameErrorText == null;
  }

  /// 초기 상태 대비 변경 여부 (플레이스 등록과 동일: 확인 다이얼로그·이미지 삭제용)
  bool _hasChanges() {
    final initialName =
        widget.savedBasicInfo?.name ?? widget.existingCourse?.name ?? '';
    final initialDescription =
        widget.savedBasicInfo?.description ??
        widget.existingCourse?.description ??
        '';
    final initialImageUrl =
        widget.savedBasicInfo?.imageUrl ?? widget.existingCourse?.imageUrl;

    return _nameController.text.trim() != initialName ||
        _descriptionController.text.trim() != initialDescription ||
        _uploadedImageUrl != initialImageUrl ||
        _selectedImage != null;
  }

  /// 나갈 때 확인 다이얼로그를 띄워야 하는지
  /// (폼 변경 있음, 또는 다음 단계 갔다가 돌아온 경우 = 진행 분이 있음)
  bool _shouldConfirmLeave() {
    return _hasChanges() || widget.savedBasicInfo != null;
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

    // 교체 시: 아직 저장 안 된 새 업로드만 삭제 (기존 코스 이미지는 저장 시 처리)
    final oldUrl = _uploadedImageUrl;
    setState(() {
      _selectedImage = File(pickedFile.path);
      _uploadedImageUrl = null;
    });
    if (oldUrl != null && oldUrl != _existingImageUrl) {
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
        folder: 'courses',
      );

      // 기존 이미지가 있고 새 이미지와 다르면 Storage에서 삭제
      if (_uploadedImageUrl != null &&
          _uploadedImageUrl != imageUrl &&
          _uploadedImageUrl == _existingImageUrl) {
        try {
          await storageService.deleteImage(_uploadedImageUrl!);
        } catch (e) {
          // 삭제 실패는 무시
        }
      }

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

  /// 이미지 삭제 (Storage에서도 삭제)
  Future<void> _deleteImage() async {
    // Storage에서 삭제할 URL 결정
    String? urlToDelete;
    if (_uploadedImageUrl != null) {
      urlToDelete = _uploadedImageUrl;
    } else if (_existingImageUrl != null) {
      urlToDelete = _existingImageUrl;
    }

    // Storage에서 삭제
    if (urlToDelete != null) {
      try {
        final storageService = StorageService();
        await storageService.deleteImage(urlToDelete);
      } catch (e) {
        // 삭제 실패는 무시하되 로그는 남김
        debugPrint('이미지 삭제 실패: $e');
      }
    }

    // 로컬 상태 초기화
    setState(() {
      _selectedImage = null;
      _uploadedImageUrl = null;
      _existingImageUrl = null;
    });
  }

  /// 뒤로가기 처리 (변경사항 있으면 확인 다이얼로그, 확인 시 업로드 이미지 백그라운드 삭제 후 이동)
  Future<void> _handleBack() async {
    if (_nameFocusNode.hasFocus) _nameFocusNode.unfocus();
    if (_descriptionFocusNode.hasFocus) _descriptionFocusNode.unfocus();

    if (_shouldConfirmLeave()) {
      final confirmed = await CommonDialog.show(
        context: context,
        title: '변경사항이 있습니다',
        message: '입력한 내용이 사라집니다.\n나가시겠습니까?',
        cancelText: '계속하기',
        confirmText: '나가기',
        confirmButtonColor: Colors.red,
      );
      if (confirmed != true) return;

      // 새로 업로드한 이미지만 삭제 (기존 코스 이미지 URL은 유지)
      if (_uploadedImageUrl != null && _uploadedImageUrl != _existingImageUrl) {
        StorageService.deleteImagesInBackground([_uploadedImageUrl!]);
      } else if (_isUploading && _uploadFuture != null) {
        _uploadFuture!.then((url) {
          if (url != null && url.isNotEmpty) {
            StorageService.deleteImagesInBackground([url]);
          }
        });
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_shouldConfirmLeave(),
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        FocusScope.of(context).unfocus();
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: AppColors.backgroundWhite,
        body: SafeArea(
          child: Column(
            children: [
              // 메인 콘텐츠
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.manual,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 헤더
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 16,
                                ),
                                child: Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                        Icons.arrow_back_ios,
                                        size: 24,
                                        color: AppColors.primaryGreen,
                                      ),
                                      onPressed: _handleBack,
                                      color: AppColors.textPrimary,
                                    ),
                                    const Spacer(),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 20),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '코스를 등록해 볼까요?',
                                      style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                    Text(
                                      '코스 정보를 입력해주세요.',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),

                                    const SizedBox(height: 40),
                                    // 코스 이미지 업로드
                                    _buildImageUpload(),
                                    const SizedBox(height: 34),
                                    // 코스명
                                    Text(
                                      '코스명',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    _buildModernTextField(
                                      controller: _nameController,
                                      focusNode: _nameFocusNode,
                                      hintText: '코스명을 입력해주세요',
                                      errorText: _nameErrorText,
                                    ),
                                    const SizedBox(height: 14),
                                    // 설명
                                    Text(
                                      '설명',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    _buildModernTextField(
                                      controller: _descriptionController,
                                      focusNode: _descriptionFocusNode,
                                      hintText: '코스에 대한 설명을 입력해주세요',
                                      minLines: 2,
                                      maxLines: 2,
                                      inputFormatters: [
                                        _MaxLinesInputFormatter(2),
                                        LengthLimitingTextInputFormatter(
                                          60,
                                        ), // 자동 줄바꿈 포함 2줄 이내
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 60),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // 하단 버튼
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed:
                        (_isFormValid() && !_isUploading)
                            ? () {
                              widget.onNext(
                                CourseBasicInfoData(
                                  name: _nameController.text.trim(),
                                  description:
                                      _descriptionController.text.trim(),
                                  imageUrl: _uploadedImageUrl,
                                ),
                              );
                            }
                            : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          (_isFormValid() && !_isUploading)
                              ? AppColors.primaryGreen
                              : AppColors.borderLight,
                      disabledBackgroundColor: AppColors.borderLight,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      '다음',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color:
                            (_isFormValid() && !_isUploading)
                                ? Colors.white
                                : AppColors.textSecondary,
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

  Widget _buildModernTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    String? hintText,
    String? errorText,
    int? minLines,
    int? maxLines,
    List<TextInputFormatter>? inputFormatters,
  }) {
    final hasError = errorText != null && errorText.isNotEmpty;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      maxLines: maxLines ?? null,
      minLines: minLines ?? 1,
      decoration: TextFieldDecorationUtil.defaultDecoration(
        hintText: hintText,
        errorText: errorText,
        hasError: hasError,
        hasFocus: focusNode.hasFocus,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
      ),
      style: TextStyle(
        fontSize: 16,
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      inputFormatters: inputFormatters,
      onChanged: (_) => setState(() {}),
    );
  }

  // 코스 이미지 업로드
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
            child: _buildImageContent(),
          ),
        ),
      ],
    );
  }

  /// 이미지 콘텐츠 빌드
  Widget _buildImageContent() {
    final borderRadius = BorderRadius.circular(15);

    // 업로드된 이미지 URL이 있으면 네트워크 이미지 표시
    // 로컬 이미지가 있으면 placeholder로 사용하여 빈 화면 방지
    if (_uploadedImageUrl != null) {
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _pickOrReplaceImage,
              child: CourseImageWidget(
                imageUrl: _uploadedImageUrl,
                width: 150,
                height: 150,
                borderRadius: borderRadius,
                localImageFile: _selectedImage,
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () => _deleteImage(),
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
          ClipRRect(
            borderRadius: borderRadius,
            child: Image.file(
              _selectedImage!,
              width: 150,
              height: 150,
              fit: BoxFit.cover,
            ),
          ),
          // 로딩 오버레이
          ClipRRect(
            borderRadius: borderRadius,
            child: Container(
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
          ),
        ],
      );
    }

    // 로컬 이미지만 있는 경우
    if (_selectedImage != null) {
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _pickOrReplaceImage,
              child: ClipRRect(
                borderRadius: borderRadius,
                child: Image.file(
                  _selectedImage!,
                  width: 150,
                  height: 150,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () => _deleteImage(),
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
}

/// 최대 줄 수를 제한하는 TextInputFormatter (줄바꿈 입력 방지)
class _MaxLinesInputFormatter extends TextInputFormatter {
  final int maxLines;

  _MaxLinesInputFormatter(this.maxLines);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final newlineCount = '\n'.allMatches(newValue.text).length;
    if (newlineCount >= maxLines) {
      return oldValue;
    }
    return newValue;
  }
}
