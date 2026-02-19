import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:reservation/utils/text_field_decoration_util.dart';
import '../../../theme/app_colors.dart';
import '../../../models/place.dart';
import '../../../models/member_view.dart';
import '../../../models/place_member.dart';
import '../../../utils/snackbar_util.dart';
import '../../../widgets/cached_image_widget.dart' show PlaceImageWidget;
import '../../../widgets/story_card.dart';
import '../../../services/storage_service.dart';
import '../../../services/member_service.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/member_provider.dart';
import '../../../services/user_service.dart';
import '../../../utils/format_utils.dart';
import '../../../utils/firestore_utils.dart';
import '../../../utils/navigator_key.dart';
import '../../../widgets/common_dialog.dart';
import 'place_delete_confirm_screen.dart';
import 'card_widgets.dart';
import 'member_selection_side_panel.dart';

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
  Future<String?>? _uploadFuture; // 업로드 중 뒤로갈 때 완료 후 삭제용

  // 저장 관련
  bool _isSaving = false;
  bool _leaveRequested = false;

  // 초기값 저장 (변경사항 추적용)
  String _initialName = '';
  String _initialLocation = '';
  String _initialDescription = '';
  String _initialAppBarText = '';
  String _initialGreetingText = '';
  bool _hideGreeting = false;
  bool _initialHideGreeting = false;

  @override
  void initState() {
    super.initState();
    // 기존 플레이스 정보가 있으면 초기값 설정
    if (widget.place != null) {
      _initialName = widget.place!.name;
      _initialDescription = widget.place!.description ?? '';
      _existingImageUrl = widget.place!.imageUrl;
      _initialGreetingText = widget.place!.greetingText ?? '';
      _hideGreeting = widget.place!.hideGreeting;
      _initialHideGreeting = widget.place!.hideGreeting;

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

  // 변경사항이 있는지 확인 (저장 버튼·뒤로가기 확인용)
  bool _hasChanges() {
    if (widget.place == null) {
      return _nameController.text.trim().isNotEmpty ||
          _locationController.text.trim().isNotEmpty ||
          _descriptionController.text.trim().isNotEmpty ||
          _appBarTextController.text.trim().isNotEmpty ||
          _greetingTextController.text.trim().isNotEmpty ||
          _hideGreeting ||
          _uploadedImageUrl != null;
    }
    // 수정 시: 현재 이미지(새로 올린 것 또는 기존 URL)가 초기와 다를 때만 변경으로 간주
    final currentImageUrl = _uploadedImageUrl ?? _existingImageUrl;
    return _nameController.text.trim() != _initialName ||
        _locationController.text.trim() != _initialLocation ||
        _descriptionController.text.trim() != _initialDescription ||
        _appBarTextController.text.trim() != _initialAppBarText ||
        _greetingTextController.text.trim() != _initialGreetingText ||
        _hideGreeting != _initialHideGreeting ||
        currentImageUrl != widget.place!.imageUrl;
  }

  Future<void> _handleBackDuringSave() async {
    if (!_isSaving) return;
    final leave = await CommonDialog.showSavingLeaveConfirm(
      context: context,
      onLeave: () => _leaveRequested = true,
    );
    if (leave && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _handleBack() async {
    _removeFocus();
    if (_isSaving) {
      await _handleBackDuringSave();
      return;
    }
    if (!_hasChanges()) {
      if (mounted) Navigator.of(context).pop();
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
        _uploadedImageUrl != widget.place?.imageUrl) {
      StorageService.deleteImagesInBackground([_uploadedImageUrl!]);
    } else if (_isUploadingImage && _uploadFuture != null) {
      _uploadFuture!.then((url) {
        if (url != null && url.isNotEmpty) {
          StorageService.deleteImagesInBackground([url]);
        }
      });
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasChanges() && !_isSaving,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        if (_isSaving) {
          await _handleBackDuringSave();
        } else {
          _handleBack();
        }
      },
      child: Scaffold(
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
                      if (widget.place != null) ...[
                        _buildFullManagersSection(),
                        const SizedBox(height: 42),
                      ],
                      // 플레이스 기본 정보 섹션
                      _buildBasicInfoSection(),

                      const SizedBox(height: 42),

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
            onPressed: _handleBack,
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
            OutlinedButton(
              onPressed: () {
                _showDeleteDialog(context);
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: BorderSide(
                  color: AppColors.textSecondary.withOpacity(0.6),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                '플레이스 삭제',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
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
        _uploadFuture = _uploadImage();
        await _uploadFuture;
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showInfo(context, '이미지를 선택할 수 없습니다');
      }
    }
  }

  // 이미지 업로드. 성공 시 URL 반환, 실패 시 null.
  Future<String?> _uploadImage() async {
    if (_selectedImage == null) return null;

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

      if (!mounted) return imageUrl;
      setState(() {
        _uploadedImageUrl = imageUrl;
        _existingImageUrl = imageUrl;
        _selectedImage = null;
        _isUploadingImage = false;
      });
      SnackbarUtil.showSuccess(context, '이미지가 업로드되었습니다');
      return imageUrl;
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUploadingImage = false;
        });
        SnackbarUtil.showInfo(context, '이미지 업로드에 실패했습니다');
      }
      return null;
    }
  }

  // 기본 정보 섹션
  Widget _buildBasicInfoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 플레이스 이름 입력
        _buildNameInput(),
        const SizedBox(height: 4),

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
          '플레이스 이름 및 설명',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary.withOpacity(0.8),
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
        TextField(
          style: TextStyle(
            fontSize: 16,
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
          controller: _descriptionController,
          focusNode: _descriptionFocusNode,
          textInputAction: TextInputAction.newline,

          onSubmitted: (_) {
            _appBarFocusNode.requestFocus();
          },
          decoration: TextFieldDecorationUtil.defaultDecoration(
            hintText: '플레이스에 대한 설명을 입력하세요',
            floatingLabelBehavior: FloatingLabelBehavior.always,
            hasFocus: _descriptionFocusNode.hasFocus,
          ),
          maxLines: null,
          minLines: 3,
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  /// 플레이스 전체 매니저 관리 (코스 매니저 설정과 동일 UI)
  Widget _buildFullManagersSection() {
    final place = widget.place!;
    final placeId = place.id;

    return Consumer2<PlaceProvider, MemberProvider>(
      builder: (context, placeProvider, memberProvider, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (memberProvider.placeId != placeId) {
            memberProvider.setPlaceId(placeId);
          }
        });

        final currentPlace = placeProvider.getPlace(placeId) ?? place;
        final adminIds = currentPlace.adminIds;
        final managerMembers =
            memberProvider.allMembers.where((v) {
              if (v.isPending) return v.isManager; // 매니저로 초대된 팬딩
              // 가입 직후 place 갱신 전에도 표시: adminIds 또는 members.role 기준
              return adminIds.contains(v.userId) || v.isManager;
            }).toList();
        final deduped = _dedupeByPhone(managerMembers);

        return SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      '플레이스 매니저',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary.withOpacity(0.8),
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed:
                        () => _openFullManagerAddPanel(
                          context,
                          placeId,
                          adminIds,
                        ),
                    icon: Icon(
                      Icons.add_circle,
                      color: AppColors.primaryGreen,
                      size: 28,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (deduped.isEmpty)
                GestureDetector(
                  onTap:
                      () =>
                          _openFullManagerAddPanel(context, placeId, adminIds),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.backgroundLight.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Text(
                      '아직 전체 매니저가 없어요',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final v in deduped)
                      MemberCard(
                        backgroundColor: AppColors.backgroundLight.withOpacity(
                          0.5,
                        ),
                        member: v,
                        roleChipLabel: '매니저',
                        openDetailSheetOnTap: false,
                        onMemberTapped:
                            () => _showFullManagerActionSheet(
                              context,
                              placeId: placeId,
                              place: currentPlace,
                              member: v,
                            ),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  static List<MemberView> _dedupeByPhone(List<MemberView> list) {
    final seen = <String>{};
    return list.where((v) {
      final key = v.phoneNumber.trim();
      if (key.isEmpty) return true;
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();
  }

  void _openFullManagerAddPanel(
    BuildContext context,
    String placeId,
    List<String> currentAdminIds,
  ) {
    MemberSelectionSidePanel.showForFullManagerAdd(
      context: context,
      placeId: placeId,
      currentAdminIds: currentAdminIds,
      onMembersSelected: (selected) async {
        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final memberProvider = Provider.of<MemberProvider>(
          context,
          listen: false,
        );
        final memberService = MemberService();
        final place = placeProvider.getPlace(placeId);
        if (place == null) return;

        final pendingSelected = selected.where((m) => m.isPending).toList();
        final toAdd = selected.where((m) => !m.isPending).map((m) => m.userId).toList();

        // pending: 문서 role만 'manager'로 수정 → 가입 시 createEnrollmentsFromPendingMembers에서 매니저 반영 (Functions 안 탐)
        for (final m in pendingSelected) {
          if (!m.userId.startsWith('pending_')) continue;
          final pendingId = m.userId.substring(8);
          await memberService.updatePendingMemberRole(placeId, pendingId, 'manager');
        }

        if (toAdd.isNotEmpty) {
          final newAdminIds = [...place.adminIds, ...toAdd];
          await placeProvider.updatePlace(place.copyWith(adminIds: newAdminIds));
          for (final uid in toAdd) {
            final current = await memberService.getPlaceMember(placeId, uid);
            if (current != null) {
              await memberService.setPlaceMember(
                placeId,
                uid,
                current.copyWith(role: PlaceMemberRole.manager),
              );
            }
          }
        }

        if (!context.mounted) return;
        setState(() {});
        placeProvider.loadPlace(placeId);
        memberProvider.setPlaceId(placeId, force: true);

        final promoted = toAdd.length;
        final pendingCount = pendingSelected.length;
        if (promoted > 0 && pendingCount > 0) {
          SnackbarUtil.showSuccess(
            context,
            '$promoted명을 전체 매니저로 추가했습니다. '
            '가입 대기 중인 $pendingCount명은 가입 시 매니저로 지정됩니다.',
          );
        } else if (promoted > 0) {
          SnackbarUtil.showSuccess(
            context,
            promoted == 1 ? '전체 매니저로 추가했습니다.' : '$promoted명을 전체 매니저로 추가했습니다.',
          );
        } else if (pendingCount > 0) {
          SnackbarUtil.showSuccess(
            context,
            pendingCount == 1
                ? '가입 시 전체 매니저로 지정됩니다.'
                : '가입 대기 중인 $pendingCount명은 가입 시 매니저로 지정됩니다.',
          );
        }
      },
    );
  }

  void _showFullManagerActionSheet(
    BuildContext context, {
    required String placeId,
    required Place place,
    required MemberView member,
  }) {
    FullManagerActionBottomSheet.show(
      context: context,
      placeId: placeId,
      place: place,
      member: member,
      onRemoved: () {
        if (!context.mounted) return;
        setState(() {});
        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        placeProvider.loadPlace(placeId);
      },
    );
  }

  // 인사말 설정 섹션
  Widget _buildGreetingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '환영 메시지를 수정할 수 있습니다',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary.withOpacity(0.8),
          ),
        ),
        const SizedBox(height: 16),
        // 미리보기 섹션
        _buildPreviewSection(),
        const SizedBox(height: 20),
        // 환영메시지 숨기기 체크박스 (원형 커스텀)
        _buildHideGreetingCheckbox(),
      ],
    );
  }

  /// 환영메시지 숨기기 체크박스 (원형 커스텀)
  Widget _buildHideGreetingCheckbox() {
    return GestureDetector(
      onTap: () => setState(() => _hideGreeting = !_hideGreeting),
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color:
                      _hideGreeting
                          ? AppColors.primaryGreen
                          : AppColors.textSecondary.withOpacity(0.5),
                  width: 2,
                ),
                color:
                    _hideGreeting ? AppColors.primaryGreen : Colors.transparent,
              ),
              child:
                  _hideGreeting
                      ? Icon(Icons.check, size: 16, color: Colors.white)
                      : null,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '환영메시지 숨기기',
            style: TextStyle(
              fontSize: 16,
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
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
            // 제목 섹션 (환영메시지 숨기기 체크 시 미리보기에서 미표시)
            if (!_hideGreeting) _buildPreviewTitleSection(),
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
            disabledForegroundColor: AppColors.textSecondary,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child:
              _isSaving
                  ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                  : Text(
                    widget.place != null ? '수정 완료' : '등록 완료',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color:
                          (_hasChanges() && !_isSaving)
                              ? Colors.white
                              : AppColors.textSecondary,
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
    final userService = UserService();
    final currentAdmin = authProvider.currentAdmin;
    if (currentAdmin == null) {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
        SnackbarUtil.showInfo(context, '관리자 정보를 찾을 수 없습니다.');
      }
      return;
    }

    try {
      if (_leaveRequested) return;
      final probeDocId =
          widget.place?.id ?? placeProvider.currentPlace?.id ?? 'probe';
      if (!await FirestoreUtils.canReachFirestoreForSave(
        probeCollection: 'places',
        probeDocId: probeDocId,
      )) {
        if (mounted) {
          setState(() => _isSaving = false);
          SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요. ');
        }
        return;
      }
      if (widget.place == null) {
        // 새로 등록 — Cloud Function 사용 (권한·중복 방지)
        final creatorDisplayName =
            currentAdmin.username.trim().isNotEmpty
                ? currentAdmin.username.trim()
                : '관리자';

        Place newPlace;
        try {
          final result = await FirebaseFunctions.instance
              .httpsCallable('createPlaceWithMember')
              .call(<String, dynamic>{
                'name': _nameController.text.trim(),
                'description':
                    _descriptionController.text.trim().isEmpty
                        ? null
                        : _descriptionController.text.trim(),
                'appBarText':
                    _appBarTextController.text.trim().isEmpty
                        ? null
                        : _appBarTextController.text.trim(),
                'greetingText':
                    _greetingTextController.text.trim().isEmpty
                        ? null
                        : _greetingTextController.text.trim(),
                'hideGreeting': _hideGreeting,
                'imageUrl': _uploadedImageUrl,
                'adminDisplayName': creatorDisplayName,
                'phoneNumber': currentAdmin.phoneNumber,
              });

          final data = result.data as Map<String, dynamic>?;
          if (data == null || data['success'] != true) {
            throw Exception('플레이스 생성에 실패했습니다.');
          }

          final placeMap = data['place'] as Map<String, dynamic>?;
          if (placeMap == null) throw Exception('응답에 place가 없습니다.');

          newPlace = Place.fromJson(placeMap);

          if (_leaveRequested) return;

          placeProvider.setCreatedPlace(newPlace);
        } on FirebaseFunctionsException catch (e) {
          if (mounted) {
            setState(() => _isSaving = false);
            String msg = '플레이스 등록 중 오류가 발생했습니다.';
            switch (e.code) {
              case 'already-exists':
                msg = '같은 이름의 플레이스가 이미 존재합니다.';
                break;
              case 'unauthenticated':
                msg = '로그인이 필요합니다.';
                break;
              case 'invalid-argument':
                msg = e.message ?? '입력 정보를 확인해주세요.';
                break;
              default:
                msg = e.message ?? msg;
            }
            SnackbarUtil.showInfo(context, msg);
          }
          return;
        } catch (e) {
          if (mounted) {
            setState(() => _isSaving = false);
            SnackbarUtil.showInfo(
              context,
              e.toString().contains('already-exists')
                  ? '같은 이름의 플레이스가 이미 존재합니다.'
                  : '플레이스 등록 중 오류가 발생했습니다.',
            );
          }
          return;
        }

        if (_leaveRequested) return;

        final updatedAdmin = currentAdmin.addPlace(newPlace.id);
        await userService.updateAdmin(updatedAdmin);
        if (authProvider.currentAdmin?.userId == updatedAdmin.userId) {
          authProvider.setCurrentAdmin(updatedAdmin);
        }
        authProvider.addAdminManagedPlace(newPlace.id);

        // PlaceSwitch에서 "일반 모드" 진입용: approvedPlaceIds에 새 플레이스 추가
        final memberPlaceIds =
            authProvider.placeAccessEntries
                .where((e) => e.isAdmin == false)
                .map((e) => e.placeId)
                .toSet()
                .toList();
        if (!memberPlaceIds.contains(newPlace.id)) {
          authProvider.setApprovedPlaceIds([...memberPlaceIds, newPlace.id]);
        }
        if (_leaveRequested) return;

        if (mounted) {
          Navigator.of(context).pop(newPlace);
          SnackbarUtil.showSuccess(context, '플레이스가 등록되었습니다.');
        }
      } else {
        // 수정
        final updatedPlace = widget.place!.copyWith(
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
          hideGreeting: _hideGreeting,
          imageUrl: _uploadedImageUrl ?? widget.place!.imageUrl,
        );

        await placeProvider.updatePlace(updatedPlace);
        if (_leaveRequested) return;

        if (mounted) {
          Navigator.of(context).pop(updatedPlace);
          SnackbarUtil.showSuccess(context, '플레이스 정보가 수정되었습니다.');
        }
      }
    } catch (e) {
      if (_leaveRequested) return;
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
        SnackbarUtil.showInfoFromError(
          context,
          e,
          fallback: '저장 중 오류가 발생했습니다.',
        );
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

// ---------------------------------------------------------------------------
// 전체 매니저 카드 탭 시: 제거(해제) 액션 바텀시트 (이름 변경 가능, 상단 원형 칩 닫기)
// ---------------------------------------------------------------------------

class FullManagerActionBottomSheet extends StatefulWidget {
  final String placeId;
  final Place place;
  final MemberView member;
  final VoidCallback onRemoved;

  const FullManagerActionBottomSheet({
    super.key,
    required this.placeId,
    required this.place,
    required this.member,
    required this.onRemoved,
  });

  static void show({
    required BuildContext context,
    required String placeId,
    required Place place,
    required MemberView member,
    required VoidCallback onRemoved,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder:
          (ctx) => FullManagerActionBottomSheet(
            placeId: placeId,
            place: place,
            member: member,
            onRemoved: onRemoved,
          ),
    );
  }

  @override
  State<FullManagerActionBottomSheet> createState() =>
      _FullManagerActionBottomSheetState();
}

class _FullManagerActionBottomSheetState
    extends State<FullManagerActionBottomSheet> {
  String? _currentMemberName;
  bool _isEditingName = false;
  TextEditingController? _nameController;

  @override
  void initState() {
    super.initState();
    _currentMemberName = widget.member.adminDisplayName;
  }

  @override
  void dispose() {
    _nameController?.dispose();
    super.dispose();
  }

  void _handleEditName() {
    setState(() {
      _isEditingName = true;
      _nameController = TextEditingController(
        text: _currentMemberName ?? widget.member.adminDisplayName,
      );
    });
  }

  Future<void> _saveName() async {
    final newName = _nameController?.text.trim() ?? '';
    final currentName = _currentMemberName ?? widget.member.adminDisplayName;
    if (newName.isEmpty || newName == currentName) {
      setState(() {
        _isEditingName = false;
        _nameController?.dispose();
        _nameController = null;
      });
      return;
    }

    try {
      setState(() {
        _currentMemberName = newName;
        _isEditingName = false;
        _nameController?.dispose();
        _nameController = null;
      });

      final memberService = MemberService();
      final ok = await memberService.updateMemberName(
        placeId: widget.placeId,
        phoneNumber: widget.member.phoneNumber,
        newName: newName,
      );

      if (!ok) {
        if (mounted) {
          setState(() => _currentMemberName = currentName);
          SnackbarUtil.showInfo(context, '이름 수정에 실패했습니다.');
        }
        return;
      }

      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      memberProvider.setPlaceId(widget.placeId, force: true);
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        final list =
            memberProvider.allMembers
                .where((v) => v.phoneNumber == widget.member.phoneNumber)
                .toList();
        if (list.isNotEmpty &&
            list.first.adminDisplayName != _currentMemberName) {
          setState(() => _currentMemberName = list.first.adminDisplayName);
        }
      });

      if (mounted) SnackbarUtil.showSuccess(context, '이름이 수정되었습니다.');
    } catch (e) {
      if (mounted) {
        setState(() => _currentMemberName = currentName);
        SnackbarUtil.showInfo(context, '이름 수정 중 오류가 발생했습니다: $e');
      }
    }
  }

  Future<void> _removeFullManager(BuildContext context) async {
    // adminIds에 있는 사람만 '마지막 매니저'로 막음. role만 manager고 adminIds에 없으면 해제 허용
    final isInAdminIds = widget.place.adminIds.contains(widget.member.userId);
    if (!widget.member.isPending && isInAdminIds && widget.place.adminIds.length <= 1) {
      SnackbarUtil.showInfo(context, '마지막 전체 매니저는 해제할 수 없어요.');
      return;
    }

    final displayName = _currentMemberName ?? widget.member.adminDisplayName;
    final placeId = widget.placeId;
    final place = widget.place;
    final member = widget.member;
    final onRemoved = widget.onRemoved;

    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;

      final confirmed = await CommonDialog.show(
        context: ctx,
        title: '전체 매니저 해제',
        message:
            member.isPending
                ? '$displayName님의 전체 매니저 초대를 해제할까요?'
                : '$displayName님을 전체 매니저에서 해제할까요?\n해제 후에는 일반 멤버로 남습니다.',
        cancelText: '취소',
        confirmText: '해제',
        confirmButtonColor: Colors.red,
      );
      if (confirmed != true) return;

      try {
        final memberService = MemberService();
        if (member.isPending) {
          final pendingId = member.userId.startsWith('pending_')
              ? member.userId.substring(8)
              : null;
          if (pendingId != null) {
            final ok = await memberService.updatePendingMemberRole(
              placeId,
              pendingId,
              'member',
            );
            if (!ctx.mounted) return;
            if (ok) {
              onRemoved();
              SnackbarUtil.showSuccess(ctx, '전체 매니저 초대를 해제했습니다.');
              Provider.of<MemberProvider>(ctx, listen: false)
                  .setPlaceId(placeId, force: true);
            } else {
              SnackbarUtil.showInfo(ctx, '해제에 실패했습니다.');
            }
          }
          return;
        }

        final placeProvider = Provider.of<PlaceProvider>(ctx, listen: false);
        final newAdminIds =
            place.adminIds.where((id) => id != member.userId).toList();
        await placeProvider.updatePlace(place.copyWith(adminIds: newAdminIds));

        final current = await memberService.getPlaceMember(
          placeId,
          member.userId,
        );
        if (current != null) {
          await memberService.setPlaceMember(
            placeId,
            member.userId,
            current.copyWith(
              role: PlaceMemberRole.member,
              manageableCourseIds: [], // 일반 멤버로 해제 시 관리 코스도 정리
            ),
          );
        }

        if (!ctx.mounted) return;
        onRemoved();
        SnackbarUtil.showSuccess(ctx, '전체 매니저에서 해제했습니다.');
        Provider.of<MemberProvider>(
          ctx,
          listen: false,
        ).setPlaceId(placeId, force: true);
      } catch (e) {
        final errCtx = navigatorKey.currentContext;
        if (errCtx != null && errCtx.mounted) {
          SnackbarUtil.showInfoFromError(errCtx, e, fallback: '해제에 실패했습니다.');
        }
      }
    });
  }

  Widget _buildCircleChipButton({
    required String svgPath,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: SvgPicture.asset(
            svgPath,
            width: 20,
            height: 20,
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // pending이거나, adminIds에 2명 이상이거나, 이 멤버가 adminIds에 없으면(role만 매니저) 해제 가능
    final isInAdminIds = widget.place.adminIds.contains(widget.member.userId);
    final canRemove =
        widget.member.isPending ||
        widget.place.adminIds.length > 1 ||
        !isInAdminIds;
    final mq = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundWhite,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 헤더: 이름(또는 인라인 TextField) + 전화번호 | 연필 칩 | 닫기 칩
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_isEditingName)
                            TextField(
                              controller: _nameController,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                isDense: true,
                              ),
                              autofocus: true,
                              maxLines: 1,
                              textInputAction: TextInputAction.done,
                              inputFormatters: [
                                LengthLimitingTextInputFormatter(20),
                              ],
                              onSubmitted: (_) => _saveName(),
                              scrollPadding: EdgeInsets.zero,
                            )
                          else
                            Text(
                              _currentMemberName ??
                                  widget.member.adminDisplayName,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          const SizedBox(height: 4),
                          Text(
                            FormatUtils.formatPhoneNumber(
                              widget.member.phoneNumber,
                            ),
                            style: TextStyle(
                              fontSize: 15,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildCircleChipButton(
                      svgPath: 'assets/icons/edit.svg',
                      color: AppColors.primaryGreen,
                      onTap: _handleEditName,
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: AppColors.textPrimary.withOpacity(0.08),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Icon(
                            Icons.close,
                            size: 20,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: AppColors.borderLight.withOpacity(0.5)),
              // 하단: 전체 매니저 해제 (플랫 레드 텍스트 버튼, SubManager 시트와 동일 스타일)
              if (canRemove)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => _removeFullManager(context),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red,
                        backgroundColor: Colors.transparent,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        minimumSize: const Size(double.infinity, 56),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(0),
                        ),
                      ),
                      child: const Text(
                        '매니저 해제',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                  child: Text(
                    '마지막 전체 매니저는 해제할 수 없어요.',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
