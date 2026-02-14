import '../utils/timezone_utils.dart';

/// 코스 등록 정보 모델
///
/// 유저가 특정 코스에 등록한 정보와 남은 예약 가능 수, 유효 기간 등을 관리
class CourseEnrollment {
  final String id;
  final String userId;
  // 🔎 Firebase 콘솔 디버깅/가독성용 (denormalized)
  final String? userName;
  final String courseId;
  // 🔎 Firebase 콘솔 디버깅/가독성용 (denormalized)
  final String? courseName;
  final String placeId;
  final DateTime enrolledAt; // 현재 등록일 (재등록 시 업데이트)
  final int totalEnrollmentCount; // 총 등록횟수 (1, 2, 3...)
  final DateTime validFrom; // 유효 시작일
  final DateTime validUntil; // 유효 종료일
  final int totalReservations; // 총 예약 가능 횟수
  final int remainingReservations; // 남은 예약 가능 횟수
  final List<ExtensionRequest> extensionRequests; // 연장 요청 기록들 (배열)
  final List<ReenrollmentRecord> reenrollmentHistory; // 재등록 이력 (취소된 등록 포함)
  final List<AdminAction> adminActions; // 관리자 대응 기록
  final String? memo; // 메모

  CourseEnrollment({
    required this.id,
    required this.userId,
    this.userName,
    required this.courseId,
    this.courseName,
    required this.placeId,
    required this.enrolledAt,
    this.totalEnrollmentCount = 1,
    required this.validFrom,
    required this.validUntil,
    required this.totalReservations,
    required this.remainingReservations,
    List<ExtensionRequest>? extensionRequests,
    List<ReenrollmentRecord>? reenrollmentHistory,
    List<AdminAction>? adminActions,
    this.memo,
    // 하위 호환성을 위한 legacy 필드
    ExtensionRequest? extensionRequest,
  }) : extensionRequests =
           extensionRequests ??
           (extensionRequest != null ? [extensionRequest] : []),
       reenrollmentHistory = reenrollmentHistory ?? [],
       adminActions = adminActions ?? [];

  // 최초 등록일 (히스토리의 첫 번째 항목에서 가져오기)
  DateTime? get firstEnrolledAt {
    if (reenrollmentHistory.isEmpty) {
      // 히스토리가 없으면 현재 enrolledAt 반환 (첫 등록)
      return enrolledAt;
    }
    // 히스토리의 첫 번째 항목이 최초 등록
    return reenrollmentHistory.first.enrolledAt;
  }

  // 유효 기간이 만료되었는지 확인
  bool get isExpired {
    return TimezoneUtils.getSeoulDateTime().isAfter(validUntil);
  }

  // 유효 기간이 유효한지 확인
  bool get isValid {
    final now = TimezoneUtils.getSeoulDateTime();
    return now.isAfter(validFrom) && now.isBefore(validUntil);
  }

  // 예약 가능 여부 (유효 기간 내이고 남은 횟수가 있으면)
  bool get canReserve {
    return isValid && remainingReservations > 0;
  }

  /// 관리자가 멤버 선택 패널에서 일회성으로 추가한 등록 여부 (1회석 등록)
  bool get isOneTime {
    return totalReservations == 1 && totalEnrollmentCount == 1;
  }

  // 하위 호환성: 가장 최근 연장 요청 반환 (pending 우선)
  ExtensionRequest? get extensionRequest {
    // pending 상태인 요청이 있으면 반환
    final pending =
        extensionRequests
            .where((r) => r.status == ExtensionRequestStatus.pending)
            .toList();
    if (pending.isNotEmpty) {
      // 가장 최근 pending 요청 반환
      pending.sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
      return pending.first;
    }
    // pending이 없으면 가장 최근 요청 반환
    if (extensionRequests.isNotEmpty) {
      final sorted = List<ExtensionRequest>.from(extensionRequests)
        ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
      return sorted.first;
    }
    return null;
  }

  // 연장 요청 중인지 확인
  bool get hasPendingExtensionRequest {
    return extensionRequests.any(
      (r) => r.status == ExtensionRequestStatus.pending,
    );
  }

  // 예약 사용 (남은 횟수 차감)
  CourseEnrollment useReservation() {
    if (remainingReservations <= 0) {
      throw Exception('남은 예약 횟수가 없습니다.');
    }
    return copyWith(remainingReservations: remainingReservations - 1);
  }

