import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// 관리자 조작 시 사용자 알림 발송 여부를 고르는 원형 체크박스.
///
/// 변경사항/선택이 있을 때만 부모에서 노출하는 것을 권장.
class AdminSendNotificationCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;
  final String offHint;
  final String onHint;

  const AdminSendNotificationCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = '알림 보내기',
    this.offHint = '알림 없이 진행',
    this.onHint = '사용자에게 알림',
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: value ? AppColors.primaryGreen : Colors.transparent,
                border: Border.all(
                  color:
                      value
                          ? AppColors.primaryGreen
                          : AppColors.textSecondary.withOpacity(0.45),
                  width: 1.6,
                ),
              ),
              child:
                  value
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Text(
              value ? onHint : offHint,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary.withOpacity(0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
