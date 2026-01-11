import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../models/admin_models.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/member_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../services/member_service.dart';
import '../../../utils/snackbar_util.dart';

/// 멤버 수정 바텀시트
class MemberEditBottomSheet extends StatefulWidget {
  final MemberData existing;

  const MemberEditBottomSheet({super.key, required this.existing});

  static Future<void> show(
    BuildContext context, {
    required MemberData existing,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      builder: (context) => MemberEditBottomSheet(existing: existing),
    );
  }

  @override
  State<MemberEditBottomSheet> createState() => _MemberEditBottomSheetState();
}

class _MemberEditBottomSheetState extends State<MemberEditBottomSheet> {
  late final TextEditingController nameCtrl;
  late final TextEditingController phoneCtrl;
  late final Set<String> selectedCourseIds;

  @override
  void initState() {
    super.initState();
    nameCtrl = TextEditingController(text: widget.existing.name);
    phoneCtrl = TextEditingController(text: widget.existing.phoneNumber);
    selectedCourseIds = Set<String>.from(
      widget.existing.enrolledCourseIds ?? [],
    );
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StatefulBuilder(
      builder: (context, setState) {
        final bottomInset = MediaQuery.of(context).viewInsets.bottom;
        return Container(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(color: Colors.transparent),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: GestureDetector(
                  onTap: () {},
                  child: Container(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.9,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundWhite,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(30),
                        topRight: Radius.circular(30),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 32,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '멤버 수정',
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  Text(
                                    '수정하면 해당 멤버 정보가 업데이트됩니다',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                              const Spacer(),
                              IconButton(
                                icon: Icon(
                                  Icons.close,
                                  color: AppColors.textSecondary,
                                ),
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          TextField(
                            controller: nameCtrl,
                            style: TextStyle(
                              fontSize: 16,
                              color: AppColors.textPrimary,
                            ),
                            decoration: InputDecoration(
                              labelText: '이름',
                              labelStyle: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 16,
                              ),
                              filled: true,
                              fillColor: AppColors.backgroundLight,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: AppColors.borderLight,
                                  width: 1,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: AppColors.borderLight,
                                  width: 1,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: AppColors.primaryGreen,
                                  width: 1,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 16,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: phoneCtrl,
                            onChanged: (value) {
                              final digitsOnly = value.replaceAll(
                                RegExp(r'[^\d]'),
                                '',
                              );
                              String formatted = digitsOnly;
                              if (formatted.isEmpty) {
                                formatted = '010';
                              }
                              String result = '';
                              if (formatted.length <= 3) {
                                result = formatted;
                              } else if (formatted.length <= 7) {
                                result =
                                    '${formatted.substring(0, 3)}-${formatted.substring(3)}';
                              } else if (formatted.length <= 11) {
                                result =
                                    '${formatted.substring(0, 3)}-${formatted.substring(3, 7)}-${formatted.substring(7)}';
                              } else {
                                result =
                                    '${formatted.substring(0, 3)}-${formatted.substring(3, 7)}-${formatted.substring(7, 11)}';
                              }
                              if (phoneCtrl.text != result) {
                                phoneCtrl.value = TextEditingValue(
                                  text: result,
                                  selection: TextSelection.collapsed(
                                    offset: result.length,
                                  ),
                                );
                              }
                              setState(() {});
                            },
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(13),
                            ],
                            style: TextStyle(
                              fontSize: 16,
                              color: AppColors.textPrimary,
                            ),
                            decoration: InputDecoration(
                              labelText: '전화번호',
                              labelStyle: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 16,
                              ),
                              filled: true,
                              fillColor: AppColors.backgroundLight,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: AppColors.borderLight,
                                  width: 1,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: AppColors.borderLight,
                                  width: 1,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                  color: AppColors.primaryGreen,
                                  width: 1,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 16,
                              ),
                            ),
                          ),
                          // 코스 선택 섹션 (코스가 있을 때만 표시)
                          Builder(
                            builder: (context) {
                              final courseProvider =
                                  Provider.of<CourseProvider>(
                                    context,
                                    listen: false,
                                  );
                              if (courseProvider.courses.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 16),
                                  Text(
                                    '코스 선택',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  // 코스 선택 그리드 (코스 개수와 키보드 높이에 따라 동적 조정)
                                  Builder(
                                    builder: (context) {
                                      final keyboardHeight = MediaQuery.of(
                                        context,
                                      ).viewInsets.bottom;
                                      final courseCount =
                                          courseProvider.courses.length;
                                      // 코스 개수에 따라 기본 높이 계산
                                      // 2열 그리드, childAspectRatio 1.5 기준
                                      // 각 행의 높이 = (너비/2 - spacing) / 1.5 + mainAxisSpacing
                                      // 대략적으로 행당 80px 정도로 계산
                                      final rows = (courseCount / 2).ceil();
                                      final baseHeight = (rows * 80.0).clamp(
                                        80.0, // 최소 1행 높이
                                        300.0, // 최대 높이
                                      );
                                      // 키보드가 올라왔을 때 높이를 줄임 (최소 60px)
                                      final gridHeight =
                                          (baseHeight - keyboardHeight).clamp(
                                            60.0,
                                            baseHeight,
                                          );
                                      return SizedBox(
                                        height: gridHeight,
                                        child: GridView.builder(
                                          padding: const EdgeInsets.all(0),
                                          gridDelegate:
                                              const SliverGridDelegateWithFixedCrossAxisCount(
                                                crossAxisCount: 2,
                                                crossAxisSpacing: 4,
                                                mainAxisSpacing: 4,
                                                childAspectRatio: 1.5,
                                              ),
                                          itemCount:
                                              courseProvider.courses.length,
                                          itemBuilder: (context, index) {
                                            final course =
                                                courseProvider.courses[index];
                                            final isSelected = selectedCourseIds
                                                .contains(course.id);
                                            return GestureDetector(
                                              onTap: () {
                                                setState(() {
                                                  if (isSelected) {
                                                    selectedCourseIds.remove(
                                                      course.id,
                                                    );
                                                  } else {
                                                    selectedCourseIds.add(
                                                      course.id,
                                                    );
                                                  }
                                                });
                                              },
                                              child: AnimatedContainer(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                curve: Curves.easeInOut,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                      vertical: 12,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: isSelected
                                                      ? AppColors.textPrimary
                                                      : AppColors
                                                            .backgroundWhite,
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                  border: isSelected
                                                      ? null
                                                      : Border.all(
                                                          color: AppColors
                                                              .borderLight,
                                                          width: 1,
                                                        ),
                                                ),
                                                child: Center(
                                                  child: Text(
                                                    '',
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: isSelected
                                                          ? AppColors
                                                                .backgroundWhite
                                                          : AppColors
                                                                .textPrimary,
                                                    ),
                                                    textAlign: TextAlign.center,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 24),
                          Builder(
                            builder: (context) {
                              final name = nameCtrl.text.trim();
                              final phoneNumber = phoneCtrl.text.trim();
                              final phoneDigitsOnly = phoneNumber.replaceAll(
                                RegExp(r'[^\d]'),
                                '',
                              );
                              final isPhoneValid = phoneDigitsOnly.length == 11;
                              // 이름과 전화번호만 필수, 코스 선택은 선택사항
                              final isEnabled =
                                  name.isNotEmpty &&
                                  phoneNumber.isNotEmpty &&
                                  isPhoneValid;

                              return SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: isEnabled
                                      ? () async {
                                          await _updateMember(
                                            context,
                                            nameCtrl.text.trim(),
                                            phoneCtrl.text.trim(),
                                            selectedCourseIds,
                                          );
                                          Navigator.of(context).pop();
                                        }
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isEnabled
                                        ? AppColors.primaryGreen
                                        : AppColors.textSecondary.withOpacity(
                                            0.3,
                                          ),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    elevation: 0,
                                    disabledBackgroundColor: AppColors
                                        .textPrimary
                                        .withOpacity(0.1),
                                  ),
                                  child: Text(
                                    '저장',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 멤버 정보 업데이트 (Firebase 연동)
  Future<void> _updateMember(
    BuildContext context,
    String name,
    String phoneNumber,
    Set<String> selectedCourseIds,
  ) async {
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;

    if (placeId == null) {
      SnackbarUtil.showError(context, '플레이스를 선택해주세요.');
      return;
    }

    try {
      final memberService = MemberService();
      final updatedUser = await memberService.updateMember(
        phoneNumber: phoneNumber,
        name: name,
        placeId: placeId,
        selectedCourseIds: selectedCourseIds,
        courses: courseProvider.courses,
      );

      if (updatedUser == null) {
        SnackbarUtil.showError(context, '멤버를 찾을 수 없습니다.');
        return;
      }

      SnackbarUtil.showSuccess(context, '멤버 정보가 업데이트되었습니다.');

      // 멤버 목록 새로고침
      await memberProvider.loadMembers(placeId);
    } catch (e) {
      SnackbarUtil.showError(context, '멤버 정보 업데이트 중 오류가 발생했습니다: $e');
    }
  }
}
