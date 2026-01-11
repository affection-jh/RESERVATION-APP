import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:provider/provider.dart';
import 'package:reservation/services/user_service.dart';
import 'package:reservation/widgets/story_card.dart';
import 'dart:io';
import '../../../theme/app_colors.dart';

import '../../../widgets/cached_image_widget.dart';
import '../../../screens/admin_screen.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/storage_service.dart';
import '../../../utils/snackbar_util.dart';

class AdminGreetingSettingScreen extends StatefulWidget {
  final String placeName;
  final String placeLocation;
  final File? placeImage;
  final String? placeImageUrl; // 이미 업로드된 이미지 URL

  const AdminGreetingSettingScreen({
    super.key,
    required this.placeName,
    required this.placeLocation,
    this.placeImage,
    this.placeImageUrl,
  });

  @override
  State<AdminGreetingSettingScreen> createState() =>
      _AdminGreetingSettingScreenState();
}

class _AdminGreetingSettingScreenState
    extends State<AdminGreetingSettingScreen> {
  final TextEditingController _greetingTextController = TextEditingController(
    text: '',
  );
  final FocusNode _greetingFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // 포커스 상태 변경 감지
    _greetingFocusNode.addListener(() {
      setState(() {});
    });
    // 화면 진입 시 인사말 필드에 포커스
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _greetingFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _greetingTextController.dispose();
    _greetingFocusNode.dispose();
    super.dispose();
  }

  void _removeFocus() {
    _greetingFocusNode.unfocus();
  }

  bool _isFormValid() {
    return _greetingTextController.text.trim().isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 메인 콘텐츠  // 뒤로가기 버튼
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: IconButton(
                    onPressed: () {
                      _removeFocus();
                      Navigator.of(context).pop();
                    },
                    icon: Icon(
                      Icons.arrow_back_ios,
                      color: AppColors.primaryGreen,
                      size: 24,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 12),

                        // 제목
                        _buildTitle(),

                        const SizedBox(height: 24),

                        // 미리보기 섹션 (인라인 편집)
                        _buildStorySection(),

                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),

                // 하단 버튼
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  child: _buildBottomButtons(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 플레이스 이미지 위젯
  Widget _buildPlaceImage() {
    if (widget.placeImage != null) {
      // 로컬 이미지 파일이 있는 경우
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.file(
          widget.placeImage!,
          width: 46,
          height: 46,
          fit: BoxFit.cover,
        ),
      );
    } else {
      // URL이 있는 경우
      return PlaceImageWidget(
        imageUrl: widget.placeImageUrl,
        width: 46,
        height: 46,
      );
    }
  }

  // 제목
  Widget _buildTitle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '인사말을 설정해 주세요',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '멤버들에게 보여질 텍스트를 수정할 수 있어요',
          style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  // 미리보기 섹션
  Widget _buildStorySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.backgroundLight,
            borderRadius: BorderRadius.circular(16),

            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white,
                Colors.white,
                Colors.white.withOpacity(0.0),
              ],
              stops: const [0.0, 0.2, 0.8],
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: _buildHomePreview(),
          ),
        ),
      ],
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      color: AppColors.backgroundLight,
      child: Row(
        children: [
          // 플레이스 이미지
          _buildPlaceImage(),
          const SizedBox(width: 6),
          // 플레이스 이름과 위치
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.placeName,
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
            hintText: '안녕하세요,\n${widget.placeName}입니다',
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
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () {
              _removeFocus();
              Navigator.of(context).pop();
            },
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
                color: AppColors.primaryGreen,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: FilledButton(
            onPressed: _isFormValid()
                ? () async {
                    _removeFocus();

                    try {
                      final authProvider = Provider.of<AuthProvider>(
                        context,
                        listen: false,
                      );
                      final placeProvider = Provider.of<PlaceProvider>(
                        context,
                        listen: false,
                      );

                      if (authProvider.currentAdmin == null) {
                        SnackbarUtil.showError(context, '관리자 정보를 찾을 수 없습니다.');
                        return;
                      }

                      final admin = authProvider.currentAdmin!;

                      // 베타 버전 제약: 이미 플레이스가 있으면 등록 불가
                      if (admin.placeIds.isNotEmpty) {
                        SnackbarUtil.showError(
                          context,
                          '베타 버전에서는 전화번호 하나당 플레이스 하나만 등록할 수 있습니다.',
                        );
                        return;
                      }

                      // 이미지 URL 처리 (이미 업로드된 경우 URL 사용, 아니면 업로드)
                      String? imageUrl = widget.placeImageUrl;
                      if (imageUrl == null && widget.placeImage != null) {
                        try {
                          final storageService = StorageService();
                          imageUrl = await storageService.uploadImage(
                            imageFile: widget.placeImage!,
                            folder: 'places',
                          );
                        } catch (e) {
                          if (mounted) {
                            SnackbarUtil.showError(
                              context,
                              '이미지 업로드에 실패했습니다: ${e.toString()}',
                            );
                          }
                          return;
                        }
                      }

                      // 플레이스 생성
                      final place = await placeProvider.createPlace(
                        name: widget.placeName,
                        location: widget.placeLocation,
                        appBarText: widget.placeName,
                        greetingText: _greetingTextController.text.trim(),
                        imageUrl: imageUrl,
                        adminId: admin.userId,
                      );

                      // 관리자의 placeIds에 추가
                      final updatedAdmin = admin.addPlace(place.id);
                      final userService = UserService();
                      await userService.updateAdmin(updatedAdmin);

                      // AuthProvider 업데이트
                      authProvider.setCurrentAdmin(updatedAdmin);

                      // 관리자 홈 화면으로 이동 (모든 이전 화면 제거)
                      if (mounted) {
                        Navigator.of(context).pushAndRemoveUntil(
                          MaterialPageRoute(
                            builder: (context) => const AdminScreen(),
                          ),
                          (route) => false,
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        final errorMessage = e.toString().replaceAll(
                          'Exception: ',
                          '',
                        );
                        SnackbarUtil.showError(context, errorMessage);
                      }
                    }
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
              '시작하기',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
