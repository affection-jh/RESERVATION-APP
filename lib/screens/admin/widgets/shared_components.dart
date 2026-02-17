import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';

/// 섹션 제목 + 선택적 액션 아이콘
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

/// 빈 목록/상태 안내 문구
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

/// 자식 위젯 + 수정/삭제 버튼 행
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

/// 바텀시트 공통 레이아웃 (제목, 닫기, 저장, 본문)
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

/// 라벨용 칩
class Chip extends StatelessWidget {
  final String text;
  final Color? backgroundColor;
  final Color? textColor;

  const Chip({
    super.key,
    required this.text,
    this.backgroundColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor ?? AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: textColor ?? AppColors.textSecondary,
          fontSize: 12,
        ),
      ),
    );
  }
}

/// 삭제 확인 다이얼로그
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
