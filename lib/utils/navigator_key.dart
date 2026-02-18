import 'package:flutter/material.dart';

/// 전역 NavigatorKey
/// FCM 등 context가 필요한 서비스에서 사용
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 전역 RouteObserver (관리자 홈 복귀 시 주차 탭 갱신 등)
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();