  // 예약 취소 (남은 횟수 복구)
  CourseEnrollment cancelReservation() {
    if (remainingReservations >= totalReservations) {
      throw Exception('남은 횟수가 이미 최대값입니다.');
    }
    return copyWith(remainingReservations: remainingReservations + 1);
  }

  // 연장 요청 생성
  CourseEnrollment requestExtension(String reason) {
    if (hasPendingExtensionRequest) {
      throw Exception('이미 연장 요청이 진행 중입니다.');
    }
    final newRequest = ExtensionRequest(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      requestedAt: TimezoneUtils.getSeoulDateTime(),
      reason: reason,
      status: ExtensionRequestStatus.pending,
    );
    return copyWith(extensionRequests: [...extensionRequests, newRequest]);
  }

  // 연장 요청 취소
  CourseEnrollment cancelExtensionRequest() {
    final updatedRequests =
        extensionRequests.map((r) {
          if (r.status == ExtensionRequestStatus.pending) {
            return r.copyWith(
              status: ExtensionRequestStatus.rejected,
              rejectedAt: TimezoneUtils.getSeoulDateTime(),
              rejectionReason: '사용자 취소',
            );
          }
          return r;
        }).toList();
    return copyWith(extensionRequests: updatedRequests);
  }

  // 연장 승인 (관리자용)
  CourseEnrollment approveExtension(DateTime newValidUntil) {
    final pendingRequest = extensionRequest;
    if (pendingRequest == null ||
        pendingRequest.status != ExtensionRequestStatus.pending) {
      throw Exception('승인할 연장 요청이 없습니다.');
    }
    final updatedRequests =
        extensionRequests.map((r) {
          if (r.id == pendingRequest.id) {
            return r.copyWith(
              status: ExtensionRequestStatus.approved,
              approvedAt: TimezoneUtils.getSeoulDateTime(),
            );
          }
          return r;
        }).toList();
    return copyWith(
      validUntil: newValidUntil,
      extensionRequests: updatedRequests,
    );
  }

  // 연장 거부 (관리자용)
  CourseEnrollment rejectExtension(String? reason) {
    final pendingRequest = extensionRequest;
    if (pendingRequest == null ||
        pendingRequest.status != ExtensionRequestStatus.pending) {
      throw Exception('거부할 연장 요청이 없습니다.');
    }
    final updatedRequests =
        extensionRequests.map((r) {
          if (r.id == pendingRequest.id) {
            return r.copyWith(
              status: ExtensionRequestStatus.rejected,
              rejectedAt: TimezoneUtils.getSeoulDateTime(),
              rejectionReason: reason,
            );
          }
          return r;
        }).toList();
    return copyWith(extensionRequests: updatedRequests);
  }

  // 복사본 생성
  CourseEnrollment copyWith({
    String? id,
    String? userId,
    String? userName,
    String? courseId,
    String? courseName,
    String? placeId,
    DateTime? enrolledAt,
    int? totalEnrollmentCount,
    DateTime? validFrom,
    DateTime? validUntil,
    int? totalReservations,
    int? remainingReservations,
    List<ExtensionRequest>? extensionRequests,
    List<ReenrollmentRecord>? reenrollmentHistory,
    List<AdminAction>? adminActions,
    String? memo,
    bool clearMemo = false,
    // 하위 호환성
    ExtensionRequest? extensionRequest,
    bool clearExtensionRequest = false,
  }) {
    List<ExtensionRequest> finalExtensionRequests;
    if (clearExtensionRequest) {
      finalExtensionRequests = [];
    } else if (extensionRequests != null) {
      finalExtensionRequests = extensionRequests;
    } else if (extensionRequest != null) {
      // 기존 배열에 새 요청 추가
      finalExtensionRequests = [...this.extensionRequests, extensionRequest];
    } else {
      finalExtensionRequests = this.extensionRequests;
    }

    return CourseEnrollment(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      courseId: courseId ?? this.courseId,
      courseName: courseName ?? this.courseName,
      placeId: placeId ?? this.placeId,
      enrolledAt: enrolledAt ?? this.enrolledAt,
      totalEnrollmentCount: totalEnrollmentCount ?? this.totalEnrollmentCount,
      validFrom: validFrom ?? this.validFrom,
      validUntil: validUntil ?? this.validUntil,
      totalReservations: totalReservations ?? this.totalReservations,
      remainingReservations:
          remainingReservations ?? this.remainingReservations,
      extensionRequests: finalExtensionRequests,
      reenrollmentHistory: reenrollmentHistory ?? this.reenrollmentHistory,
      adminActions: adminActions ?? this.adminActions,
      memo: clearMemo ? null : (memo ?? this.memo),
    );
  }

  // JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'userName': userName,
      'courseId': courseId,
      'courseName': courseName,
      'placeId': placeId,
      'enrolledAt': enrolledAt.toIso8601String(),
      'totalEnrollmentCount': totalEnrollmentCount,
      'validFrom': validFrom.toIso8601String(),
      'validUntil': validUntil.toIso8601String(),
      'totalReservations': totalReservations,
      'remainingReservations': remainingReservations,
      'extensionRequests': extensionRequests.map((r) => r.toJson()).toList(),
      'reenrollmentHistory':
          reenrollmentHistory.map((r) => r.toJson()).toList(),
      'adminActions': adminActions.map((a) => a.toJson()).toList(),
      'memo': memo,
      // 하위 호환성: 가장 최근 extensionRequest도 포함
      if (extensionRequest != null)
        'extensionRequest': extensionRequest!.toJson(),
    };
  }

  // JSON에서 생성
  factory CourseEnrollment.fromJson(Map<String, dynamic> json) {
    // 하위 호환성: extensionRequest가 있으면 extensionRequests로 변환
    List<ExtensionRequest> extensionRequestsList = [];
    if (json['extensionRequests'] != null) {
      extensionRequestsList =
          (json['extensionRequests'] as List)
              .map((e) => ExtensionRequest.fromJson(e as Map<String, dynamic>))
              .toList();
    } else if (json['extensionRequest'] != null) {
      // 기존 단일 extensionRequest를 배열로 변환
      extensionRequestsList = [
        ExtensionRequest.fromJson(
          json['extensionRequest'] as Map<String, dynamic>,
        ),
      ];
    }

    return CourseEnrollment(
      id: json['id'] as String,
      userId: json['userId'] as String,
      userName: json['userName'] as String?,
      courseId: json['courseId'] as String,
      courseName: json['courseName'] as String?,
      placeId: json['placeId'] as String,
      enrolledAt: DateTime.parse(json['enrolledAt'] as String),
      totalEnrollmentCount: json['totalEnrollmentCount'] as int? ?? 1,
      validFrom: DateTime.parse(json['validFrom'] as String),
      validUntil: DateTime.parse(json['validUntil'] as String),
      totalReservations: json['totalReservations'] as int,
      remainingReservations: json['remainingReservations'] as int,
      extensionRequests: extensionRequestsList,
      reenrollmentHistory:
          json['reenrollmentHistory'] != null
              ? (json['reenrollmentHistory'] as List)
                  .map(
                    (e) =>
                        ReenrollmentRecord.fromJson(e as Map<String, dynamic>),
                  )
                  .toList()
              : [],
      adminActions:
          json['adminActions'] != null
              ? (json['adminActions'] as List)
                  .map((e) => AdminAction.fromJson(e as Map<String, dynamic>))
                  .toList()
              : [],
      memo: json['memo'] as String?,
    );
  }

  @override
  String toString() {
    return 'CourseEnrollment(courseId: $courseId, remaining: $remainingReservations/$totalReservations, validUntil: $validUntil)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CourseEnrollment && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// 연장 요청 모델
class ExtensionRequest {
  final String id;
  final DateTime requestedAt;
  final String reason;
  final ExtensionRequestStatus status;
  final DateTime? approvedAt;
  final DateTime? rejectedAt;
  final String? rejectionReason;

  ExtensionRequest({
    required this.id,
    required this.requestedAt,
    required this.reason,
    required this.status,
    this.approvedAt,
    this.rejectedAt,
    this.rejectionReason,
  });

  // 복사본 생성
  ExtensionRequest copyWith({
    String? id,
    DateTime? requestedAt,
    String? reason,
    ExtensionRequestStatus? status,
    DateTime? approvedAt,
    DateTime? rejectedAt,
    String? rejectionReason,
  }) {
    return ExtensionRequest(
      id: id ?? this.id,
      requestedAt: requestedAt ?? this.requestedAt,
      reason: reason ?? this.reason,
      status: status ?? this.status,
      approvedAt: approvedAt ?? this.approvedAt,
      rejectedAt: rejectedAt ?? this.rejectedAt,
      rejectionReason: rejectionReason ?? this.rejectionReason,
    );
  }

  // JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'requestedAt': requestedAt.toIso8601String(),
      'reason': reason,
      'status': status.name,
      'approvedAt': approvedAt?.toIso8601String(),
      'rejectedAt': rejectedAt?.toIso8601String(),
      'rejectionReason': rejectionReason,
    };
  }

  // JSON에서 생성
  factory ExtensionRequest.fromJson(Map<String, dynamic> json) {
    return ExtensionRequest(
      id: json['id'] as String,
      requestedAt: DateTime.parse(json['requestedAt'] as String),
      reason: json['reason'] as String,
      status: ExtensionRequestStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => ExtensionRequestStatus.pending,
      ),
      approvedAt:
          json['approvedAt'] != null
              ? DateTime.parse(json['approvedAt'] as String)
              : null,
      rejectedAt:
          json['rejectedAt'] != null
              ? DateTime.parse(json['rejectedAt'] as String)
              : null,
      rejectionReason: json['rejectionReason'] as String?,
    );
  }
}

