import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../models/course.dart';
import '../../../models/reservation.dart';
import '../../../models/user.dart';
import '../../../models/course_enrollment.dart';
import '../../../models/admin_models.dart';
import '../../../theme/app_colors.dart';
import 'bulk_move_reservations_bottom_sheet.dart';
import '../../../utils/snackbar_util.dart';
import '../../../widgets/common_dialog.dart';
import '../../../providers/reservation_provider.dart';
import '../../../providers/member_provider.dart';
import '../../../utils/navigator_key.dart';
import 'package:provider/provider.dart';
import '../../../utils/timezone_utils.dart';
import 'enrollment_detail_screen.dart';

/// 예약 관리 간단 바텀시트 (예약 취소, 예약 변경 버튼만)
class ReservationManageBottomSheet extends StatelessWidget {
  final Course course;
  final CourseSession sourceSession;
  final DateTime sourceDate;
  final Reservation reservation;
  final User? user;
  final VoidCallback? onCancelled;
  final VoidCallback? onMoved;
  final Function(Set<String>)? onMovingStarted;
  final Function(String)? onMovingCompleted;
  final Function()? onAllMovingCompleted;
  /// 스낵바를 붙일 context (예약 변경 성공/실패 스낵바를 화면에 표시할 때 사용)
  final BuildContext? snackbarContext;

  const ReservationManageBottomSheet({
    super.key,
    required this.course,
    required this.sourceSession,
    required this.sourceDate,
    required this.reservation,
    this.user,
    this.onCancelled,
    this.onMoved,
    this.onMovingStarted,
    this.onMovingCompleted,
    this.onAllMovingCompleted,
    this.snackbarContext,
  });

  static void show({
    required BuildContext context,
    required Course course,
    required CourseSession sourceSession,
    required DateTime sourceDate,
    required Reservation reservation,
    User? user,
    VoidCallback? onCancelled,
    VoidCallback? onMoved,
    Function(Set<String>)? onMovingStarted,
    Function(String)? onMovingCompleted,
    Function()? onAllMovingCompleted,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder:
          (modalContext) => ReservationManageBottomSheet(
            course: course,
            sourceSession: sourceSession,
            sourceDate: sourceDate,
            reservation: reservation,
            user: user,
            onCancelled: onCancelled,
            onMoved: onMoved,
            onMovingStarted: onMovingStarted,
            onMovingCompleted: onMovingCompleted,
            onAllMovingCompleted: onAllMovingCompleted,
            snackbarContext: context,
          ),
    );
  }

  /// 세션이 이미 시작되었는지 확인
  bool _isSessionStarted() {
    final now = TimezoneUtils.getSeoulDateTime();
    final sessionStartTime = sourceSession.startTime.split(':');
    final sessionHour = int.parse(sessionStartTime[0]);
    final sessionMinute = int.parse(sessionStartTime[1]);
    final sessionDateTime = DateTime(
      sourceDate.year,
      sourceDate.month,
      sourceDate.day,
      sessionHour,
      sessionMinute,
    );
    return sessionDateTime.isBefore(now);
  }

