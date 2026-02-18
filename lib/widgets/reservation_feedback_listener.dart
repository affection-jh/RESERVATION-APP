import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/reservation_provider.dart';
import '../providers/enrollment_provider.dart';
import '../utils/snackbar_util.dart';
import '../utils/error_message_util.dart';

/// 예약 취소 성공/실패 스낵바를 단일 구독으로 처리
/// MyPageScreen/CalendarScreen 등 여러 화면에서 중복 구독하지 않도록
class ReservationFeedbackListener extends StatefulWidget {
  final Widget child;

  const ReservationFeedbackListener({
    super.key,
    required this.child,
  });

  @override
  State<ReservationFeedbackListener> createState() =>
      _ReservationFeedbackListenerState();
}

class _ReservationFeedbackListenerState extends State<ReservationFeedbackListener> {
  StreamSubscription<ReservationOperationEvent>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _subscribe() {
    _sub?.cancel();
    final rp = Provider.of<ReservationProvider>(context, listen: false);
    _sub = rp.operationEvents.listen((event) async {
      if (event.type != ReservationOperationType.cancel) return;
      if (!mounted) return;
      if (event.success == true && event.reservation != null) {
        final r = event.reservation!;
        try {
          await Provider.of<EnrollmentProvider>(context, listen: false)
              .loadUserEnrollments(userId: r.userId, placeId: r.placeId);
          await Provider.of<ReservationProvider>(context, listen: false)
              .loadUserReservations(userId: r.userId, placeId: r.placeId);
        } catch (_) {}
        if (!mounted) return;
        SnackbarUtil.showSuccess(context, '예약이 취소되었습니다.');
      } else if (event.success == false) {
        final raw = event.error?.toString() ?? '';
        final friendly =
            raw.trim().isEmpty ? '' : ErrorMessageUtil.toUserFriendlyMessage(raw);
        if (friendly.contains('네트워크') || friendly.contains('인터넷')) {
          SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요.');
        } else {
          SnackbarUtil.showInfo(context, '예약 취소에 실패했습니다.');
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