/// 연장 요청 상태
enum ExtensionRequestStatus {
  pending, // 대기 중
  approved, // 승인됨
  rejected, // 거부됨
}

/// 재등록 기록 모델
class ReenrollmentRecord {
  final int enrollmentNumber; // 몇 번째 등록인지 (1, 2, 3...)
  final int totalReservations; // 해당 등록의 총 횟수
  final DateTime enrolledAt; // 재등록일
  final DateTime validFrom; // 유효 시작일
  final DateTime validUntil; // 유효 종료일
  final DateTime? cancelledAt; // 취소된 경우

  ReenrollmentRecord({
    required this.enrollmentNumber,
    required this.totalReservations,
    required this.enrolledAt,
    required this.validFrom,
    required this.validUntil,
    this.cancelledAt,
  });

  // JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'enrollmentNumber': enrollmentNumber,
      'totalReservations': totalReservations,
      'enrolledAt': enrolledAt.toIso8601String(),
      'validFrom': validFrom.toIso8601String(),
      'validUntil': validUntil.toIso8601String(),
      'cancelledAt': cancelledAt?.toIso8601String(),
    };
  }

  // JSON에서 생성
  factory ReenrollmentRecord.fromJson(Map<String, dynamic> json) {
    return ReenrollmentRecord(
      enrollmentNumber: json['enrollmentNumber'] as int,
      totalReservations: json['totalReservations'] as int,
      enrolledAt: DateTime.parse(json['enrolledAt'] as String),
      validFrom: DateTime.parse(json['validFrom'] as String),
      validUntil: DateTime.parse(json['validUntil'] as String),
      cancelledAt:
          json['cancelledAt'] != null
              ? DateTime.parse(json['cancelledAt'] as String)
              : null,
    );
  }
}

/// 관리자 대응 기록 모델
class AdminAction {
  final String id;
  final AdminActionType actionType;
  final DateTime performedAt;
  final String performedBy; // adminId
  final String? details; // 상세 설명
  final Map<String, dynamic>? oldValue; // 변경 전 값
  final Map<String, dynamic>? newValue; // 변경 후 값

  AdminAction({
    required this.id,
    required this.actionType,
    required this.performedAt,
    required this.performedBy,
    this.details,
    this.oldValue,
    this.newValue,
  });

  // JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'actionType': actionType.name,
      'performedAt': performedAt.toIso8601String(),
      'performedBy': performedBy,
      'details': details,
      'oldValue': oldValue,
      'newValue': newValue,
    };
  }

  // JSON에서 생성
  factory AdminAction.fromJson(Map<String, dynamic> json) {
    return AdminAction(
      id: json['id'] as String,
      actionType: AdminActionType.values.firstWhere(
        (e) => e.name == json['actionType'],
        orElse: () => AdminActionType.other,
      ),
      performedAt: DateTime.parse(json['performedAt'] as String),
      performedBy: json['performedBy'] as String,
      details: json['details'] as String?,
      oldValue: json['oldValue'] as Map<String, dynamic>?,
      newValue: json['newValue'] as Map<String, dynamic>?,
    );
  }
}

/// 관리자 작업 타입
enum AdminActionType {
  adjustCount, // 횟수 조정
  extendPeriod, // 기간 연장
  reenroll, // 재등록
  cancel, // 취소
  memoUpdated, // 메모 업데이트
  other, // 기타
}
