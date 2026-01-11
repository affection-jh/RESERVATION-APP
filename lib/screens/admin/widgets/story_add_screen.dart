import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../theme/app_colors.dart';
import '../../../models/admin_models.dart';
import '../../../utils/snackbar_util.dart';
import '../../../services/storage_service.dart' as firebase_storage;
import '../../../widgets/common_dialog.dart';

// 이미지 데이터 타입
enum _ImageType { uploaded, selected }

class _ImageData {
  final _ImageType type;
  final String? url;
  final File? file;
  final int index;

  _ImageData({required this.type, this.url, this.file, required this.index});
}

/// 스토리 추가 화면
class StoryAddScreen extends StatefulWidget {
  final StoryData? existingStory;
  final Function(StoryData) onSave;
  final Function()? onDelete;

  const StoryAddScreen({
    super.key,
    this.existingStory,
    required this.onSave,
    this.onDelete,
  });

  @override
  State<StoryAddScreen> createState() => _StoryAddScreenState();
}

class _StoryAddScreenState extends State<StoryAddScreen> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _titleFocusNode = FocusNode();
  final _contentFocusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();

  List<File> _selectedImages = [];
  List<String> _uploadedImageUrls = [];
  // 각 이미지의 업로드 상태를 추적 (인덱스 -> 업로드 중 여부)
  Map<int, bool> _uploadingStatus = {};
  bool _isSaving = false; // 게시 중 여부

  // 배경 이미지 관련
  File? _selectedBackgroundImage;
  String? _uploadedBackgroundImageUrl;
  bool _isUploadingBackground = false;

  // 초기값 저장 (변경사항 감지용)
  String _initialTitle = '';
  String _initialContent = '';
  List<String> _initialImageUrls = [];
  String? _initialBackgroundImageUrl;

  @override
  void initState() {
    super.initState();
    if (widget.existingStory != null) {
      _titleController.text = widget.existingStory!.title;
      _contentController.text = widget.existingStory!.content;
      _uploadedImageUrls = List<String>.from(widget.existingStory!.imageUrls);
      _uploadedBackgroundImageUrl = widget.existingStory!.backgroundImageUrl;

      // 초기값 저장
      _initialTitle = widget.existingStory!.title;
      _initialContent = widget.existingStory!.content;
      _initialImageUrls = List<String>.from(widget.existingStory!.imageUrls);
      _initialBackgroundImageUrl = widget.existingStory!.backgroundImageUrl;
    }

    // 변경사항 감지를 위한 리스너 추가
    _titleController.addListener(() => setState(() {}));
    _contentController.addListener(() => setState(() {}));

    // 화면 진입 시 제목 필드에 포커스
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _titleFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _titleFocusNode.dispose();
    _contentFocusNode.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final List<XFile> images = await _imagePicker.pickMultiImage(
        imageQuality: 85,
      );

      if (images.isNotEmpty) {
        // 모든 이미지를 먼저 추가
        final List<File> newFiles = [];
        for (final xFile in images) {
          final file = File(xFile.path);
          newFiles.add(file);
        }

        setState(() {
          // 모든 이미지를 한 번에 추가
          final startIndex = _selectedImages.length;
          _selectedImages.addAll(newFiles);
          // 모든 새 이미지를 업로드 중 상태로 설정
          for (int i = 0; i < newFiles.length; i++) {
            _uploadingStatus[startIndex + i] = true;
          }
        });

        // 모든 이미지를 병렬로 업로드 시작
        for (int i = 0; i < newFiles.length; i++) {
          final index = _selectedImages.length - newFiles.length + i;
          _uploadImage(index); // await 없이 병렬 실행
        }
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '이미지를 선택할 수 없습니다');
      }
    }
  }

  Future<void> _pickBackgroundImage() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _selectedBackgroundImage = File(image.path);
          _isUploadingBackground = true;
        });

        // 배경 이미지 업로드
        try {
          final storageService = firebase_storage.StorageService();
          final imageUrl = await storageService.uploadImage(
            imageFile: _selectedBackgroundImage!,
            folder: 'stories/backgrounds',
          );

          if (mounted) {
            setState(() {
              _uploadedBackgroundImageUrl = imageUrl;
              _selectedBackgroundImage = null;
              _isUploadingBackground = false;
            });
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _selectedBackgroundImage = null;
              _isUploadingBackground = false;
            });
            SnackbarUtil.showError(context, '배경 이미지 업로드에 실패했습니다');
          }
        }
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '이미지를 선택할 수 없습니다');
      }
    }
  }

  void _deleteBackgroundImage() async {
    if (_uploadedBackgroundImageUrl != null) {
      try {
        final storageService = firebase_storage.StorageService();
        await storageService.deleteImage(_uploadedBackgroundImageUrl!);
      } catch (e) {
        debugPrint('배경 이미지 삭제 실패: $e');
      }
    }

    setState(() {
      _uploadedBackgroundImageUrl = null;
      _selectedBackgroundImage = null;
      _isUploadingBackground = false;
    });
  }

  Future<void> _uploadImage(int index) async {
    if (index >= _selectedImages.length) return;

    // 파일 경로를 미리 저장 (인덱스 변경 전)
    final filePath = _selectedImages[index].path;

    try {
      final storageService = firebase_storage.StorageService();
      final imageUrl = await storageService.uploadImage(
        imageFile: _selectedImages[index],
        folder: 'stories',
      );

      if (mounted) {
        setState(() {
          // 업로드 완료: 해당 인덱스의 업로드 상태 제거
          _uploadingStatus.remove(index);

          // 업로드된 이미지는 _selectedImages에서 제거하고 _uploadedImageUrls에 추가
          _selectedImages.removeAt(index);
          _uploadedImageUrls.add(imageUrl);

          // 인덱스가 변경된 이미지들의 업로드 상태 맵 업데이트
          final newUploadingStatus = <int, bool>{};
          _uploadingStatus.forEach((oldIndex, isUploading) {
            if (oldIndex < index) {
              // 제거된 인덱스보다 앞에 있는 것들은 그대로
              newUploadingStatus[oldIndex] = isUploading;
            } else if (oldIndex > index) {
              // 제거된 인덱스보다 뒤에 있는 것들은 인덱스 -1
              newUploadingStatus[oldIndex - 1] = isUploading;
            }
            // oldIndex == index인 경우는 제거되므로 추가하지 않음
          });
          _uploadingStatus = newUploadingStatus;
        });
      }
    } catch (e) {
      if (mounted) {
        // 업로드 실패 시 파일 경로로 찾아서 제거
        setState(() {
          // 업로드 상태 제거
          _uploadingStatus.remove(index);

          // 파일 경로로 찾아서 제거 (인덱스가 변경되었을 수 있으므로)
          _selectedImages.removeWhere((file) => file.path == filePath);

          // 인덱스가 변경된 이미지들의 업로드 상태 맵 업데이트
          final newUploadingStatus = <int, bool>{};
          _uploadingStatus.forEach((oldIndex, isUploading) {
            if (oldIndex < index) {
              newUploadingStatus[oldIndex] = isUploading;
            } else if (oldIndex > index) {
              newUploadingStatus[oldIndex - 1] = isUploading;
            }
          });
          _uploadingStatus = newUploadingStatus;
        });

        // 파일 삭제는 setState 이후에 수행 (UI 업데이트 후)
        try {
          final failedFile = File(filePath);
          if (await failedFile.exists()) {
            await failedFile.delete();
          }
        } catch (deleteError) {
          debugPrint('파일 삭제 실패: $deleteError');
        }

        if (mounted) {
          SnackbarUtil.showError(context, '이미지 업로드에 실패했습니다');
        }
      }
    }
  }

  // 변경사항이 있는지 확인
  bool _hasChanges() {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();

    // 이미지가 하나라도 추가된 경우 변경사항으로 판단
    if (_selectedImages.isNotEmpty) return true;

    // 배경 이미지가 변경된 경우
    if (_uploadedBackgroundImageUrl != _initialBackgroundImageUrl) return true;

    // 새로 작성하는 경우: 제목이나 내용이 있으면 변경사항 있음
    if (widget.existingStory == null) {
      return title.isNotEmpty ||
          content.isNotEmpty ||
          _uploadedImageUrls.isNotEmpty ||
          _uploadedBackgroundImageUrl != null;
    }

    // 수정하는 경우: 초기값과 비교
    // 제목이나 내용이 변경되었거나, 업로드된 이미지가 변경된 경우
    return title != _initialTitle ||
        content != _initialContent ||
        !_listEquals(_uploadedImageUrls, _initialImageUrls) ||
        _uploadedBackgroundImageUrl != _initialBackgroundImageUrl;
  }

  // 리스트 비교 헬퍼
  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // 이미지 리오더
  void _reorderImages(int oldIndex, int newIndex) {
    setState(() {
      // ReorderableListView 규칙: 이동 후 인덱스가 한 칸 당겨짐
      if (newIndex > oldIndex) newIndex -= 1;

      final totalImages = _uploadedImageUrls.length + _selectedImages.length;
      if (oldIndex < 0 ||
          oldIndex >= totalImages ||
          newIndex < 0 ||
          newIndex >= totalImages) {
        return;
      }

      // 업로드된 이미지와 선택된 이미지를 하나의 리스트로 관리
      final allImageData = <_ImageData>[];

      // 업로드된 이미지 추가
      for (int i = 0; i < _uploadedImageUrls.length; i++) {
        allImageData.add(
          _ImageData(
            type: _ImageType.uploaded,
            url: _uploadedImageUrls[i],
            index: i,
          ),
        );
      }

      // 선택된 이미지 추가
      for (int i = 0; i < _selectedImages.length; i++) {
        allImageData.add(
          _ImageData(
            type: _ImageType.selected,
            file: _selectedImages[i],
            index: i,
          ),
        );
      }

      // 리오더
      final item = allImageData.removeAt(oldIndex);
      allImageData.insert(newIndex, item);

      // 다시 분리
      final newUploadedUrls = <String>[];
      final newSelectedFiles = <File>[];

      for (final data in allImageData) {
        if (data.type == _ImageType.uploaded) {
          newUploadedUrls.add(data.url!);
        } else {
          newSelectedFiles.add(data.file!);
        }
      }

      _uploadedImageUrls = newUploadedUrls;
      _selectedImages = newSelectedFiles;
    });
  }

  // 저장 가능한지 확인 (제목 필수)
  bool _canSave() {
    final title = _titleController.text.trim();
    return title.isNotEmpty && _hasChanges();
  }

  Future<void> _deleteImage(int index) async {
    // index가 업로드된 이미지 범위 내인지 확인
    if (index < _uploadedImageUrls.length) {
      // 업로드된 이미지 삭제
      final urlToDelete = _uploadedImageUrls[index];
      try {
        final storageService = firebase_storage.StorageService();
        await storageService.deleteImage(urlToDelete);
      } catch (e) {
        debugPrint('이미지 삭제 실패: $e');
      }
      setState(() {
        _uploadedImageUrls.removeAt(index);
        // 업로드된 이미지가 삭제되면 해당 인덱스의 선택 이미지도 삭제
        if (index < _selectedImages.length) {
          _selectedImages.removeAt(index);
        }
      });
      setState(() {}); // 변경사항 감지를 위해
    } else {
      // 선택만 하고 아직 업로드되지 않은 이미지 삭제
      final localIndex = index - _uploadedImageUrls.length;
      if (localIndex >= 0 && localIndex < _selectedImages.length) {
        setState(() {
          _selectedImages.removeAt(localIndex);
        });
      }
      setState(() {}); // 변경사항 감지를 위해
    }
  }

  void _handleSave() async {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();

    if (title.isEmpty || content.isEmpty) {
      SnackbarUtil.showError(context, '제목과 내용을 입력해주세요');
      return;
    }

    setState(() {
      _isSaving = true;
    });

    // 모든 이미지 URL 리스트 (기존 업로드된 것 + 새로 업로드할 것)
    final List<String> allImageUrls = List<String>.from(_uploadedImageUrls);

    // 선택한 로컬 이미지들을 저장 시에만 업로드 (병렬로)
    if (_selectedImages.isNotEmpty) {
      // 모든 이미지를 병렬로 업로드
      final uploadFutures = _selectedImages.asMap().entries.map((entry) async {
        final index = entry.key;
        final file = entry.value;

        try {
          final storageService = firebase_storage.StorageService();
          final imageUrl = await storageService.uploadImage(
            imageFile: file,
            folder: 'stories',
          );
          return {
            'success': true,
            'url': imageUrl,
            'index': index,
            'file': file,
          };
        } catch (e) {
          // 업로드 실패 시 파일 삭제
          try {
            if (await file.exists()) {
              await file.delete();
            }
          } catch (deleteError) {
            debugPrint('파일 삭제 실패: $deleteError');
          }
          if (mounted) {
            SnackbarUtil.showError(context, '이미지 업로드에 실패했습니다');
          }
          return {'success': false, 'url': null, 'index': index, 'file': file};
        }
      }).toList();

      try {
        final results = await Future.wait(uploadFutures);
        final failedUploads = results
            .where((r) => r['success'] == false)
            .toList();

        if (failedUploads.isNotEmpty) {
          // 실패한 이미지들을 _selectedImages에서 제거
          setState(() {
            for (final result in failedUploads.reversed) {
              final index = result['index'] as int;
              if (index < _selectedImages.length) {
                _selectedImages.removeAt(index);
              }
            }
            _isSaving = false;
          });
          return;
        }

        final uploadedUrls = results
            .where((r) => r['success'] == true)
            .map((r) => r['url'] as String)
            .toList();
        allImageUrls.addAll(uploadedUrls);
      } catch (e) {
        // 모든 이미지 파일 삭제 시도
        for (final file in _selectedImages) {
          try {
            if (await file.exists()) {
              await file.delete();
            }
          } catch (deleteError) {
            debugPrint('파일 삭제 실패: $deleteError');
          }
        }
        if (mounted) {
          setState(() {
            _isSaving = false;
          });
        }
        return;
      }
    }

    // 배경 이미지가 선택되어 있지만 아직 업로드되지 않은 경우 업로드
    String? finalBackgroundImageUrl = _uploadedBackgroundImageUrl;
    if (_selectedBackgroundImage != null && !_isUploadingBackground) {
      try {
        final storageService = firebase_storage.StorageService();
        final imageUrl = await storageService.uploadImage(
          imageFile: _selectedBackgroundImage!,
          folder: 'stories/backgrounds',
        );
        finalBackgroundImageUrl = imageUrl;
      } catch (e) {
        if (mounted) {
          SnackbarUtil.showError(context, '배경 이미지 업로드에 실패했습니다');
          setState(() {
            _isSaving = false;
          });
          return;
        }
      }
    }

    final story = StoryData(
      title: title,
      content: content,
      date: DateTime.now().toString(),
      imageUrls: allImageUrls,
      backgroundImageUrl: finalBackgroundImageUrl,
    );

    widget.onSave(story);
    if (mounted) {
      setState(() {
        _isSaving = false;
      });
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(),
      child: Scaffold(
        backgroundColor: AppColors.backgroundWhite,
        appBar: AppBar(
          scrolledUnderElevation: 0,
          backgroundColor: AppColors.backgroundWhite,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
            onPressed: () async {
              if (_hasChanges()) {
                final confirmed = await CommonDialog.show(
                  context: context,
                  title: '변경사항이 있습니다',
                  message: '저장하지 않고 나가시면 변경된 내용이 사라집니다.',
                  secondaryMessage: '정말 나가시겠습니까?',
                  cancelText: '취소',
                  confirmText: '나가기',
                  confirmButtonColor: Colors.red,
                );
                if (confirmed == true && mounted) {
                  Navigator.of(context).pop();
                }
              } else {
                Navigator.of(context).pop();
              }
            },
          ),

          centerTitle: false,
          actions: [
            // 수정 모드일 때 삭제 버튼
            if (widget.existingStory != null && widget.onDelete != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: OutlinedButton(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('스토리 삭제'),
                        content: const Text('이 스토리를 삭제할까요?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('취소'),
                          ),
                          FilledButton(
                            onPressed: () {
                              widget.onDelete?.call();
                              Navigator.of(context).pop();
                              Navigator.of(context).pop();
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.red,
                            ),
                            child: const Text('삭제'),
                          ),
                        ],
                      ),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    side: BorderSide(
                      color: Colors.red.withOpacity(0.3),
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SvgPicture.asset(
                        'assets/icons/delete.svg',
                        width: 20,
                        height: 20,
                        colorFilter: const ColorFilter.mode(
                          Colors.red,
                          BlendMode.srcIn,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('삭제'),
                    ],
                  ),
                ),
              ),
            // 저장/수정 버튼
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: (_canSave() && !_isSaving) ? _handleSave : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primaryGreen,
                  disabledBackgroundColor: AppColors.borderLight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: _isSaving
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                    : Text(
                        widget.existingStory == null ? '게시하기' : '수정하기',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ],
        ),
        body: Stack(
          children: [
            SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 배경 이미지 선택 섹션
                    if (_uploadedBackgroundImageUrl != null ||
                        _selectedBackgroundImage != null ||
                        _isUploadingBackground)
                      Container(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '배경 이미지',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const Spacer(),
                                if (_uploadedBackgroundImageUrl != null ||
                                    _selectedBackgroundImage != null)
                                  TextButton.icon(
                                    onPressed: _deleteBackgroundImage,
                                    icon: const Icon(Icons.close, size: 18),
                                    label: const Text('제거'),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.red,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // 배경 이미지 미리보기
                            Container(
                              height: 200,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: AppColors.borderLight,
                                  width: 1,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: _isUploadingBackground
                                    ? Container(
                                        color: AppColors.backgroundLight,
                                        child: Center(
                                          child: CircularProgressIndicator(
                                            color: AppColors.primaryGreen,
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      )
                                    : _selectedBackgroundImage != null
                                    ? Image.file(
                                        _selectedBackgroundImage!,
                                        fit: BoxFit.cover,
                                      )
                                    : _uploadedBackgroundImageUrl != null
                                    ? CachedNetworkImage(
                                        imageUrl: _uploadedBackgroundImageUrl!,
                                        fit: BoxFit.cover,
                                        placeholder: (context, url) =>
                                            Container(
                                              color: AppColors.backgroundLight,
                                              child: Center(
                                                child:
                                                    CircularProgressIndicator(
                                                      color: AppColors
                                                          .primaryGreen,
                                                      strokeWidth: 2,
                                                    ),
                                              ),
                                            ),
                                        errorWidget: (context, url, error) =>
                                            Container(
                                              color: AppColors.backgroundLight,
                                              child: Icon(
                                                Icons.error_outline,
                                                color: AppColors.textSecondary,
                                              ),
                                            ),
                                      )
                                    : Container(
                                        color: AppColors.backgroundLight,
                                        child: Center(
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(
                                                Icons.image_outlined,
                                                size: 48,
                                                color: AppColors.textSecondary
                                                    .withOpacity(0.5),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                '배경 이미지 없음',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: AppColors.textSecondary
                                                      .withOpacity(0.6),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),

                    // 배경 이미지 선택 버튼 (배경 이미지가 없을 때만 표시)
                    if (_uploadedBackgroundImageUrl == null &&
                        _selectedBackgroundImage == null &&
                        !_isUploadingBackground)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: OutlinedButton.icon(
                          onPressed: _pickBackgroundImage,
                          icon: const Icon(Icons.image_outlined, size: 20),
                          label: const Text('배경 이미지 선택'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.primaryGreen,
                            side: BorderSide(
                              color: AppColors.primaryGreen.withOpacity(0.3),
                              width: 1.5,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),

                    // 이미지 리스트 (상단) - AnimatedSize로 부드러운 전환
                    AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      child:
                          (_uploadedImageUrls.isNotEmpty ||
                              _selectedImages.isNotEmpty)
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  height: 204, // 180 + padding
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.backgroundWhite,
                                  ),
                                  child: ReorderableListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    onReorder: _reorderImages,
                                    buildDefaultDragHandles: false,
                                    proxyDecorator: (child, index, animation) {
                                      return AnimatedBuilder(
                                        animation: animation,
                                        builder: (context, _) {
                                          final t = Curves.easeOut.transform(
                                            animation.value,
                                          );
                                          final scale = 1.0 + (0.1 * t);
                                          return Transform.scale(
                                            scale: scale,
                                            child: Material(
                                              color: Colors.transparent,
                                              elevation: 8 * t,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              shadowColor: Colors.black
                                                  .withOpacity(0.2),
                                              child: child,
                                            ),
                                          );
                                        },
                                      );
                                    },
                                    itemCount:
                                        _uploadedImageUrls.length +
                                        _selectedImages.length,
                                    itemBuilder: (contxt, index) {
                                      final isUploaded =
                                          index < _uploadedImageUrls.length;
                                      return _buildImageItem(index, isUploaded);
                                    },
                                  ),
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                    // 텍스트 입력 부분
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 16),

                          // 제목 입력
                          TextField(
                            controller: _titleController,
                            focusNode: _titleFocusNode,

                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                              height: 1.3,
                            ),
                            decoration: InputDecoration(
                              hintText: '제목을 입력하세요',
                              hintStyle: TextStyle(
                                color: AppColors.textSecondary.withOpacity(0.4),
                                fontSize: 32,
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const SizedBox(height: 12),

                          // 날짜 표시
                          Text(
                            '${DateTime.now().year}년 ${DateTime.now().month}월 ${DateTime.now().day}일',
                            style: TextStyle(
                              fontSize: 16,
                              color: AppColors.textSecondary.withOpacity(0.6),
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                          const SizedBox(height: 32),

                          // 내용 입력
                          TextField(
                            controller: _contentController,
                            focusNode: _contentFocusNode,

                            maxLines: null,
                            minLines: 15,
                            style: TextStyle(
                              fontSize: 17,
                              color: AppColors.textPrimary,
                              height: 1.8,
                              letterSpacing: 0.2,
                            ),
                            decoration: InputDecoration(
                              hintText: '내용을 입력하세요...',
                              hintStyle: TextStyle(
                                color: AppColors.textSecondary.withOpacity(0.4),
                                fontSize: 17,
                                height: 1.8,
                                letterSpacing: 0.2,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const SizedBox(height: 40),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            Positioned(
              bottom: 34,
              right: 24,
              child: FloatingActionButton(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(50),
                ),
                onPressed: _pickImage,
                backgroundColor: AppColors.primaryGreen,
                child: SvgPicture.asset(
                  'assets/icons/gallery-icon.svg',
                  width: 34,
                  height: 34,
                  colorFilter: const ColorFilter.mode(
                    Colors.white,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 이미지 아이템 빌더 (리오더 가능)
  Widget _buildImageItem(int index, bool isUploaded) {
    return ReorderableDelayedDragStartListener(
      key: ValueKey('image_$index'),
      index: index,
      child: Container(
        width: 180,
        height: 180,
        margin: const EdgeInsets.only(right: 8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: isUploaded
                  ? CachedNetworkImage(
                      imageUrl: _uploadedImageUrls[index],
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        color: AppColors.backgroundLight,
                        child: Center(
                          child: CircularProgressIndicator(
                            color: AppColors.primaryGreen,
                            strokeWidth: 2,
                          ),
                        ),
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: AppColors.backgroundLight,
                        child: Icon(
                          Icons.error_outline,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                  : Image.file(
                      _selectedImages[index - _uploadedImageUrls.length],
                      fit: BoxFit.cover,
                    ),
            ),
            // 업로드 중 표시 (선택된 이미지이고 업로드 중인 경우)
            if (!isUploaded &&
                (index - _uploadedImageUrls.length) >= 0 &&
                (index - _uploadedImageUrls.length) < _selectedImages.length &&
                _uploadingStatus[index - _uploadedImageUrls.length] == true)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: CircularProgressIndicator(
                      color: Colors.grey.shade400,
                      strokeWidth: 3,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
            // 삭제 버튼 (항상 위에 표시)
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                onTap: () => _deleteImage(index),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
