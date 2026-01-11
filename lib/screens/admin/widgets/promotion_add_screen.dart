import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../../theme/app_colors.dart';
import '../../../models/admin_models.dart';
import '../../../services/storage_service.dart';
import '../../../utils/snackbar_util.dart';

/// 스토리(프로모션) 추가 화면
class PromotionAddScreen extends StatefulWidget {
  final PromotionData? existingPromotion;
  final Function(PromotionData) onSave;
  final Function()? onDelete;

  const PromotionAddScreen({
    super.key,
    this.existingPromotion,
    required this.onSave,
    this.onDelete,
  });

  @override
  State<PromotionAddScreen> createState() => _PromotionAddScreenState();
}

class _PromotionAddScreenState extends State<PromotionAddScreen> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _titleFocusNode = FocusNode();
  final _descriptionFocusNode = FocusNode();
  File? _selectedImage;
  final ImagePicker _imagePicker = ImagePicker();

  String? _existingImageUrl; // 기존 이미지 URL (수정 시)

  @override
  void initState() {
    super.initState();
    if (widget.existingPromotion != null) {
      _titleController.text = widget.existingPromotion!.title;
      _descriptionController.text = widget.existingPromotion!.description;
      _existingImageUrl = widget.existingPromotion!.imageUrl;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _titleFocusNode.dispose();
    _descriptionFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();

    if (title.isEmpty || description.isEmpty) {
      SnackbarUtil.showError(context, '제목과 설명을 입력해주세요');
      return;
    }

    // 이미지 업로드 처리
    String? imageUrl;

    if (_selectedImage != null) {
      // 새 이미지가 선택된 경우 업로드
      try {
        // 로딩 표시
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const Center(
            child: CircularProgressIndicator(color: AppColors.primaryGreen),
          ),
        );

        final storageService = StorageService();
        imageUrl = await storageService.uploadImage(
          imageFile: _selectedImage!,
          folder: 'promotions',
        );

        // 기존 이미지가 있으면 삭제 (수정 시)
        if (_existingImageUrl != null && _existingImageUrl != imageUrl) {
          try {
            await storageService.deleteImage(_existingImageUrl!);
          } catch (e) {
            // 삭제 실패는 무시 (이미 새 이미지로 교체됨)
          }
        }

        // 로딩 닫기
        if (mounted) {
          Navigator.of(context).pop();
        }
      } catch (e) {
        // 로딩 닫기
        if (mounted) {
          Navigator.of(context).pop();
          SnackbarUtil.showError(context, '이미지 업로드에 실패했습니다: ${e.toString()}');
        }
        return;
      }
    } else {
      // 새 이미지가 없으면 기존 이미지 URL 유지 (수정 시)
      imageUrl = _existingImageUrl;
    }

    final promotion = PromotionData(
      title: title,
      description: description,
      tag: null,
      imageUrl: imageUrl,
      backgroundColor: null,
    );

    widget.onSave(promotion);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundWhite,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.existingPromotion == null ? '스토리 추가' : '스토리 수정',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _handleSave(),
            child: Text(
              '저장',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryGreen,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              // 인라인 편집 가능한 카드
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 상단: # 아이콘
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.primaryGreen,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Text(
                          '#',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 이미지 추가 버튼 또는 이미지
                    if (_selectedImage == null && _existingImageUrl == null)
                      GestureDetector(
                        onTap: () async {
                          final source = await showDialog<ImageSource>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('이미지 선택'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.photo_library),
                                    title: const Text('갤러리에서 선택'),
                                    onTap: () => Navigator.of(
                                      context,
                                    ).pop(ImageSource.gallery),
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.camera_alt),
                                    title: const Text('카메라로 촬영'),
                                    onTap: () => Navigator.of(
                                      context,
                                    ).pop(ImageSource.camera),
                                  ),
                                ],
                              ),
                            ),
                          );

                          if (source != null) {
                            final pickedFile = await _imagePicker.pickImage(
                              source: source,
                            );
                            if (pickedFile != null) {
                              setState(() {
                                _selectedImage = File(pickedFile.path);
                              });
                            }
                          }
                        },
                        child: Container(
                          width: double.infinity,
                          height: 120,
                          decoration: BoxDecoration(
                            color: AppColors.primaryGreen.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: AppColors.primaryGreen,
                              width: 2,
                              style: BorderStyle.solid,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.add_photo_alternate,
                                color: AppColors.primaryGreen,
                                size: 32,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '이미지 추가',
                                style: TextStyle(
                                  color: AppColors.primaryGreen,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Stack(
                        children: [
                          Container(
                            width: double.infinity,
                            height: 200,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: _selectedImage != null
                                  ? Image.file(
                                      _selectedImage!,
                                      fit: BoxFit.cover,
                                    )
                                  : _existingImageUrl != null
                                  ? Image.network(
                                      _existingImageUrl!,
                                      fit: BoxFit.cover,
                                      errorBuilder:
                                          (context, error, stackTrace) {
                                            return Container(
                                              color: Colors.grey.shade200,
                                              child: Icon(
                                                Icons.image_not_supported,
                                                color: Colors.grey.shade400,
                                              ),
                                            );
                                          },
                                    )
                                  : Container(color: Colors.grey.shade200),
                            ),
                          ),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedImage = null;
                                  _existingImageUrl = null;
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.close,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    // 제목 (인라인 편집)
                    TextField(
                      controller: _titleController,
                      focusNode: _titleFocusNode,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        hintText: '제목을 입력하세요',
                        hintStyle: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    // 설명 (인라인 편집)
                    TextField(
                      controller: _descriptionController,
                      focusNode: _descriptionFocusNode,
                      maxLines: null,
                      minLines: 3,
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                        height: 1.5,
                      ),
                      decoration: InputDecoration(
                        hintText: '설명을 입력하세요',
                        hintStyle: TextStyle(
                          color: AppColors.textSecondary.withOpacity(0.5),
                          fontSize: 14,
                          height: 1.5,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        alignLabelWithHint: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
              ),
              if (widget.existingPromotion != null &&
                  widget.onDelete != null) ...[
                const SizedBox(height: 30),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
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
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('삭제'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      side: BorderSide(color: Colors.red.withOpacity(0.5)),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
