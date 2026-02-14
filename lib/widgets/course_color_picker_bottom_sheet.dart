import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';

/// 코스 색상 선택 바텀시트
class CourseColorPickerBottomSheet extends StatefulWidget {
  final int initialColor;
  final ValueChanged<int>? onColorChanged; // 색상 선택 시 즉시 콜백

  const CourseColorPickerBottomSheet({
    super.key,
    required this.initialColor,
    this.onColorChanged,
  });

  @override
  State<CourseColorPickerBottomSheet> createState() =>
      _CourseColorPickerBottomSheetState();

  /// 색상 int 값으로 onColor 찾기
  static Color getOnColorForColor(int colorInt) {
    final color = Color(colorInt);

    // 모든 팔레트에서 해당 색상 찾기
    for (final palette
        in _CourseColorPickerBottomSheetState._colorPalettes.values) {
      for (final colorData in palette) {
        final paletteColor = colorData['color'] as Color;
        if (paletteColor.value == colorInt) {
          return colorData['onColor'] as Color;
        }
      }
    }

    // 찾지 못한 경우 기본값 (luminance 기반)
    return color.computeLuminance() > 0.5
        ? AppColors.textPrimary
        : Colors.white;
  }
}

class _CourseColorPickerBottomSheetState
    extends State<CourseColorPickerBottomSheet>
    with TickerProviderStateMixin {
  late TabController _tabController;
  late PageController _palettePageController;
  int _selectedColor = 0xFF006644;

  // 색상 팔레트 (static으로 변경하여 외부에서 접근 가능하게)
  static final Map<String, List<Map<String, dynamic>>> _colorPalettes = {
    'Romantic Reds': [
      {
        'color': Color.fromARGB(255, 85, 13, 13),
        'onColor': Colors.white,
        'code': '#450A0A',
        'intensity': 100,
      }, // 다크 레드
      {
        'color': Color(0xFF7F1D1D),
        'onColor': Colors.white,
        'code': '#7F1D1D',
        'intensity': 200,
      }, // 딥 레드
      {
        'color': Color(0xFF991B1B),
        'onColor': Colors.white,
        'code': '#991B1B',
        'intensity': 300,
      }, // 크림슨
      {
        'color': Color(0xFFDC2626),
        'onColor': Colors.white,
        'code': '#DC2626',
        'intensity': 400,
      }, // 체리 레드
      {
        'color': Color(0xFFEF4444),
        'onColor': Colors.white,
        'code': '#EF4444',
        'intensity': 500,
      }, // 브라이트 레드
      {
        'color': Color(0xFFF87171),
        'onColor': AppColors.textPrimary,
        'code': '#F87171',
        'intensity': 600,
      }, // 코랄 레드
      {
        'color': Color(0xFFFCA5A5),
        'onColor': Colors.white,
        'code': '#FCA5A5',
        'intensity': 700,
      }, // 로즈 레드
    ],
    'Modern Grays': [
      {
        'color': Color(0xFF0F0F23),
        'onColor': Colors.white,
        'code': '#0F0F23',
        'intensity': 100,
      }, // 거의 블랙
      {
        'color': Color(0xFF111827),
        'onColor': Colors.white,
        'code': '#111827',
        'intensity': 200,
      }, // 차콜 그레이
      {
        'color': Color(0xFF374151),
        'onColor': Colors.white,
        'code': '#374151',
        'intensity': 300,
      }, // 슬레이트 그레이
      {
        'color': Color(0xFF4B5563),
        'onColor': Colors.white,
        'code': '#4B5563',
        'intensity': 400,
      }, // 쿨 그레이
      {
        'color': Color(0xFF6B7280),
        'onColor': Colors.white,
        'code': '#6B7280',
        'intensity': 500,
      }, // 미디엄 그레이
      {
        'color': Color(0xFF9CA3AF),
        'onColor': AppColors.textPrimary,
        'code': '#9CA3AF',
        'intensity': 600,
      }, // 라이트 그레이
      {
        'color': Color(0xFFD1D5DB),
        'onColor': AppColors.textPrimary,
        'code': '#D1D5DB',
        'intensity': 700,
      }, // 실버 그레이
    ],
    'Nature Greens': [
      {
        'color': Color(0xFF064E3B),
        'onColor': Colors.white,
        'code': '#064E3B',
        'intensity': 100,
      }, // 다크 포레스트
      {
        'color': Color(0xFF14532D),
        'onColor': Colors.white,
        'code': '#14532D',
        'intensity': 200,
      }, // 포레스트 그린
      {
        'color': Color(0xFF166534),
        'onColor': Colors.white,
        'code': '#166534',
        'intensity': 300,
      }, // 딥 그린
      {
        'color': Color(0xFF15803D),
        'onColor': Colors.white,
        'code': '#15803D',
        'intensity': 400,
      }, // 에메랄드 그린
      {
        'color': Color(0xFF22C55E),
        'onColor': Colors.white,
        'code': '#22C55E',
        'intensity': 500,
      }, // 프레시 그린
      {
        'color': Color(0xFF4ADE80),
        'onColor': AppColors.textPrimary,
        'code': '#4ADE80',
        'intensity': 600,
      }, // 라임 그린
      {
        'color': Color(0xFF86EFAC),
        'onColor': AppColors.textPrimary,
        'code': '#86EFAC',
        'intensity': 700,
      }, // 라이트 그린
    ],
    'Ocean Blues': [
      {
        'color': Color(0xFF0F172A),
        'onColor': Colors.white,
        'code': '#0F172A',
        'intensity': 100,
      }, // 미드나잇 네이비
      {
        'color': Color(0xFF1E3A8A),
        'onColor': Colors.white,
        'code': '#1E3A8A',
        'intensity': 200,
      }, // 네이비 블루
      {
        'color': Color(0xFF1E40AF),
        'onColor': Colors.white,
        'code': '#1E40AF',
        'intensity': 300,
      }, // 딥 블루
      {
        'color': Color(0xFF2563EB),
        'onColor': Colors.white,
        'code': '#2563EB',
        'intensity': 400,
      }, // 로얄 블루
      {
        'color': Color(0xFF3B82F6),
        'onColor': Colors.white,
        'code': '#3B82F6',
        'intensity': 500,
      }, // 브라이트 블루
      {
        'color': Color(0xFF60A5FA),
        'onColor': AppColors.textPrimary,
        'code': '#60A5FA',
        'intensity': 600,
      }, // 스카이 블루
      {
        'color': Color(0xFF93C5FD),
        'onColor': AppColors.textPrimary,
        'code': '#93C5FD',
        'intensity': 700,
      }, // 라이트 블루
    ],
    'Royal Purples': [
      {
        'color': Color(0xFF2E1065),
        'onColor': Colors.white,
        'code': '#2E1065',
        'intensity': 100,
      }, // 다크 퍼플
      {
        'color': Color(0xFF4C1D95),
        'onColor': Colors.white,
        'code': '#4C1D95',
        'intensity': 200,
      }, // 딥 퍼플
      {
        'color': Color(0xFF5B21B6),
        'onColor': Colors.white,
        'code': '#5B21B6',
        'intensity': 300,
      }, // 로얄 퍼플
      {
        'color': Color(0xFF7C3AED),
        'onColor': Colors.white,
        'code': '#7C3AED',
        'intensity': 400,
      }, // 바이올렛
      {
        'color': Color(0xFF8B5CF6),
        'onColor': Colors.white,
        'code': '#8B5CF6',
        'intensity': 500,
      }, // 라벤더 퍼플
      {
        'color': Color(0xFFA78BFA),
        'onColor': AppColors.textPrimary,
        'code': '#A78BFA',
        'intensity': 600,
      }, // 소프트 퍼플
      {
        'color': Color(0xFFC4B5FD),
        'onColor': AppColors.textPrimary,
        'code': '#C4B5FD',
        'intensity': 700,
      }, // 라이트 퍼플
    ],
    'Sunset Oranges': [
      {
        'color': Color(0xFF7C2D12),
        'onColor': Colors.white,
        'code': '#7C2D12',
        'intensity': 100,
      }, // 다크 오렌지
      {
        'color': Color(0xFF9A3412),
        'onColor': Colors.white,
        'code': '#9A3412',
        'intensity': 200,
      }, // 딥 오렌지
      {
        'color': Color(0xFFEA580C),
        'onColor': Colors.white,
        'code': '#EA580C',
        'intensity': 300,
      }, // 탠저린
      {
        'color': Color(0xFFF97316),
        'onColor': Colors.white,
        'code': '#F97316',
        'intensity': 400,
      }, // 브라이트 오렌지
      {
        'color': Color(0xFFFB923C),
        'onColor': AppColors.textPrimary,
        'code': '#FB923C',
        'intensity': 500,
      }, // 선셋 오렌지
      {
        'color': Color(0xFFFDAB6D),
        'onColor': AppColors.textPrimary,
        'code': '#FDAB6D',
        'intensity': 600,
      }, // 피치 오렌지
      {
        'color': Color(0xFFFED7AA),
        'onColor': AppColors.textPrimary,
        'code': '#FED7AA',
        'intensity': 700,
      }, // 라이트 오렌지
    ],
  };

  @override
  void initState() {
    super.initState();
    _selectedColor = widget.initialColor;

    // 탭 컨트롤러 초기화
    _tabController = TabController(length: _colorPalettes.length, vsync: this);

    // 첫 번째 탭(Romantic Reds)부터 시작
    _tabController.index = 0;

    // 팔레트 페이지 컨트롤러 초기화
    _palettePageController = PageController(initialPage: 0);
  }

  @override
  void dispose() {
    _palettePageController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _saveAndClose() {
    Navigator.pop(context, _selectedColor);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    final isLandscape = screenWidth > screenHeight;

    return Container(
      constraints: BoxConstraints(
        maxHeight: isLandscape ? screenHeight * 0.95 : screenHeight * 0.85,
      ),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 핸들
          Container(
            margin: EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.borderLight,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // 헤더
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Spacer(),
                IconButton(
                  onPressed: () => _saveAndClose(),
                  icon: Icon(Icons.close, color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
          SizedBox(height: 10),

          // 스크롤 가능한 콘텐츠
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  // 색상 카테고리 탭
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 0),
                    child: SizedBox(
                      height: 40,
                      child: TabBar(
                        dividerColor: Colors.transparent,
                        controller: _tabController,
                        isScrollable: true,

                        onTap: (index) {
                          setState(() {});
                          // 팔레트 PageView도 해당 페이지로 이동
                          _palettePageController.animateToPage(
                            index,
                            duration: Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        },
                        tabs: _colorPalettes.keys
                            .map((category) => Tab(text: category))
                            .toList(),
                      ),
                    ),
                  ),

                  SizedBox(height: 20),

                  // 색상 팔레트 (스와이프 가능)
                  SizedBox(
                    height: isLandscape ? 140 : 280,
                    child: PageView.builder(
                      controller: _palettePageController,
                      onPageChanged: (index) {
                        setState(() {
                          _tabController.animateTo(index);
                        });
                      },
                      itemCount: _colorPalettes.length,
                      itemBuilder: (context, index) {
                        final categoryName = _colorPalettes.keys.elementAt(
                          index,
                        );
                        return Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          child: _buildColorPaletteForCategory(
                            categoryName,
                            isLandscape,
                          ),
                        );
                      },
                    ),
                  ),

                  SizedBox(height: 30),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorPaletteForCategory(String categoryName, bool isLandscape) {
    final colors = _colorPalettes[categoryName]!;
    final rows = isLandscape ? 1 : 2;
    final colorsPerRow = (colors.length / rows).ceil();

    return Column(
      children: List.generate(rows, (rowIndex) {
        final startIndex = rowIndex * colorsPerRow;
        final endIndex = (startIndex + colorsPerRow).clamp(0, colors.length);
        final rowColors = colors.sublist(startIndex, endIndex);

        return Container(
          height: isLandscape ? 120 : 100,
          margin: EdgeInsets.only(bottom: rowIndex < rows - 1 ? 8 : 0),
          child: Row(
            children: rowColors.map((colorData) {
              final color = colorData['color'] as Color;
              final code = colorData['code'] as String;
              final colorInt = color.value;
              final isSelected = colorInt == _selectedColor;
              final isLight = color.computeLuminance() > 0.5;

              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedColor = colorInt;
                    });
                    HapticFeedback.lightImpact();
                    // 색상 선택 시 즉시 콜백 호출하여 상위 화면 업데이트
                    widget.onColorChanged?.call(colorInt);
                  },
                  child: AnimatedScale(
                    scale: isSelected ? 1.15 : 1.0,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    child: Container(
                      margin: EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Spacer(),
                            Text(
                              code,
                              style: TextStyle(
                                color: isLight
                                    ? Colors.black54
                                    : Colors.white70,
                                fontSize: isLandscape ? 9 : 10,
                                fontFamily: 'Courier',
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );
      }),
    );
  }
}

/// 코스 색상 선택 바텀시트 표시
void showCourseColorPickerBottomSheet(
  BuildContext context,
  int initialColor,
  ValueChanged<int> onColorSelected,
) {
  int? currentSelectedColor = initialColor;

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.1),
    useSafeArea: true,
    builder: (context) => CourseColorPickerBottomSheet(
      initialColor: initialColor,
      onColorChanged: (color) {
        // 색상 선택 시 즉시 상위 화면 업데이트
        currentSelectedColor = color;
        onColorSelected(color);
      },
    ),
  ).then((selectedColor) {
    // 바텀시트가 닫힐 때 최종 선택된 색상 전달 (이미 업데이트되었지만 일관성을 위해)
    if (selectedColor != null && selectedColor != currentSelectedColor) {
      onColorSelected(selectedColor);
    }
  });
}
