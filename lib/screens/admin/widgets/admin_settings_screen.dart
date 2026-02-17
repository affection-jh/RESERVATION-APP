import 'package:flutter/material.dart';
import '../../setting_screen.dart';

/// 관리자 설정 화면 (통합 SettingScreen의 어드민 모드 래퍼)
class AdminSettingsScreen extends StatelessWidget {
  const AdminSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingScreen(isAdminMode: true);
  }
}
