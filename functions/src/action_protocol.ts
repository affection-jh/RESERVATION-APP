import * as functions from 'firebase-functions';

export type RequiresForceDetails = {
  requiresForce: true;
  reason: string; // ReservationLockReason string
  openAt?: string | null;
  capacity?: number;
  reservedCount?: number;
  closeBeforeMinutes?: number;
};

export function throwRequiresForce(details: Omit<RequiresForceDetails, 'requiresForce'>): never {
  throw new functions.https.HttpsError(
    'failed-precondition',
    '정책상 예약이 제한됩니다. 관리자 권한으로 강제 추가하시겠습니까?',
    {
      requiresForce: true,
      ...details,
    } satisfies RequiresForceDetails,
  );
}

export type RequiresCascadeDetails = {
  requiresCascade: true;
  courseId: string;
  courseName: string;
  reservationCount: number;
};

export function throwRequiresCascade(details: Omit<RequiresCascadeDetails, 'requiresCascade'>): never {
  throw new functions.https.HttpsError(
    'failed-precondition',
    '해당 코스의 미래 예약이 존재합니다. 예약을 모두 취소한 뒤 등록 취소를 진행할 수 있습니다.',
    {
      requiresCascade: true,
      ...details,
    } satisfies RequiresCascadeDetails,
  );
}

export type RequiresCascadeDeleteCourseDetails = {
  requiresCascade: true;
  kind: 'deleteCourse';
  courseId: string;
  courseName: string;
  reservationCount: number;
};

export function throwRequiresCascadeDeleteCourse(
  details: Omit<RequiresCascadeDeleteCourseDetails, 'requiresCascade' | 'kind'>,
): never {
  throw new functions.https.HttpsError(
    'failed-precondition',
    '코스 삭제를 위해 먼저 남아있는 예약을 모두 취소해야 합니다.',
    {
      requiresCascade: true,
      kind: 'deleteCourse',
      ...details,
    } satisfies RequiresCascadeDeleteCourseDetails,
  );
}

export type RequiresBulkMoveDetails = {
  requiresBulkMove: true;
  courseId: string;
  courseName: string;
  dayOfWeek: number;
  startTime: string;
  operation: 'delete' | 'modify';
};

export function throwRequiresBulkMove(details: Omit<RequiresBulkMoveDetails, 'requiresBulkMove'>): never {
  throw new functions.https.HttpsError(
    'failed-precondition',
    '예약이 있는 세션은 삭제/변경할 수 없습니다. 먼저 예약을 이동하거나 세션을 취소해주세요.',
    {
      requiresBulkMove: true,
      ...details,
    } satisfies RequiresBulkMoveDetails,
  );
}


