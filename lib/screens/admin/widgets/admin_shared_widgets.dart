import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/cached_image_widget.dart';
import '../../../models/admin_models.dart';
import '../../../models/course.dart' as reservation_models;
import '../../../models/place.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/member_provider.dart';
import '../../../services/reservation_service.dart';
import '../../../services/auth_service.dart';
import '../../../utils/snackbar_util.dart';
import 'member_detail_bottom_sheet.dart';

// ===== 공유 UI 컴포넌트 =====

class SectionHeader extends StatelessWidget {
  final String title;
  final double horizontalPadding;
  final Widget? icon;
  final VoidCallback? onIconTap;
  final double? fontSize;

  const SectionHeader({
    super.key,
    required this.title,
    this.horizontalPadding = 20,
    this.icon,
    this.onIconTap,
    this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Row(
        children: [
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: fontSize ?? 22,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryGreen,
            ),
          ),
          const Spacer(),
          if (icon != null && onIconTap != null)
            IconButton(onPressed: onIconTap, icon: icon!),
        ],
      ),
    );
  }
}

class EmptyHint extends StatelessWidget {
  final String text;
  const EmptyHint({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.backgroundWhite,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Text(text, style: TextStyle(color: AppColors.textSecondary)),
      ),
    );
  }
}

class EditablePreview extends StatelessWidget {
  final Widget child;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const EditablePreview({
    super.key,
    required this.child,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        child,
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('수정'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('삭제'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class BottomSheetScaffold extends StatelessWidget {
  final String title;
  final VoidCallback onSave;
  final Widget child;

  const BottomSheetScaffold({
    super.key,
    required this.title,
    required this.onSave,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('닫기'),
                ),
                FilledButton(onPressed: onSave, child: const Text('저장')),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class AdminTextField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final int maxLines;
  final TextInputType? keyboardType;

  const AdminTextField({
    super.key,
    required this.label,
    required this.controller,
    this.maxLines = 1,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class IconPicker extends StatelessWidget {
  final IconData value;
  final ValueChanged<IconData> onChanged;

  const IconPicker({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final icons = <IconData>[
      Icons.notifications,
      Icons.info,
      Icons.celebration,
      Icons.campaign,
      Icons.warning_amber,
    ];
    return DropdownButtonFormField<IconData>(
      value: value,
      decoration: const InputDecoration(
        labelText: '아이콘',
        border: OutlineInputBorder(),
      ),
      items:
          icons
              .map(
                (i) => DropdownMenuItem(
                  value: i,
                  child: Row(
                    children: [
                      Icon(i, size: 18),
                      const SizedBox(width: 8),
                      Text(i.toString().split('.').last),
                    ],
                  ),
                ),
              )
              .toList(),
      onChanged: (v) {
        if (v == null) return;
        onChanged(v);
      },
    );
  }
}

class ColorPicker extends StatelessWidget {
  final String label;
  final Color? value;
  final List<Color?> colors;
  final ValueChanged<Color?> onChanged;

  const ColorPicker({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in colors)
              GestureDetector(
                onTap: () => onChanged(c),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: c ?? Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color:
                          value == c
                              ? AppColors.primaryGreen
                              : AppColors.borderLight,
                      width: value == c ? 2 : 1,
                    ),
                  ),
                  child:
                      c == null
                          ? Icon(Icons.block, color: AppColors.textSecondary)
                          : null,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class IntColorPicker extends StatelessWidget {
  final String label;
  final int value;
  final List<int> colors;
  final ValueChanged<int> onChanged;

  const IntColorPicker({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in colors)
              GestureDetector(
                onTap: () => onChanged(c),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Color(c),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color:
                          value == c
                              ? AppColors.primaryGreen
                              : AppColors.borderLight,
                      width: value == c ? 2 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class ReservationCourseCard extends StatelessWidget {
  final reservation_models.Course course;
  final VoidCallback onTap; // 자세히 보기 콜백

  const ReservationCourseCard({
    super.key,
    required this.course,
    required this.onTap,
  });

  // 총 수강생 수 계산 (모든 세션의 예약에서 고유한 userId 수)
  int _getTotalStudentCount(reservation_models.Course course) {
    final userIds = <String>{};
    for (final session in course.sessions) {
      for (final reservation in session.reservations) {
        userIds.add(reservation.userId);
      }
    }
    return userIds.length;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: AppColors.backgroundWhite,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            // 왼쪽 이미지
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CourseImageWidget(
                imageUrl: course.imageUrl,
                width: 100,
                height: 100,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(width: 16),
            // 오른쪽 콘텐츠
            Expanded(
              child: SizedBox(
                height: 110, // 이미지 높이와 동일하게 고정
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // 상단 콘텐츠
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 코스 이름
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                course.name,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        if (!course.description.isNotEmpty)
                          Text(
                            '${_getTotalStudentCount(course)}명 수강',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        if (course.description.isNotEmpty) ...[
                          Text(
                            course.description,
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),

                    // 자세히 버튼 (오른쪽 정렬)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primaryGreen,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  '자세히',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.backgroundWhite,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.arrow_forward_ios,
                                size: 14,
                                color: AppColors.backgroundWhite,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 연장 요청 정보
class ExtensionRequestInfo {
  final int count;
  final List<String> courseNames;

  ExtensionRequestInfo({required this.count, required this.courseNames});
}

class MemberCard extends StatefulWidget {
  final MemberData member;
  final VoidCallback? onMemberTapped;
  final Color? backgroundColor;
  final ExtensionRequestInfo? extensionRequestInfo;

  const MemberCard({
    super.key,
    required this.member,
    this.onMemberTapped,
    this.backgroundColor,
    this.extensionRequestInfo,
  });

  @override
  State<MemberCard> createState() => _MemberCardState();
}

class _MemberCardState extends State<MemberCard> {
  bool _isCopied = false;

  String _formatPhoneNumber(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length <= 3) {
      return digits;
    } else if (digits.length <= 7) {
      return '${digits.substring(0, 3)}-${digits.substring(3)}';
    } else if (digits.length <= 11) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7)}';
    } else {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7, 11)}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasRequests = widget.member.hasPendingRequests;
    final memberProvider = Provider.of<MemberProvider>(context);
    final isDeleting = memberProvider.isDeletingMember(widget.member.userId);

    return GestureDetector(
      onTap:
          isDeleting
              ? null // 삭제 중일 때는 탭 비활성화
              : () {
                // 최근 본 멤버 추가 콜백 호출
                widget.onMemberTapped?.call();
                MemberDetailBottomSheet.show(
                  context: context,
                  member: widget.member,
                );
              },
      child: Stack(
        children: [
          Opacity(
            opacity: isDeleting ? 0.7 : 1.0, // 삭제 중일 때 살짝만 반투명
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: widget.backgroundColor ?? AppColors.backgroundWhite,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.member.name,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                            if (!isDeleting &&
                                (widget.member.needsReenrollment == true ||
                                    hasRequests))
                              Container(
                                margin: const EdgeInsets.only(right: 8),
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),

                        Row(
                          children: [
                            Text(
                              _formatPhoneNumber(widget.member.phoneNumber),
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () {
                                Clipboard.setData(
                                  ClipboardData(
                                    text: widget.member.phoneNumber,
                                  ),
                                );
                                setState(() {
                                  _isCopied = true;
                                });
                                // 스낵바 표시
                                SnackbarUtil.showSuccess(
                                  context,
                                  '클립보드에 복사되었습니다',
                                );
                                // 2초 후 원래 아이콘으로 복귀
                                Future.delayed(const Duration(seconds: 2), () {
                                  if (mounted) {
                                    setState(() {
                                      _isCopied = false;
                                    });
                                  }
                                });
                              },
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                child: Icon(
                                  _isCopied ? Icons.check : Icons.copy,
                                  key: ValueKey(_isCopied),
                                  size: 16,
                                  color:
                                      _isCopied
                                          ? AppColors.primaryGreen
                                          : AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                  // Forward icon
                  Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: AppColors.textSecondary.withOpacity(0.5),
                  ),
                ],
              ),
            ),
          ),
          if (isDeleting)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  color: Colors.black.withOpacity(0.08),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primaryGreen,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '삭제중…',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class Chip extends StatelessWidget {
  final String text;
  const Chip({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Text(
        text,
        style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
      ),
    );
  }
}

// 삭제 확인 다이얼로그
Future<void> confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
  required VoidCallback onConfirm,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder:
        (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('삭제'),
            ),
          ],
        ),
  );
  if (ok == true) onConfirm();
}

/// 관리자 플레이스 선택 위젯 (공통)
class AdminPlaceSelector extends StatefulWidget {
  final VoidCallback? onEditTap;
  final Future<List<Place>> Function()? loadPlaces;
  final Widget? trailing; // 끝에 표시할 위젯 (아이콘, 배지 등)
  final VoidCallback? onTrailingTap; // 끝 위젯 클릭 콜백
  final bool showDescription;

  const AdminPlaceSelector({
    super.key,
    this.onEditTap,
    this.loadPlaces,
    this.trailing,
    this.onTrailingTap,
    this.showDescription = false,
  });

  @override
  State<AdminPlaceSelector> createState() => _AdminPlaceSelectorState();
}

class _AdminPlaceSelectorState extends State<AdminPlaceSelector> {
  bool _isPlaceListExpanded = false;

  List<Place> _getPlaces() {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);

    if (authProvider.currentAdmin == null) {
      return [];
    }

    final admin = authProvider.currentAdmin!;

    // 관리자가 관리하는 모든 플레이스 가져오기 (이미 로드된 것만)
    return admin.placeIds
        .map((placeId) => placeProvider.getPlace(placeId))
        .whereType<Place>()
        .toList();
  }

  Future<void> _switchPlace(BuildContext context, Place newPlace) async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final admin = authProvider.currentAdmin;

    if (admin == null) {
      return;
    }

    // 관리자가 해당 플레이스를 관리하는지 확인
    if (!admin.placeIds.contains(newPlace.id)) {
      return;
    }

    try {
      // PlaceProvider 업데이트
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      placeProvider.setCurrentPlace(newPlace);

      // ReservationService 업데이트
      final reservationService = ReservationService();
      reservationService.setPlace(newPlace);

      // AuthService에 마지막 접속 플레이스 저장
      final authService = AuthService();
      await authService.updateLastAccessedPlace(newPlace.id);

      if (mounted) {
        setState(() {
          _isPlaceListExpanded = false;
        });
      }
    } catch (e) {
      // 에러 처리
      if (mounted) {
        SnackbarUtil.showInfo(context, '플레이스 전환 중 오류가 발생했습니다: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        final placeProvider = Provider.of<PlaceProvider>(context);
        final authProvider = Provider.of<AuthProvider>(context);
        final currentPlace = placeProvider.currentPlace;
        final admin = authProvider.currentAdmin;

        // 플레이스가 없으면 빈 섹션 표시
        if (currentPlace == null) {
          return const SizedBox.shrink();
        }

        final placeName = currentPlace.name;
        final descriptionText =
            (currentPlace.description ?? currentPlace.location ?? '').trim();
        final showDescriptionLine =
            widget.showDescription && descriptionText.isNotEmpty;
        final hasMultiplePlaces = admin != null && admin.placeIds.length > 1;
        final currentPlaceId = currentPlace.id;
        final places = _getPlaces();

        return Padding(
          padding: const EdgeInsets.only(left: 20, right: 10, top: 10),
          child: Column(
            children: [
              // 플레이스 정보 (클릭 가능)
              InkWell(
                onTap:
                    hasMultiplePlaces
                        ? () {
                          setState(() {
                            _isPlaceListExpanded = !_isPlaceListExpanded;
                          });
                        }
                        : null,
                borderRadius: BorderRadius.circular(16),
                child: Row(
                  children: [
                    // 플레이스 이미지
                    PlaceImageWidget(
                      imageUrl: currentPlace.imageUrl,
                      width: 46,
                      height: 46,
                    ),
                    const SizedBox(width: 16),
                    // 플레이스 이름
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            placeName,
                            style: TextStyle(
                              fontSize: showDescriptionLine ? 18 : 20,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.5,
                            ),
                          ),
                          if (showDescriptionLine) ...[
                            Text(
                              descriptionText,
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),

                    if (hasMultiplePlaces)
                      Icon(
                        _isPlaceListExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: AppColors.textSecondary,
                        size: 24,
                      ),
                    if (widget.trailing != null) ...[
                      const SizedBox(width: 16),
                      widget.onTrailingTap != null
                          ? IconButton(
                            color: AppColors.textSecondary,
                            iconSize: 24,
                            onPressed: widget.onTrailingTap,
                            icon: widget.trailing!,
                          )
                          : widget.trailing!,
                    ],
                  ],
                ),
              ),

              // 플레이스 리스트 (펼쳐질 때)
              if (_isPlaceListExpanded && hasMultiplePlaces) ...[
                const SizedBox(height: 12),
                Column(
                  children:
                      places.map((place) {
                        final isCurrentPlace = place.id == currentPlaceId;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: InkWell(
                            onTap:
                                isCurrentPlace
                                    ? null
                                    : () => _switchPlace(context, place),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    isCurrentPlace
                                        ? AppColors.primaryGreen.withOpacity(
                                          0.1,
                                        )
                                        : AppColors.backgroundWhite,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color:
                                      isCurrentPlace
                                          ? AppColors.primaryGreen
                                          : AppColors.textSecondary.withOpacity(
                                            0.2,
                                          ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      place.name,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                        color:
                                            isCurrentPlace
                                                ? AppColors.primaryGreen
                                                : AppColors.textPrimary,
                                      ),
                                    ),
                                  ),
                                  if (isCurrentPlace)
                                    Icon(
                                      Icons.check_circle,
                                      color: AppColors.primaryGreen,
                                      size: 20,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
