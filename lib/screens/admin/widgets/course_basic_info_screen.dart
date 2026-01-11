import 'package:flutter/material.dart';
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
        folder: 'courses',
      );

      // 기존 이미지가 있고 새 이미지와 다르면 Storage에서 삭제
      if (_uploadedImageUrl != null &&
          _uploadedImageUrl != imageUrl &&
          _uploadedImageUrl == _existingImageUrl) {
        try {
          await storageService.deleteImage(_uploadedImageUrl!);
        } catch (e) {
          // 삭제 실패는 무시 (이미 새 이미지로 교체됨)
        }
      }

      setState(() {
        _uploadedImageUrl = imageUrl;
        _isUploading = false;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      body: SafeArea(
        child: Column(
          children: [
            // 메인 콘텐츠
            Expanded(
              child: SingleChildScrollView(
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
                            onPressed: () => Navigator.of(context).pop(),
                            color: AppColors.textPrimary,
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
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
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 60),
                  ],
                ),
              ),
            ),
            // 하단 버튼
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_isFormValid() && !_isUploading)
                      ? () {
                          widget.onNext(
                            CourseBasicInfoData(
                              name: _nameController.text.trim(),
                              description: _descriptionController.text.trim(),
                              imageUrl: _uploadedImageUrl,
                            ),
                          );
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: (_isFormValid() && !_isUploading)
                        ? AppColors.primaryGreen
                        : AppColors.borderLight,
                    disabledBackgroundColor: AppColors.borderLight,
                    padding: const EdgeInsets.symmetric(vertical: 18),
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
                      color: (_isFormValid() && !_isUploading)
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
    );
  }

  Widget _buildModernTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    String? hintText,
    String? errorText,
    int? minLines,
  }) {
    final hasError = errorText != null && errorText.isNotEmpty;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      maxLines: null,
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
      onChanged: (_) => setState(() {}),
    );
  }

  // 코스 이미지 업로드
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
          CourseImageWidget(
            imageUrl: _uploadedImageUrl,
            width: 150,
            height: 150,
            borderRadius: borderRadius,
            localImageFile: _selectedImage, // 로컬 이미지를 placeholder로 사용
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
                  color: AppColors.primaryGreen,
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
          ClipRRect(
            borderRadius: borderRadius,
            child: Image.file(
              _selectedImage!,
              width: 150,
              height: 150,
              fit: BoxFit.cover,
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
