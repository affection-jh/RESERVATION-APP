import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../models/course.dart' as reservation_models;
import '../../../utils/text_field_decoration_util.dart';
import '../../../services/storage_service.dart';
import '../../../utils/navigator_key.dart';
import '../../../utils/snackbar_util.dart';
import '../../../widgets/cached_image_widget.dart';
import '../../../widgets/course_color_picker_bottom_sheet.dart';
import '../../../widgets/common_dialog.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/place_provider.dart';
import 'course_schedule_edit_screen.dart';

/// 코스 정보 수정 화면 (한 페이지)
class CourseEditScreen extends StatefulWidget {
  final reservation_models.Course course;

  const CourseEditScreen({super.key, required this.course});

  @override
  State<CourseEditScreen> createState() => _CourseEditScreenState();
}

class _CourseEditScreenState extends State<CourseEditScreen> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _nameFocusNode = FocusNode();
  final _descriptionFocusNode = FocusNode();
  File? _selectedImage;
  String? _uploadedImageUrl; // 업로드된 이미지 URL
  String? _existingImageUrl; // 기존 코스의 원본 이미지 URL (Storage 삭제용)
  bool _isUploading = false; // 업로드 중 여부
  Future<String?>? _uploadFuture; // 업로드 중 뒤로갈 때 완료 후 삭제용
  late int _selectedColor; // 선택된 색상
  final ImagePicker _imagePicker = ImagePicker();
  bool _isSaving = false; // 저장 중 여부
  bool _isDeleting = false; // 삭제 중 여부

  // 에러 메시지
  String? _nameErrorText;

  // 일괄 적용 모드 관련
  bool _useUniformSettings = false;
  int _uniformTotalReservations = 10;
  reservation_models.PeriodType _uniformPeriodType =
      reservation_models.PeriodType.weeks;
  int _uniformPeriodValue = 1;
  final TextEditingController _uniformTotalReservationsController =
      TextEditingController();
  final TextEditingController _uniformPeriodController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    // Place의 description 값을 기본값으로 사용
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final currentPlace = placeProvider.currentPlace;
    final placeDescription = currentPlace?.description ?? '';

    // 기존 코스 정보 로드
    _nameController.text = widget.course.name;
    // description이 비어있으면 Place의 description을 기본값으로 사용
    _descriptionController.text =
        widget.course.description.isEmpty
            ? placeDescription
            : widget.course.description;
    _uploadedImageUrl = widget.course.imageUrl;
    _existingImageUrl = widget.course.imageUrl; // 원본 URL 저장 (삭제용)
    _selectedColor = widget.course.color;

    // 기본 수업 횟수/유효기간 초기화
    _useUniformSettings = false;
    _uniformTotalReservations = widget.course.defaultTotalReservations;
    _uniformPeriodType =
        widget.course.defaultPeriodType ?? reservation_models.PeriodType.weeks;
    _uniformPeriodValue = widget.course.defaultPeriodValue ?? 1;
    // 0이면 빈 문자열로 표시 (hintText로 "0" 표시)
    _uniformTotalReservationsController.text =
        _uniformTotalReservations == 0
            ? ''
            : _uniformTotalReservations.toString();
    _uniformPeriodController.text = _uniformPeriodValue.toString();

    // 코스명 입력 시 실시간 검증
    _nameController.addListener(() {
      _validateName();
      setState(() {});
    });
    // 설명 입력 시 버튼 상태 업데이트
    _descriptionController.addListener(() {
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
    _uniformTotalReservationsController.dispose();
    _uniformPeriodController.dispose();
    _nameFocusNode.dispose();
    _descriptionFocusNode.dispose();
    super.dispose();
  }

  /// 코스명 검증 (중복 체크 포함)
  void _validateName() {
    final courseName = _nameController.text.trim();
    if (courseName.isEmpty) {
      setState(() {
        _nameErrorText = '코스명을 입력해주세요.';
      });
      return;
    }

    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final courses = courseProvider.courses;

    // 기존 코스 편집 시 자기 자신은 제외
    final hasDuplicate = courses.any(
      (course) =>
          course.name.trim().toLowerCase() == courseName.toLowerCase() &&
          course.id != widget.course.id,
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
    // 코스명 검증
    if (_nameController.text.trim().isEmpty || _nameErrorText != null) {
      return false;
    }

    // 일괄 적용 모드가 켜져 있을 때 수업 횟수가 0이면 유효하지 않음
    if (_useUniformSettings && _uniformTotalReservations == 0) {
      return false;
    }

    return true;
  }

  /// 변경사항이 있는지 확인
  bool _hasChanges() {
    // 이름 변경 확인
    if (_nameController.text.trim() != widget.course.name) {
      return true;
    }

    // 설명 변경 확인
    if (_descriptionController.text.trim() != widget.course.description) {
      return true;
    }

    // 색상 변경 확인
    if (_selectedColor != widget.course.color) {
      return true;
    }

    // 기본 수업 횟수/유효기간 변경 확인
    if (_uniformTotalReservations != widget.course.defaultTotalReservations) {
      return true;
    }
    if (_uniformPeriodType !=
        (widget.course.defaultPeriodType ??
            reservation_models.PeriodType.weeks)) {
      return true;
    }
    if (_uniformPeriodValue != (widget.course.defaultPeriodValue ?? 1)) {
      return true;
    }

    // 이미지 변경 확인
    // 1. 기존 이미지가 있었는데 삭제된 경우
    if (widget.course.imageUrl != null && _uploadedImageUrl == null) {
      return true;
    }

    // 2. 기존 이미지가 없었는데 추가된 경우
    if (widget.course.imageUrl == null && _uploadedImageUrl != null) {
      return true;
    }

    // 3. 기존 이미지와 다른 이미지로 변경된 경우
    if (widget.course.imageUrl != null &&
        _uploadedImageUrl != null &&
        widget.course.imageUrl != _uploadedImageUrl) {
      return true;
    }

    return false;
  }

  Future<void> _handleBack() async {
    if (!_hasChanges()) {
      Navigator.of(context).pop();
      return;
    }
    final confirmed = await CommonDialog.show(
      context: context,
      title: '변경사항이 있습니다',
      message: '변경된 내용이 사라집니다.\n나가시겠습니까?',
      cancelText: '취소',
      confirmText: '나가기',
      confirmButtonColor: Colors.red,
    );
    if (confirmed != true || !mounted) return;
    if (_uploadedImageUrl != null &&
        _uploadedImageUrl != widget.course.imageUrl) {
      StorageService.deleteImagesInBackground([_uploadedImageUrl!]);
    } else if (_isUploading && _uploadFuture != null) {
      _uploadFuture!.then((url) {
        if (url != null && url.isNotEmpty) {
          StorageService.deleteImagesInBackground([url]);
        }
      });
    }
    Navigator.of(context).pop();
  }

  /// 갤러리에서 이미지 선택 또는 교체
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

  /// 코스 정보 저장
  Future<void> _saveCourse() async {
    // 최종 검증
    _validateName();

    if (!_isFormValid() || !_hasChanges()) {
      // 에러가 있으면 포커스 이동
      if (_nameErrorText != null) {
        _nameFocusNode.requestFocus();
      }
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);

      // 현재 플레이스 가져오기
      final currentPlace = placeProvider.currentPlace;
      if (currentPlace == null) {
        if (mounted) {
          SnackbarUtil.showInfo(context, '플레이스 정보를 찾을 수 없습니다.');
        }
        return;
      }

      final updatedCourse = reservation_models.Course(
        id: widget.course.id,
        placeId: widget.course.placeId,
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        color: _selectedColor,
        imageUrl: _uploadedImageUrl,
        sessions: widget.course.sessions,
        defaultTotalReservations:
            _useUniformSettings
                ? _uniformTotalReservations
                : widget.course.defaultTotalReservations,
        defaultPeriodType:
            _useUniformSettings
                ? _uniformPeriodType
                : widget.course.defaultPeriodType,
        defaultPeriodValue:
            _useUniformSettings
                ? _uniformPeriodValue
                : widget.course.defaultPeriodValue,
        policy: widget.course.policy,
        createdAt: widget.course.createdAt,
        updatedAt: DateTime.now(),
      );

      // CourseProvider의 updateCourse 사용
      await courseProvider.updateCourse(updatedCourse);

      if (mounted) {
        SnackbarUtil.showSuccess(context, '코스 정보가 저장되었습니다.');
        Navigator.of(context).pop(true); // true를 반환하여 상위 화면에서 새로고침 가능하도록
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showInfo(context, '저장에 실패했습니다: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  /// 코스 삭제
  Future<void> _deleteCourse() async {
    // 삭제 버튼을 누르는 순간 저장 버튼 숨기기
    setState(() {
      _isDeleting = true;
    });

    // 삭제 확인 다이얼로그 표시
    final result = await CommonDialogWithTextField.show(
      context: context,
      title: '코스 삭제',
      message: '이 작업은 되돌릴 수 없습니다.\n삭제하려면 코스명을 정확히 입력하세요.',
      hintText: widget.course.name,
      cancelText: '취소',
      confirmText: '삭제',
      confirmButtonColor: Colors.red,
      expectedText: widget.course.name, // 정확히 일치해야 함
    );

    if (result == null) {
      // 취소됨 - 저장 버튼 다시 표시
      if (mounted) {
        setState(() {
          _isDeleting = false;
        });
      }
      return;
    }

    // 삭제 진행 - 스낵바로 로딩 표시
    final ctx = navigatorKey.currentContext ?? context;
    SnackbarUtil.showLoading(ctx, '코스 삭제중');

    try {
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );

      // 1) cascade=false로 먼저 체크(미래 예약 있으면 requiresCascade로 막힘)
      try {
        await courseProvider.deleteCourse(widget.course.id, cascade: false);
      } on FirebaseFunctionsException catch (e) {
        final details = e.details;
        final detailsMap =
            details is Map ? Map<String, dynamic>.from(details) : null;
        final requiresCascade = detailsMap?['requiresCascade'] == true;
        final kind = detailsMap?['kind'];

        if (requiresCascade && kind == 'deleteCourse') {
          final reservationCount = detailsMap?['reservationCount'];

          final confirmedCascade = await CommonDialog.show(
            context: context,
            title: '코스 삭제',
            message: '$reservationCount건의 예약이 있는 코스입니다.\n삭제 처리하시겠습니까?',
            cancelText: '취소',
            confirmText: '코스 삭제',
            confirmButtonColor: Colors.red,
          );
          if (confirmedCascade != true) {
            if (mounted) setState(() => _isDeleting = false);
            return;
          }

          await courseProvider.deleteCourse(widget.course.id, cascade: true);
        } else {
          rethrow;
        }
      }

      // 삭제 완료 - navigatorKey 사용 (사용자가 뒤로가기로 나갔어도 동작)
      // 상세 화면 제거로 코스 탭 시 바로 편집 화면으로 가므로 1번만 pop
      final navCtx = navigatorKey.currentContext;
      if (navCtx != null) {
        final navigator = Navigator.of(navCtx);
        if (navigator.canPop()) navigator.pop(); // CourseEditScreen
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = navigatorKey.currentContext;
          if (ctx != null) {
            SnackbarUtil.showSuccess(ctx, '코스가 삭제되었습니다.');
          }
        });
      }
    } catch (e) {
      final navCtx = navigatorKey.currentContext;
      if (navCtx != null) {
        SnackbarUtil.showInfo(navCtx, '코스 삭제 중 문제가 발생했어요.\n잠시 후 다시 시도해주세요.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDeleting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasChanges(),
      onPopInvokedWithResult: (bool didPop, dynamic result) {
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
                child: GestureDetector(
                  onTap: () {
                    // 여백을 탭하면 키보드 내리기
                    FocusScope.of(context).unfocus();
                  },
                  behavior: HitTestBehavior.opaque,
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
                                onPressed: _handleBack,
                                color: AppColors.textPrimary,
                              ),

                              const Spacer(),
                              // 일정 편집 버튼
                              OutlinedButton(
                                onPressed:
                                    (_isSaving || _isDeleting)
                                        ? null
                                        : () async {
                                          final courseProvider =
                                              Provider.of<CourseProvider>(
                                                context,
                                                listen: false,
                                              );
                                          final currentCourse =
                                              courseProvider.getCourse(
                                                widget.course.id,
                                              ) ??
                                              widget.course;
                                          final result = await Navigator.of(
                                            context,
                                          ).push(
                                            MaterialPageRoute(
                                              builder:
                                                  (context) =>
                                                      CourseScheduleEditScreen(
                                                        course: currentCourse,
                                                      ),
                                            ),
                                          );
                                          if (result == true && mounted) {
                                            setState(() {});
                                          }
                                        },
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  side: BorderSide(
                                    color: AppColors.borderLight,
                                    width: 1.5,
                                  ),
                                ),
                                child: Text(
                                  '정기 일정 편집',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // 코스 삭제 버튼
                              OutlinedButton(
                                onPressed:
                                    (_isSaving || _isDeleting)
                                        ? null
                                        : _deleteCourse,
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  side: BorderSide(
                                    color: AppColors.borderLight,
                                    width: 1.5,
                                  ),
                                ),
                                child: Text(
                                  '코스 삭제',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 코스 이미지 업로드
                              _buildImageUpload(),
                              const SizedBox(height: 44),
                              // 코스명
                              Text(
                                '코스명',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _buildModernTextField(
                                controller: _nameController,
                                focusNode: _nameFocusNode,
                                hintText: '코스명을 입력해주세요',
                                errorText: _nameErrorText,
                              ),
                              const SizedBox(height: 20),
                              // 위치/설명
                              Text(
                                '설명',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _buildModernTextField(
                                controller: _descriptionController,
                                focusNode: _descriptionFocusNode,
                                hintText: '위치 또는 설명을 입력해주세요',
                                minLines: 2,
                              ),
                              const SizedBox(height: 24),
                              // 코스 색상 선택
                              _buildColorSelection(),
                              const SizedBox(height: 34),

                              // 일괄 적용 모드
                              _buildUniformSettingsField(),
                              const SizedBox(height: 16),
                            ],
                          ),
                        ),
                        const SizedBox(height: 60),
                      ],
                    ),
                  ),
                ),
              ),
              // 하단 버튼 (삭제 중일 때는 숨김)
              if (!_isDeleting)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 4,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed:
                          (_isFormValid() &&
                                  _hasChanges() &&
                                  !_isSaving &&
                                  !_isUploading)
                              ? _saveCourse
                              : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            (_isFormValid() &&
                                    _hasChanges() &&
                                    !_isSaving &&
                                    !_isUploading)
                                ? AppColors.primaryGreen
                                : AppColors.borderLight,
                        disabledBackgroundColor: AppColors.borderLight,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        elevation: 0,
                      ),
                      child:
                          _isSaving
                              ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                              : Text(
                                '저장',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color:
                                      (_isFormValid() &&
                                              _hasChanges() &&
                                              !_isSaving &&
                                              !_isUploading)
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
    int? minLines,
    String? errorText,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          focusNode: focusNode,
          style: TextStyle(
            fontSize: 16,
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
          maxLines: null,
          minLines: minLines ?? 1,
          decoration: TextFieldDecorationUtil.defaultDecoration(
            hintText: hintText,
            hasFocus: focusNode.hasFocus,
            floatingLabelBehavior: FloatingLabelBehavior.always,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ).copyWith(
            errorText: errorText,
            errorBorder:
                errorText != null
                    ? OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    )
                    : null,
            focusedErrorBorder:
                errorText != null
                    ? OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    )
                    : null,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
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

  // 코스 색상 선택
  Widget _buildColorSelection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '코스 대표 색상',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary.withOpacity(0.8),
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () {
            showCourseColorPickerBottomSheet(context, _selectedColor, (
              selectedColor,
            ) {
              setState(() {
                _selectedColor = selectedColor;
              });
            });
          },
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderLight, width: 1),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Color(_selectedColor),
                    borderRadius: BorderRadius.circular(50),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '색상 선택',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 일괄 적용 모드 필드
  Widget _buildUniformSettingsField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 토글 스위치
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '기본 등록값 설정',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary.withOpacity(0.8),
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: _useUniformSettings,
              onChanged: (value) {
                setState(() {
                  _useUniformSettings = value;
                });
              },
              activeColor: Color(_selectedColor),
            ),
          ],
        ),

        // 일괄 적용 설정 UI (토글이 켜져 있을 때만 표시)
        if (_useUniformSettings) ...[
          const SizedBox(height: 24),
          // 일괄 적용 수업 횟수
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '수업 횟수',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 100,
                height: 46,
                child: TextField(
                  controller: _uniformTotalReservationsController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: '0',
                    hintStyle: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 0,
                    ),
                    filled: true,
                    fillColor: AppColors.backgroundLight,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (value) {
                    if (value.isEmpty) {
                      setState(() {
                        _uniformTotalReservations = 0;
                        // controller는 빈 문자열 유지 (hintText 표시)
                      });
                    } else {
                      final total = int.tryParse(value);
                      if (total != null && total > 0) {
                        setState(() {
                          _uniformTotalReservations = total;
                        });
                      } else if (total == 0) {
                        // 0을 입력하면 빈 문자열로 변경
                        _uniformTotalReservationsController.text = '';
                        setState(() {
                          _uniformTotalReservations = 0;
                        });
                      }
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // 일괄 적용 유효기간
          _buildUniformValidPeriodField(),
        ],
      ],
    );
  }

  /// 일괄 적용 유효기간 설정 위젯
  Widget _buildUniformValidPeriodField() {
    int getMaxValue() {
      return 999;
    }

    String getUnitText() {
      switch (_uniformPeriodType) {
        case reservation_models.PeriodType.weeks:
          return '주';
        case reservation_models.PeriodType.days:
          return '일';
        case reservation_models.PeriodType.months:
          return '개월';
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '유효기간',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        // 탭바 (주/달/일)
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.backgroundLight,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Expanded(
                child: _buildPeriodTab(
                  label: '주',
                  isSelected:
                      _uniformPeriodType == reservation_models.PeriodType.weeks,
                  onTap: () {
                    setState(() {
                      _uniformPeriodType = reservation_models.PeriodType.weeks;
                      _uniformPeriodValue = 1;
                      _uniformPeriodController.text = '1';
                    });
                  },
                ),
              ),
              Expanded(
                child: _buildPeriodTab(
                  label: '달',
                  isSelected:
                      _uniformPeriodType ==
                      reservation_models.PeriodType.months,
                  onTap: () {
                    setState(() {
                      _uniformPeriodType = reservation_models.PeriodType.months;
                      _uniformPeriodValue = 1;
                      _uniformPeriodController.text = '1';
                    });
                  },
                ),
              ),
              Expanded(
                child: _buildPeriodTab(
                  label: '일',
                  isSelected:
                      _uniformPeriodType == reservation_models.PeriodType.days,
                  onTap: () {
                    setState(() {
                      _uniformPeriodType = reservation_models.PeriodType.days;
                      _uniformPeriodValue = 7;
                      _uniformPeriodController.text = '7';
                    });
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 값 조절 UI
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.backgroundLight,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // - 버튼
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap:
                      _uniformPeriodValue > 0
                          ? () {
                            setState(() {
                              final newValue = _uniformPeriodValue - 1;
                              _uniformPeriodValue = newValue;
                              _uniformPeriodController.text =
                                  newValue.toString();
                            });
                          }
                          : null,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.remove_rounded,
                      size: 20,
                      color:
                          _uniformPeriodValue > 0
                              ? AppColors.primaryGreen
                              : AppColors.textLight.withOpacity(0.3),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // 값 표시
              SizedBox(
                width: 60,
                child: TextField(
                  controller: _uniformPeriodController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color:
                        _uniformPeriodValue == 0
                            ? AppColors.textSecondary.withOpacity(0.4)
                            : AppColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: '0',
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                    suffixText: getUnitText(),
                    suffixStyle: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  onChanged: (value) {
                    if (value.isEmpty) {
                      setState(() {
                        _uniformPeriodValue = 0;
                      });
                    } else {
                      final intValue = int.tryParse(value);
                      if (intValue != null &&
                          intValue >= 0 &&
                          intValue <= getMaxValue()) {
                        setState(() {
                          _uniformPeriodValue = intValue;
                        });
                      }
                    }
                  },
                  onSubmitted: (value) {
                    if (value.isEmpty) {
                      setState(() {
                        _uniformPeriodValue = 0;
                        _uniformPeriodController.text = '0';
                      });
                    } else {
                      final intValue = int.tryParse(value);
                      if (intValue == null || intValue < 0) {
                        setState(() {
                          _uniformPeriodValue = 0;
                          _uniformPeriodController.text = '0';
                        });
                      } else if (intValue > getMaxValue()) {
                        setState(() {
                          _uniformPeriodValue = getMaxValue();
                          _uniformPeriodController.text =
                              getMaxValue().toString();
                        });
                      } else {
                        setState(() {
                          _uniformPeriodValue = intValue;
                        });
                      }
                    }
                  },
                ),
              ),
              const SizedBox(width: 16),
              // + 버튼
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap:
                      _uniformPeriodValue < getMaxValue()
                          ? () {
                            setState(() {
                              final newValue = _uniformPeriodValue + 1;
                              _uniformPeriodValue = newValue;
                              _uniformPeriodController.text =
                                  newValue.toString();
                            });
                          }
                          : null,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.add_rounded,
                      size: 20,
                      color:
                          _uniformPeriodValue < getMaxValue()
                              ? AppColors.primaryGreen
                              : AppColors.textLight.withOpacity(0.3),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 유효기간 탭 위젯
  Widget _buildPeriodTab({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.backgroundWhite : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color:
                  isSelected ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
