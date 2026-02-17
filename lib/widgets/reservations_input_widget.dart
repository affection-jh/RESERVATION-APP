import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';

/// 수업 횟수 지정 입력 위젯
///
/// [controller] 텍스트 입력 컨트롤러
/// [currentValue] 현재 값
/// [defaultValue] 기본값 (hint에 표시)
/// [onChanged] 값 변경 콜백
/// [enabled] 활성화 여부 (false면 회색 처리)
/// [maxValue] 최대값 (기본값: 999)
/// [minValue] 최소값 (기본값: 0)
/// [hideLabel] 라벨 숨김 여부 (기본값: false)
class ReservationsInputWidget extends StatelessWidget {
  final TextEditingController controller;
  final int currentValue;
  final int defaultValue;
  final ValueChanged<int> onChanged;
  final bool enabled;
  final int maxValue;
  final int minValue;
  final bool hideLabel;

  const ReservationsInputWidget({
    super.key,
    required this.controller,
    required this.currentValue,
    required this.defaultValue,
    required this.onChanged,
    this.enabled = true,
    this.maxValue = 999,
    this.minValue = 0,
    this.hideLabel = false,
  });

  @override
  Widget build(BuildContext context) {
    // controller 동기화 - 0일 때는 빈 텍스트로 표시
    final expectedText = currentValue == 0 ? '' : currentValue.toString();
    if (controller.text != expectedText) {
      controller.text = expectedText;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!hideLabel) ...[
          Text(
            '수업 횟수 지정',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color:
                  enabled
                      ? AppColors.textSecondary
                      : AppColors.textSecondary.withOpacity(0.4),
            ),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: 100,
          height: 46,
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(3),
            ],
            textAlign: TextAlign.center,
            enabled: enabled,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color:
                  !enabled
                      ? AppColors.textSecondary.withOpacity(0.4)
                      : AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 0,
              ),
              filled: true,
              fillColor:
                  enabled
                      ? AppColors.backgroundLight
                      : AppColors.backgroundLight.withOpacity(0.5),
              hintText: '0',
              hintStyle: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary.withOpacity(0.4),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.borderLight, width: 0),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.borderLight, width: 0),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: AppColors.borderLight.withOpacity(0.5),
                  width: 1,
                ),
              ),
            ),
            onChanged: (value) {
              if (value.isEmpty) {
                // 빈 값이면 minValue로 설정하되 텍스트는 빈 상태 유지
                onChanged(minValue);
              } else {
                final total = int.tryParse(value);
                if (total != null && total >= minValue && total <= maxValue) {
                  onChanged(total);
                }
              }
            },
            onSubmitted: (value) {
              if (value.isEmpty) {
                // 빈 값이면 minValue로 설정하되 텍스트는 빈 상태 유지
                onChanged(minValue);
              } else {
                final total = int.tryParse(value);
                if (total != null && total >= minValue && total <= maxValue) {
                  onChanged(total);
                } else {
                  // 유효하지 않은 값이면 minValue로 설정하고 빈 텍스트로 표시
                  onChanged(minValue);
                  controller.text = '';
                }
              }
            },
          ),
        ),
      ],
    );
  }
}
