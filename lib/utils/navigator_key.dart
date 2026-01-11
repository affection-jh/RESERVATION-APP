import 'package:flutter/material.dart';

/// 전역 NavigatorKey
/// FCM 등 context가 필요한 서비스에서 사용
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