  @override
  Widget build(BuildContext context) {
    final isSessionStarted = _isSessionStarted();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      ),
      padding: EdgeInsets.only(
        left: 0,
        right: 0,
        top: 32,
        bottom: 32 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '예약 관리',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () async {
                    // 현재 바텀시트 닫기
                    Navigator.of(context).pop();

                    // 닫힌 후 다음 화면으로 이동
                    await Future.delayed(const Duration(milliseconds: 300));
                    final ctx = navigatorKey.currentContext;
                    if (ctx == null) return;

                    try {
                      final memberProvider = Provider.of<MemberProvider>(
                        ctx,
                        listen: false,
                      );

                      // 1) 멤버(User) 확보 (우선 전달된 user 사용, 없으면 Provider에서 조회)
                      User? targetUser = user;
                      targetUser ??= memberProvider.getMember(
                        reservation.userId,
                      );

                      // 캐시에 없으면 placeId 기준으로 로드 후 재시도
                      if (targetUser == null) {
                        await memberProvider.loadMembers(reservation.placeId);
                        targetUser = memberProvider.getMember(
                          reservation.userId,
                        );
                      }

                      if (targetUser == null) {
                        throw Exception('멤버 정보를 찾을 수 없습니다.');
                      }

                      // 2) MemberData 구성 (EnrollmentDetailScreen에 필요한 최소 정보)
                      final isPending = targetUser.userId.startsWith(
                        'pending_',
                      );
                      final memberData = MemberData(
                        userId: targetUser.userId,
                        name: targetUser.name,
                        phoneNumber: targetUser.phoneNumber,
                        role: isPending ? '대기중' : '일반',
                        isActive: !isPending,
                        pendingExtensionRequests:
                            targetUser.pendingExtensionRequests.length,
                        enrolledCourseIds:
                            targetUser.enrollments
                                .map((e) => e.courseId)
                                .toList(),
                      );

                      // 3) enrollment 조회 (deterministic id)
                      final enrollmentId =
                          '${targetUser.userId}_${reservation.placeId}_${course.id}';
                      final doc =
                          await FirebaseFirestore.instance
                              .collection('enrollments')
                              .doc(enrollmentId)
                              .get();

                      if (!doc.exists || doc.data() == null) {
                        SnackbarUtil.showError(
                          ctx,
                          '등록 정보를 찾을 수 없습니다. (enrollmentId: $enrollmentId)',
                        );
                        return;
                      }

                      DateTime _toDateTime(dynamic v) {
                        if (v == null) return TimezoneUtils.getSeoulDateTime();
                        if (v is Timestamp) return v.toDate();
                        if (v is String) return DateTime.parse(v);
                        return TimezoneUtils.getSeoulDateTime();
                      }

                      Map<String, dynamic> normalizeEnrollmentJson(
                        Map<String, dynamic> raw,
                      ) {
                        final json = Map<String, dynamic>.from(raw);
                        json['id'] ??= doc.id;

                        json['enrolledAt'] =
                            _toDateTime(json['enrolledAt']).toIso8601String();
                        json['validFrom'] =
                            _toDateTime(json['validFrom']).toIso8601String();
                        json['validUntil'] =
                            _toDateTime(json['validUntil']).toIso8601String();

                        // extensionRequests 내부 timestamp 정리 (있을 때만)
                        if (json['extensionRequests'] is List) {
                          final list =
                              (json['extensionRequests'] as List)
                                  .map(
                                    (e) => Map<String, dynamic>.from(e as Map),
                                  )
                                  .toList();
                          for (final r in list) {
                            r['requestedAt'] =
                                _toDateTime(r['requestedAt']).toIso8601String();
                            if (r['approvedAt'] != null) {
                              r['approvedAt'] =
                                  _toDateTime(
                                    r['approvedAt'],
                                  ).toIso8601String();
                            }
                            if (r['rejectedAt'] != null) {
                              r['rejectedAt'] =
                                  _toDateTime(
                                    r['rejectedAt'],
                                  ).toIso8601String();
                            }
                          }
                          json['extensionRequests'] = list;
                        }

                        // 하위 호환성: extensionRequest 단일 객체도 timestamp 정리
                        if (json['extensionRequest'] is Map) {
                          final r = Map<String, dynamic>.from(
                            json['extensionRequest'] as Map,
                          );
                          r['requestedAt'] =
                              _toDateTime(r['requestedAt']).toIso8601String();
                          if (r['approvedAt'] != null) {
                            r['approvedAt'] =
                                _toDateTime(r['approvedAt']).toIso8601String();
                          }
                          if (r['rejectedAt'] != null) {
                            r['rejectedAt'] =
                                _toDateTime(r['rejectedAt']).toIso8601String();
                          }
                          json['extensionRequest'] = r;
                        }

                        return json;
                      }

                      final enrollment = CourseEnrollment.fromJson(
                        normalizeEnrollmentJson(doc.data()!),
                    );

                      // 4) 상세 화면으로 이동
                      await Navigator.of(ctx).push(
                        MaterialPageRoute(
                          builder:
                              (context) => EnrollmentDetailScreen(
                                member: memberData,
                                enrollment: enrollment,
                                course: course,
                              ),
                        ),
                      );
                    } catch (e) {
                      SnackbarUtil.showError(
                        ctx,
                        '등록 상세 화면 이동 중 오류가 발생했습니다: $e',
                      );
                    }
                  },
                  color: AppColors.textSecondary,
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const Icon(Icons.close),
                ),
                SizedBox(width: 8),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // 현재 세션 정보
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '현재 세션',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondary.withOpacity(0.9),
                  ),
                ),
                const SizedBox(height: 8),
                _buildSessionInfo(),
              ],
            ),
          ),
          // 액션 버튼들 (시작된 세션이 아닐 때만 표시)
          if (!isSessionStarted) ...[
          const SizedBox(height: 34),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _handleCancel(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    child: const Text(
                      '예약 취소',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: () => _handleMove(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      '예약 변경시키기',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ],
        ],
      ),
    );
  }

  Widget _buildSessionInfo() {
    final weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final weekday = weekdays[sourceDate.weekday - 1];
    final dateStr =
        '${sourceDate.year}-${sourceDate.month.toString().padLeft(2, '0')}-${sourceDate.day.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$dateStr ($weekday) ${sourceSession.startTime}~${sourceSession.endTime}',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }

  Future<void> _handleCancel(BuildContext context) async {
    // 바텀시트를 먼저 닫기
    Navigator.of(context).pop();

    // 바텀시트가 닫힌 후 다이얼로그 표시
    await Future.delayed(const Duration(milliseconds: 300));

    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;

    // 다이얼로그 띄우기
    final confirmed = await CommonDialog.show(
      context: ctx,
      title: '예약 취소',
      message: '${user?.name ?? reservation.userId}님의 예약을 취소하시겠습니까?',
      cancelText: '취소',
      confirmText: '예약 취소',
      confirmButtonColor: Colors.red,
    );

    if (confirmed != true) return;

    // 취소 시작 알림 (로딩 스피너 표시를 위해)
    onCancelled?.call();

    try {
      final rp = Provider.of<ReservationProvider>(ctx, listen: false);
      if (reservation.id.isEmpty) {
        throw Exception('예약 ID가 없습니다.');
      }
      await rp.cancelReservation(reservation);
    } catch (e) {
      final errorCtx = navigatorKey.currentContext;
      if (errorCtx != null && errorCtx.mounted) {
        SnackbarUtil.showError(errorCtx, '예약 취소 중 오류가 발생했습니다: $e');
      }
      rethrow;
    }
  }

  void _handleMove(BuildContext context) {
    // 현재 바텀시트 닫기
    Navigator.of(context).pop();

    // 바텀시트가 닫힌 후 예약 변경 바텀시트 표시
    Future.delayed(const Duration(milliseconds: 300), () {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;

      showModalBottomSheet(
        context: ctx,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withOpacity(0.7),
        isDismissible: true,
        enableDrag: true,
        useSafeArea: true,
        builder:
            (context) => BulkMoveReservationsBottomSheet(
              course: course,
              sourceSession: sourceSession,
              sourceDate: sourceDate,
              reservations: [reservation],
              user: user,
              onMoved: () {
                onMoved?.call();
              },
              onCancelled: () {
                onCancelled?.call();
              },
              onMovingStarted: onMovingStarted,
              onMovingCompleted: onMovingCompleted,
              onAllMovingCompleted: onAllMovingCompleted,
              snackbarContext: snackbarContext,
            ),
      );
    });
  }
}
