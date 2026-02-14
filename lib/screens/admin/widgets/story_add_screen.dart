import 'dart:io';
import 'dart:ui' as ui;
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
  // 각 이미지의 업로드 상태를 추적 (파일 경로 -> 업로드 중 여부)
  Map<String, bool> _uploadingStatus = {};
  bool _isSaving = false; // 게시 중 여부

  // 초기값 저장 (변경사항 감지용)
  String _initialTitle = '';
  String _initialContent = '';
  List<String> _initialImageUrls = [];

  @override
  void initState() {
    super.initState();
    if (widget.existingStory != null) {
      _titleController.text = widget.existingStory!.title;
      _contentController.text = widget.existingStory!.content;
      _uploadedImageUrls = List<String>.from(widget.existingStory!.imageUrls);

      // 초기값 저장
      _initialTitle = widget.existingStory!.title;
      _initialContent = widget.existingStory!.content;
      _initialImageUrls = List<String>.from(widget.existingStory!.imageUrls);
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
        imageQuality: 70, // 화질을 낮춰서 파일 크기 감소
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
          _selectedImages.addAll(newFiles);
          // 모든 새 이미지를 업로드 중 상태로 설정 (파일 경로를 키로 사용)
          for (final file in newFiles) {
            _uploadingStatus[file.path] = true;
          }
        });

        // 모든 이미지를 병렬로 업로드 시작 (파일 경로를 사용하여 추적)
        final uploadFutures =
            newFiles.map((file) => _uploadImageByFile(file)).toList();
        await Future.wait(uploadFutures);
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '이미지를 선택할 수 없습니다');
      }
    }
  }

  /// 이미지 리사이징 (최대 너비 1920px로 제한)
  Future<File?> _resizeImageIfNeeded(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // 이미지가 이미 작으면 리사이징 불필요
      if (image.width <= 1920) {
        image.dispose();
        return imageFile;
      }

      // 비율 유지하며 리사이징
      final ratio = image.width / image.height;
      final newWidth = 1920;
      final newHeight = (1920 / ratio).round();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()..filterQuality = FilterQuality.medium;

      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, newWidth.toDouble(), newHeight.toDouble()),
        paint,
      );
      image.dispose();

      final picture = recorder.endRecording();
      final resizedImage = await picture.toImage(newWidth, newHeight);
      final byteData = await resizedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      resizedImage.dispose();
      picture.dispose();

      if (byteData == null) {
        return imageFile;
      }

      // 임시 파일에 저장 (원본 확장자 유지)
      final originalPath = imageFile.path;
      final extension =
          originalPath.contains('.')
              ? originalPath.substring(originalPath.lastIndexOf('.'))
              : '.jpg';
      final resizedFile = File('${originalPath}_resized$extension');
      await resizedFile.writeAsBytes(byteData.buffer.asUint8List());

      return resizedFile;
    } catch (e) {
      debugPrint('이미지 리사이징 실패: $e');
      return imageFile; // 실패 시 원본 파일 반환
    }
  }

  Future<void> _uploadImageByFile(File file) async {
    final filePath = file.path;

    // 파일이 _selectedImages에 있는지 확인하고 인덱스 찾기
    final index = _selectedImages.indexWhere((f) => f.path == filePath);
    if (index == -1) return; // 파일이 이미 제거되었거나 없음

    try {
      // 이미지 리사이징 (필요한 경우)
      final resizedFile = await _resizeImageIfNeeded(file);
      final fileToUpload = resizedFile ?? file;

      final storageService = firebase_storage.StorageService();
      final imageUrl = await storageService.uploadImage(
        imageFile: fileToUpload,
        folder: 'stories',
      );

      // 리사이징된 임시 파일 삭제
      if (resizedFile != null && resizedFile.path != file.path) {
        try {
          await resizedFile.delete();
        } catch (e) {
          debugPrint('임시 파일 삭제 실패: $e');
        }
      }

      if (mounted) {
        setState(() {
          // 업로드 완료: 해당 파일 경로의 업로드 상태 제거
          _uploadingStatus.remove(filePath);

          // 업로드된 이미지는 _selectedImages에서 제거하고 _uploadedImageUrls에 추가
          _selectedImages.removeWhere((f) => f.path == filePath);
          _uploadedImageUrls.add(imageUrl);
        });
      }
    } catch (e) {
      if (mounted) {
        // 업로드 실패 시 파일 경로로 찾아서 제거
        setState(() {
          // 업로드 상태 제거
          _uploadingStatus.remove(filePath);

          // 파일 경로로 찾아서 제거
          _selectedImages.removeWhere((f) => f.path == filePath);
        });

        // 파일 삭제는 setState 이후에 수행 (UI 업데이트 후)
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
      }
    }
  }

  // 변경사항이 있는지 확인
  bool _hasChanges() {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();

    // 이미지가 하나라도 추가된 경우 변경사항으로 판단
    if (_selectedImages.isNotEmpty) return true;

    // 새로 작성하는 경우: 제목이나 내용이 있으면 변경사항 있음
    if (widget.existingStory == null) {
      return title.isNotEmpty ||
          content.isNotEmpty ||
          _uploadedImageUrls.isNotEmpty;
    }

    // 수정하는 경우: 초기값과 비교
    // 제목이나 내용이 변경되었거나, 업로드된 이미지가 변경된 경우
    // 배경 이미지는 첫 번째 이미지로 자동 설정되므로 이미지 리스트 변경 시 자동 반영
    return title != _initialTitle ||
        content != _initialContent ||
        !_listEquals(_uploadedImageUrls, _initialImageUrls);
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

  // 저장 가능한지 확인 (제목 필수, 업로드 중인 이미지 없어야 함)
  bool _canSave() {
    final title = _titleController.text.trim();

    // 업로드 중인 이미지가 있는지 확인
    final hasUploadingImages = _uploadingStatus.values.any(
      (isUploading) => isUploading,
    );

    return title.isNotEmpty && _hasChanges() && !hasUploadingImages;
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
      final uploadFutures =
          _selectedImages.asMap().entries.map((entry) async {
            final index = entry.key;
            final file = entry.value;

            try {
              // 이미지 리사이징 (필요한 경우)
              final resizedFile = await _resizeImageIfNeeded(file);
              final fileToUpload = resizedFile ?? file;

              final storageService = firebase_storage.StorageService();
              final imageUrl = await storageService.uploadImage(
                imageFile: fileToUpload,
                folder: 'stories',
              );

              // 리사이징된 임시 파일 삭제
              if (resizedFile != null && resizedFile.path != file.path) {
                try {
                  await resizedFile.delete();
                } catch (e) {
                  debugPrint('임시 파일 삭제 실패: $e');
                }
              }
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
              return {
                'success': false,
                'url': null,
                'index': index,
                'file': file,
              };
            }
          }).toList();

      try {
        final results = await Future.wait(uploadFutures);
        final failedUploads =
            results.where((r) => r['success'] == false).toList();

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

        final uploadedUrls =
            results
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

    // 배경 이미지는 첫 번째 첨부 이미지를 자동으로 사용
    final String? finalBackgroundImageUrl =
        allImageUrls.isNotEmpty ? allImageUrls[0] : null;

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
                  message: '저장하지 않고 나가시면\n변경된 내용이 사라집니다.\n',
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
                  onPressed: () async {
                    final confirmed = await CommonDialog.show(
                      context: context,
                      title: '스토리 삭제',
                      message: '이 스토리를 삭제할까요?',
                      cancelText: '취소',
                      confirmText: '삭제',
                      confirmButtonColor: Colors.red,
                    );
                    if (confirmed == true && mounted) {
                      widget.onDelete?.call();
                      Navigator.of(context).pop();
                    }
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
                      const Text(
                        '삭제',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.red,
                        ),
                      ),
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
                child:
                    _isSaving
                        ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 1,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.primaryGreen,
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
              child: ListView(
                children: [
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

                        // 내용 입력
                        TextField(
                          controller: _contentController,
                          focusNode: _contentFocusNode,

                          maxLines: null,
                          minLines: 1,
                          style: TextStyle(
                            fontSize: 18,
                            color: AppColors.textPrimary.withOpacity(0.9),
                            height: 1.8,
                            letterSpacing: 0.2,
                          ),
                          decoration: InputDecoration(
                            hintText: '내용을 입력하세요...',
                            hintStyle: TextStyle(
                              color: AppColors.textSecondary.withOpacity(0.4),
                              fontSize: 18,
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
            Positioned(
              bottom: 24 + MediaQuery.of(context).padding.bottom,
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
    final isFirstImage = index == 0; // 첫 번째 이미지인지 확인

    // 안정적인 키 생성: 업로드된 이미지는 URL, 선택된 이미지는 파일 경로 사용
    final String uniqueKey;
    if (isUploaded) {
      uniqueKey = _uploadedImageUrls[index];
    } else {
      final localIndex = index - _uploadedImageUrls.length;
      uniqueKey = _selectedImages[localIndex].path;
    }

    return ReorderableDelayedDragStartListener(
      key: ValueKey(uniqueKey),
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
              child:
                  isUploaded
                      ? CachedNetworkImage(
                        imageUrl: _uploadedImageUrls[index],
                        cacheKey: _uploadedImageUrls[index],
                        fit: BoxFit.cover,
                        maxWidthDiskCache: 1000,
                        maxHeightDiskCache: 1000,
                        memCacheWidth: 1000,
                        memCacheHeight: 1000,
                        fadeInDuration: const Duration(milliseconds: 0),
                        fadeOutDuration: const Duration(milliseconds: 0),
                        placeholder:
                            (context, url) => Container(
                              color: AppColors.backgroundLight,
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: AppColors.primaryGreen,
                                  strokeWidth: 1,
                                ),
                              ),
                            ),
                        errorWidget:
                            (context, url, error) => Container(
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
                (index - _uploadedImageUrls.length) < _selectedImages.length)
              Builder(
                builder: (context) {
                  final localIndex = index - _uploadedImageUrls.length;
                  final file = _selectedImages[localIndex];
                  if (_uploadingStatus[file.path] == true) {
                    return Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.95),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Center(
                          child: CircularProgressIndicator(
                            color: AppColors.primaryGreen,
                            strokeWidth: 1,
                            backgroundColor: Colors.white,
                          ),
                        ),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            // 첫 번째 이미지에 대표 칩 표시
            if (isFirstImage)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primaryGreen,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    '대표',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
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
