import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import type { EventContext } from 'firebase-functions';
import type { QueryDocumentSnapshot } from 'firebase-functions/v1/firestore';
import type { Change } from 'firebase-functions';
import { logFunctionStart, logFunctionSuccess, logFunctionError, logWarn } from './logger';
import { assertAdminUid, assertAdminForPlaceUid, isAdminForPlaceUid } from './admin_auth';
import { getPlaceOrThrow, getCourseName, findCourse } from './course_catalog';
import { throwRequiresForce, throwRequiresCascade, throwRequiresBulkMove } from './action_protocol';
import {
    incrementSessionReservedCountUpsert,
} from './reservation_ops';

// Export course override functions
export { upsertCourseOverride } from './course_override';

async function deleteCollectionByPath(
    db: FirebaseFirestore.Firestore,
    collectionPath: string,
    batchSize = 400,
): Promise<number> {
    let deleted = 0;
    while (true) {
        const snap = await db.collection(collectionPath).limit(batchSize).get();
        if (snap.empty) break;
        const batch = db.batch();
        snap.docs.forEach((d) => batch.delete(d.ref));
        await batch.commit();
        deleted += snap.size;
        if (snap.size < batchSize) break;
    }
    return deleted;
}

async function deleteByQuery(
    db: FirebaseFirestore.Firestore,
    query: FirebaseFirestore.Query,
    batchSize = 400,
): Promise<number> {
    let deleted = 0;
    while (true) {
        const snap = await query.limit(batchSize).get();
        if (snap.empty) break;
        const batch = db.batch();
        snap.docs.forEach((d) => batch.delete(d.ref));
        await batch.commit();
        deleted += snap.size;
        if (snap.size < batchSize) break;
    }
    return deleted;
}

admin.initializeApp();

/**
 * ==================== Reservation Policy (Server) ====================
 *
 * 앱이 "단일 진실"로 트랜잭션을 갖는 구조를 유지하려면:
 * - reservations/sessionReservations/enrollments(remainingReservations) 변경은
 *   반드시 "한 곳"에서만 수행되어야 합니다.
 *
 * 이 구현은 Callable + Firestore transaction을 서버에서 수행하여
 * rollingWindow/weeklyRelease 정책을 정합적으로 반영합니다.
 */

type BookingOpenStrategyType = 'rollingWindow' | 'weeklyRelease';

type RollingWindowOpenStrategy = {
    windowDays: number;
};

type WeeklyReleaseOpenStrategy = {
    releaseDayOfWeek: number; // 1=월 ... 7=일
    releaseTime: string; // "HH:mm"
    weeksAhead: number; // 1이면 "다음주 주차" 오픈
};

type BookingOpenStrategy = {
    type: BookingOpenStrategyType;
    rollingWindow?: RollingWindowOpenStrategy;
    weeklyRelease?: WeeklyReleaseOpenStrategy;
};

type CoursePolicy = {
    courseId: string;
    placeId: string;
    closeBeforeMinutes: number;
    openStrategy: BookingOpenStrategy;
    allowAdminForceMoveWithinCourse?: boolean;
    version?: number;
    effectiveFrom: Date;
};

type CoursePolicyDoc = {
    active?: any;
    scheduled?: any;
    // legacy: policy fields directly
};

enum ReservationLockReason {
    none = 'none',
    pastDate = 'pastDate',
    notOpenedYet = 'notOpenedYet',
    closedBeforeStart = 'closedBeforeStart',
    full = 'full',
    noCreditsOrExpired = 'noCreditsOrExpired',
}

type ReservationEligibility = {
    canReserve: boolean;
    reason: ReservationLockReason;
    openAt?: Date;
};

const SEOUL_OFFSET_MINUTES = 9 * 60;

function pad2(n: number): string {
    return String(n).padStart(2, '0');
}

function parseHHmm(hhmm: string): { h: number; m: number } {
    const [hRaw, mRaw] = (hhmm || '').split(':');
    const h = Number(hRaw);
    const m = Number(mRaw);
    return { h: Number.isFinite(h) ? h : 0, m: Number.isFinite(m) ? m : 0 };
}

function parseYYYYMMDD(dateString: string): { y: number; mo: number; d: number } {
    const [yRaw, mRaw, dRaw] = (dateString || '').split('-');
    const y = Number(yRaw);
    const mo = Number(mRaw);
    const d = Number(dRaw);
    if (!Number.isFinite(y) || !Number.isFinite(mo) || !Number.isFinite(d)) {
        throw new functions.https.HttpsError('invalid-argument', `날짜 형식이 올바르지 않습니다: ${dateString}`);
    }
    return { y, mo, d };
}

/**
 * "서울 로컬 시각"을 UTC 기반 Date로 만든다.
 * 예: 2026-01-07 10:00(서울) -> 내부적으로 UTC Date로 변환되어 비교 가능
 */
function makeSeoulDateTime(y: number, mo: number, d: number, h: number, m: number): Date {
    const utcMillis = Date.UTC(y, mo - 1, d, h, m) - SEOUL_OFFSET_MINUTES * 60_000;
    return new Date(utcMillis);
}

function seoulDateOnly(dateString: string): Date {
    const { y, mo, d } = parseYYYYMMDD(dateString);
    return makeSeoulDateTime(y, mo, d, 0, 0);
}

function addDaysUtc(date: Date, days: number): Date {
    return new Date(date.getTime() + days * 24 * 60 * 60 * 1000);
}

function seoulWeekday1to7(dateString: string): number {
    // seoulDateOnly는 "서울 00:00"을 나타내는 UTC Date이므로, getUTCDay()가 서울 요일과 일치한다.
    const d = seoulDateOnly(dateString);
    const day0 = d.getUTCDay(); // 0=일..6=토
    return day0 === 0 ? 7 : day0; // 1=월..7=일
}

function startOfWeekMondaySeoul(dateString: string): Date {
    const wd = seoulWeekday1to7(dateString);
    const monday = addDaysUtc(seoulDateOnly(dateString), -(wd - 1));
    return monday;
}

function computeOpenAt({
    policy,
    sessionDateString,
}: {
    policy: CoursePolicy;
    sessionDateString: string;
}): Date | undefined {
    const strategy = policy.openStrategy;
    if (!strategy || !strategy.type) return undefined;

    if (strategy.type === 'rollingWindow') {
        const days = strategy.rollingWindow?.windowDays ?? 21;
        // (세션 날짜 - windowDays) 00:00(서울) 오픈
        return addDaysUtc(seoulDateOnly(sessionDateString), -days);
    }

    // weeklyRelease
    const w = strategy.weeklyRelease;
    if (!w) return undefined;

    const weekStart = startOfWeekMondaySeoul(sessionDateString);
    // weeksAhead 의미(클라이언트/정책 UI와 일치):
    // - weeksAhead=1: 이번주만 오픈 (해당 주의 releaseDay/releaseTime에 오픈)
    // - weeksAhead=2: 이번주+다음주 오픈 (다음 주는 이번주의 releaseDay/releaseTime에 오픈)
    const weeksAhead = w.weeksAhead ?? 1;
    const openWeekStart = addDaysUtc(
        weekStart,
        -(7 * Math.max(weeksAhead - 1, 0)),
    );
    const { h, m } = parseHHmm(w.releaseTime ?? '10:00');
    // openWeekStart는 월요일 00:00(서울). 여기에 releaseDay-1일 + releaseTime 추가
    return addDaysUtc(makeSeoulDateTime(
        openWeekStart.getUTCFullYear(),
        openWeekStart.getUTCMonth() + 1,
        openWeekStart.getUTCDate(),
        h,
        m,
    ), (w.releaseDayOfWeek ?? 1) - 1);
}

function parsePolicy(raw: any, fallback: { courseId: string; placeId: string }): CoursePolicy {
    const openStrategyRaw = (raw?.openStrategy ?? {}) as any;
    const type = (openStrategyRaw?.type as BookingOpenStrategyType) ?? 'rollingWindow';
    const closeBeforeMinutes = Number(raw?.closeBeforeMinutes ?? 60);

    const effectiveFromRaw = raw?.effectiveFrom;
    let effectiveFrom: Date;
    if (effectiveFromRaw instanceof admin.firestore.Timestamp) {
        effectiveFrom = effectiveFromRaw.toDate();
    } else if (typeof effectiveFromRaw === 'string') {
        effectiveFrom = new Date(effectiveFromRaw);
    } else {
        effectiveFrom = new Date();
    }

    const policy: CoursePolicy = {
        courseId: String(raw?.courseId ?? fallback.courseId),
        placeId: String(raw?.placeId ?? fallback.placeId),
        closeBeforeMinutes: Number.isFinite(closeBeforeMinutes) ? closeBeforeMinutes : 60,
        openStrategy: {
            type,
            rollingWindow: openStrategyRaw?.rollingWindow,
            weeklyRelease: openStrategyRaw?.weeklyRelease,
        },
        allowAdminForceMoveWithinCourse: Boolean(raw?.allowAdminForceMoveWithinCourse ?? false),
        version: Number(raw?.version ?? 1),
        effectiveFrom,
    };
    return policy;
}

function selectEffectivePolicy(now: Date, docData: CoursePolicyDoc | null, fallback: { courseId: string; placeId: string }): CoursePolicy {
    // default: weekly release (월요일 9시, 60분)
    const defaultPolicy: CoursePolicy = {
        courseId: fallback.courseId,
        placeId: fallback.placeId,
        closeBeforeMinutes: 60,
        openStrategy: {
            type: 'weeklyRelease',
            weeklyRelease: {
                releaseDayOfWeek: 1, // 월요일
                releaseTime: '09:00', // 9시
                weeksAhead: 1
            }
        },
        allowAdminForceMoveWithinCourse: false,
        version: 1,
        effectiveFrom: now,
    };

    if (!docData) return defaultPolicy;

    // 신규 스키마: active/scheduled
    if (docData.active || docData.scheduled) {
        const active = docData.active ? parsePolicy(docData.active, fallback) : undefined;
        const scheduled = docData.scheduled ? parsePolicy(docData.scheduled, fallback) : undefined;

        const candidates: CoursePolicy[] = [];
        if (active && active.effectiveFrom.getTime() <= now.getTime()) candidates.push(active);
        if (scheduled && scheduled.effectiveFrom.getTime() <= now.getTime()) candidates.push(scheduled);

        if (candidates.length > 0) {
            candidates.sort((a, b) => a.effectiveFrom.getTime() - b.effectiveFrom.getTime());
            return candidates[candidates.length - 1];
        }

        if (active) return active;
        return defaultPolicy;
    }

    // 레거시: 문서 자체가 policy
    return parsePolicy(docData, fallback);
}

function evaluateReservation({
    now,
    policy,
    sessionDateString,
    startTime,
    capacity,
    reservedCount,
    enrollmentCanReserve,
    skipOpenPolicy = false,
    isBookingWeekOpened = false, // 관리자가 미리 열린 주차인지 여부
}: {
    now: Date;
    policy: CoursePolicy;
    sessionDateString: string;
    startTime: string;
    capacity: number;
    reservedCount: number;
    enrollmentCanReserve: boolean;
    skipOpenPolicy?: boolean;
    isBookingWeekOpened?: boolean;
}): ReservationEligibility {
    // 1) 과거 날짜 (가장 우선 체크)
    const todaySeoul = getSeoulDateTime();
    const todayString = `${todaySeoul.getFullYear()}-${pad2(todaySeoul.getMonth() + 1)}-${pad2(todaySeoul.getDate())}`;
    if (seoulDateOnly(sessionDateString).getTime() < seoulDateOnly(todayString).getTime()) {
        return { canReserve: false, reason: ReservationLockReason.pastDate };
    }

    // 2) 정원 마감
    if (reservedCount >= capacity) {
        return { canReserve: false, reason: ReservationLockReason.full };
    }

    // 3) 시작 N분 전 마감
    const { y, mo, d } = parseYYYYMMDD(sessionDateString);
    const { h, m } = parseHHmm(startTime);
    const sessionStart = makeSeoulDateTime(y, mo, d, h, m);
    const closeAt = new Date(sessionStart.getTime() - (policy.closeBeforeMinutes ?? 60) * 60_000);
    if (now.getTime() >= closeAt.getTime()) {
        return { canReserve: false, reason: ReservationLockReason.closedBeforeStart };
    }

    // 4) 오픈 정책 (skipOpenPolicy가 true이거나 미리 열린 주차이면 건너뛰기)
    if (!skipOpenPolicy && !isBookingWeekOpened) {
        const openAt = computeOpenAt({ policy, sessionDateString });
        if (openAt && now.getTime() < openAt.getTime()) {
            return { canReserve: false, reason: ReservationLockReason.notOpenedYet, openAt };
        }
    }

    // 5) 크레딧/유효기간 (마지막 체크)
    // 다른 체크를 먼저 수행하여 더 구체적인 오류 메시지를 제공
    if (!enrollmentCanReserve) {
        return { canReserve: false, reason: ReservationLockReason.noCreditsOrExpired };
    }

    return { canReserve: true, reason: ReservationLockReason.none };
}

/**
 * 예약 생성 시 sessionReservations 자동 업데이트
 * 
 * reservations 컬렉션에 새 문서가 생성되면:
 * 1. 해당 세션의 sessionReservations를 찾거나 생성
 * 2. reservedCount를 1 증가
 */
export const onReservationCreated = functions.firestore
    .document('places/{placeId}/reservations/{reservationId}')
    .onCreate(async (snap: QueryDocumentSnapshot, context: EventContext) => {
        // 단일 진실: 예약/정원/크레딧 업데이트는 "Callable 트랜잭션"에서만 수행.
        // (기존 트리거는 충돌/중복 카운트 위험 때문에 비활성화)
        console.log('[onReservationCreated] DISABLED (server callable transaction is the source of truth).');
        return;
        const reservation = snap.data();
        const reservationId = context.params.reservationId;

        try {
            // 세션 ID 생성: "courseId_dayOfWeek_startTime"
            const sessionId = `${reservation.courseId}_${reservation.dayOfWeek}_${reservation.startTime}`;

            // reservedDateString이 있으면 사용, 없으면 Timestamp를 서울 시간대로 변환
            let dateString: string;
            if (reservation.reservedDateString) {
                dateString = reservation.reservedDateString;
            } else if (reservation.reservedDate) {
                // Firestore Timestamp를 서울 시간대 기준으로 변환
                const timestamp = reservation.reservedDate as admin.firestore.Timestamp;
                dateString = formatTimestampToSeoulDate(timestamp);
            } else {
                throw new Error('reservedDateString or reservedDate is required');
            }

            console.log(`[onReservationCreated] reservationId: ${reservationId}, sessionId: ${sessionId}, date: ${dateString}`);

            // 1. 수강생 여부 검증 (서버 측 보안 검증)
            const enrollmentQuery = admin.firestore()
                .collection('enrollments')
                .where('userId', '==', reservation.userId)
                .where('courseId', '==', reservation.courseId)
                .limit(1);

            const enrollmentSnapshot = await enrollmentQuery.get();
            if (enrollmentSnapshot.empty) {
                throw new Error(`등록된 코스가 아닙니다. (userId: ${reservation.userId}, courseId: ${reservation.courseId})`);
            }

            const enrollmentData = enrollmentSnapshot.docs[0].data();
            const seoulNow = getSeoulDateTime();
            const validFrom = enrollmentData.validFrom?.toDate() || new Date();
            const validUntil = enrollmentData.validUntil?.toDate() || new Date();
            const remainingReservations = enrollmentData.remainingReservations || 0;

            // 유효 기간 및 남은 횟수 확인
            const isEnrollmentValid = seoulNow >= validFrom
                && seoulNow <= validUntil
                && remainingReservations > 0;

            if (!isEnrollmentValid) {
                throw new Error(
                    `예약 불가: 등록 기간이 만료되었거나 예약 가능한 횟수가 없습니다. ` +
                    `(validFrom: ${validFrom.toISOString()}, validUntil: ${validUntil.toISOString()}, ` +
                    `remainingReservations: ${remainingReservations})`
                );
            }

            // 2. 예약 가능 여부 검증 (세션 시작 1시간 전까지 예약 가능)
            const canReserve = await checkReservationAvailability(
                reservation.dayOfWeek,
                reservation.startTime,
                dateString
            );

            if (!canReserve) {
                const seoulNow = getSeoulDateTime();
                const [hour, minute] = reservation.startTime.split(':').map(Number);
                const sessionStartTime = new Date(
                    seoulNow.getFullYear(),
                    seoulNow.getMonth(),
                    seoulNow.getDate(),
                    hour,
                    minute
                );
                const oneHourBefore = new Date(sessionStartTime.getTime() - 60 * 60 * 1000);

                throw new Error(
                    `예약 불가: 세션 시작 1시간 전까지만 예약 가능합니다. ` +
                    `(현재: ${seoulNow.getHours()}:${String(seoulNow.getMinutes()).padStart(2, '0')}, ` +
                    `세션: ${reservation.startTime}, ` +
                    `마감: ${oneHourBefore.getHours()}:${String(oneHourBefore.getMinutes()).padStart(2, '0')})`
                );
            }

            // sessionReservations 컬렉션에서 해당 세션 찾기
            const sessionReservationQuery = admin.firestore()
                .collection('sessionReservations')
                .where('sessionId', '==', sessionId)
                .where('date', '==', dateString)
                .limit(1);

            const snapshot = await sessionReservationQuery.get();

            if (snapshot.empty) {
                // 첫 예약인 경우, sessionReservation 생성
                console.log(`[onReservationCreated] Creating new sessionReservation for ${sessionId}`);

                // Place에서 세션 정보 가져오기 (capacity 확인용)
                const placeDoc = await admin.firestore()
                    .collection('places')
                    .doc(reservation.placeId)
                    .get();

                if (!placeDoc.exists) {
                    throw new Error(`Place not found: ${reservation.placeId}`);
                }

                const place = placeDoc.data()!;
                const course = findCourse(place, reservation.courseId);
                if (!course) {
                    throw new Error(`Course not found: ${reservation.courseId}`);
                }

                const session = findSession(course, reservation.dayOfWeek, reservation.startTime);
                if (!session) {
                    throw new Error(`Session not found: ${reservation.dayOfWeek}, ${reservation.startTime}`);
                }

                // 날짜별 수용인원 확인 (dateCapacityOverrides 확인)
                const capacity = await getCapacityForDate(
                    reservation.placeId,
                    reservation.courseId,
                    reservation.dayOfWeek,
                    reservation.startTime,
                    dateString,
                    session.capacity
                );

                // 새 sessionReservation 생성
                const newSessionReservationRef = admin.firestore()
                    .collection('sessionReservations')
                    .doc();

                await newSessionReservationRef.set({
                    id: newSessionReservationRef.id,
                    sessionId,
                    courseId: reservation.courseId,
                    placeId: reservation.placeId,
                    dayOfWeek: reservation.dayOfWeek,
                    startTime: reservation.startTime,
                    date: dateString,
                    capacity,
                    reservedCount: 1,
                    lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });

                console.log(`[onReservationCreated] Created sessionReservation: ${newSessionReservationRef.id}`);
            } else {
                // 기존 sessionReservation 업데이트
                const doc = snapshot.docs[0];
                const currentData = doc.data();
                const newReservedCount = (currentData.reservedCount || 0) + 1;

                // 수용인원 초과 확인
                if (newReservedCount > currentData.capacity) {
                    console.warn(
                        `[onReservationCreated] Capacity exceeded for ${sessionId} on ${dateString}. ` +
                        `Current: ${newReservedCount}, Capacity: ${currentData.capacity}`
                    );
                    // 실제로는 예약을 거부해야 하지만, 이미 생성된 상태이므로 경고만
                }

                await doc.ref.update({
                    reservedCount: newReservedCount,
                    lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                });

                console.log(`[onReservationCreated] Updated sessionReservation: ${doc.id}, new count: ${newReservedCount}`);
            }
        } catch (error) {
            console.error(`[onReservationCreated] Error processing reservation ${reservationId}:`, error);

            // 검증 실패 시 예약 문서 삭제 (데이터 불일치 방지)
            try {
                const placeId = context.params.placeId;
                await admin.firestore()
                    .collection('places')
                    .doc(placeId)
                    .collection('reservations')
                    .doc(reservationId)
                    .delete();
                console.log(`[onReservationCreated] Deleted invalid reservation: ${reservationId}`);
            } catch (deleteError) {
                console.error(`[onReservationCreated] Failed to delete invalid reservation ${reservationId}:`, deleteError);
            }

            throw error;
        }
    });

/**
 * 예약 삭제 시 sessionReservations 자동 업데이트
 * 
 * reservations 컬렉션에서 문서가 삭제되면:
 * 1. 해당 세션의 sessionReservations를 찾기
 * 2. reservedCount를 1 감소
 */
export const onReservationDeleted = functions.firestore
    .document('places/{placeId}/reservations/{reservationId}')
    .onDelete(async (snap: QueryDocumentSnapshot, context: EventContext) => {
        console.log('[onReservationDeleted] DISABLED (server callable transaction is the source of truth).');
        return;
        const reservation = snap.data();
        const reservationId = context.params.reservationId;

        try {
            const sessionId = `${reservation.courseId}_${reservation.dayOfWeek}_${reservation.startTime}`;

            // reservedDateString이 있으면 사용, 없으면 Timestamp를 서울 시간대로 변환
            let dateString: string;
            if (reservation.reservedDateString) {
                dateString = reservation.reservedDateString;
            } else if (reservation.reservedDate) {
                const timestamp = reservation.reservedDate as admin.firestore.Timestamp;
                dateString = formatTimestampToSeoulDate(timestamp);
            } else {
                throw new Error('reservedDateString or reservedDate is required');
            }

            console.log(`[onReservationDeleted] reservationId: ${reservationId}, sessionId: ${sessionId}, date: ${dateString}`);

            // sessionReservations 찾기
            const sessionReservationQuery = admin.firestore()
                .collection('sessionReservations')
                .where('sessionId', '==', sessionId)
                .where('date', '==', dateString)
                .limit(1);

            const snapshot = await sessionReservationQuery.get();

            if (!snapshot.empty) {
                const doc = snapshot.docs[0];
                const currentData = doc.data();
                const newReservedCount = Math.max(0, (currentData.reservedCount || 0) - 1);

                await doc.ref.update({
                    reservedCount: newReservedCount,
                    lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                });

                console.log(`[onReservationDeleted] Updated sessionReservation: ${doc.id}, new count: ${newReservedCount}`);

                // reservedCount가 0이 되고 오래된 날짜면 삭제 (선택적)
                if (newReservedCount === 0) {
                    // 서울 시간대 기준으로 날짜 비교
                    const seoulNow = getSeoulDateTime();
                    const todayString = `${seoulNow.getFullYear()}-${pad2(seoulNow.getMonth() + 1)}-${pad2(seoulNow.getDate())}`;
                    const seoulToday = seoulDateOnly(todayString);
                    const reservationDate = seoulDateOnly(dateString);
                    const daysDiff = Math.floor((seoulToday.getTime() - reservationDate.getTime()) / (1000 * 60 * 60 * 24));

                    // 30일 이상 지난 경우 삭제
                    if (daysDiff > 30) {
                        await doc.ref.delete();
                        console.log(`[onReservationDeleted] Deleted old sessionReservation: ${doc.id}`);
                    }
                }
            } else {
                console.warn(`[onReservationDeleted] SessionReservation not found for ${sessionId} on ${dateString}`);
            }
        } catch (error) {
            console.error(`[onReservationDeleted] Error processing reservation ${reservationId}:`, error);
            throw error;
        }
    });

/**
 * 등록 정보 생성 시 courseMembers 자동 생성
 */
export const onEnrollmentCreated = functions.firestore
    .document('enrollments/{enrollmentId}')
    .onCreate(async (snap: QueryDocumentSnapshot, context: EventContext) => {
        const enrollment = snap.data();
        const enrollmentId = context.params.enrollmentId;

        try {
            // courseMembers 컬렉션에 추가
            await admin.firestore().collection('courseMembers').add({
                userId: enrollment.userId,
                courseId: enrollment.courseId,
                placeId: enrollment.placeId,
                enrollmentId: enrollmentId,
                enrolledAt: enrollment.enrolledAt || admin.firestore.FieldValue.serverTimestamp(),
                isActive: true,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            console.log(`[onEnrollmentCreated] Created courseMember for user ${enrollment.userId}, course ${enrollment.courseId}`);
        } catch (error) {
            console.error(`[onEnrollmentCreated] Error:`, error);
            throw error;
        }
    });

/**
 * 등록 정보 업데이트 시 courseMembers 동기화
 */
export const onEnrollmentUpdated = functions.firestore
    .document('enrollments/{enrollmentId}')
    .onUpdate(async (change: Change<QueryDocumentSnapshot>, context: EventContext) => {
        const after = change.after.data();
        const enrollmentId = context.params.enrollmentId;

        try {
            // isActive 상태 확인 (유효 기간 체크)
            // 서울 시간대 기준으로 현재 시간 사용
            const seoulNow = getSeoulDateTime();
            const validFrom = after.validFrom?.toDate() || new Date();
            const validUntil = after.validUntil?.toDate() || new Date();
            const isActive = seoulNow >= validFrom && seoulNow <= validUntil && (after.remainingReservations || 0) > 0;

            // courseMembers 찾기
            const courseMemberQuery = admin.firestore()
                .collection('courseMembers')
                .where('enrollmentId', '==', enrollmentId)
                .limit(1);

            const snapshot = await courseMemberQuery.get();

            if (!snapshot.empty) {
                const doc = snapshot.docs[0];
                await doc.ref.update({
                    isActive,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                });

                console.log(`[onEnrollmentUpdated] Updated courseMember: ${doc.id}, isActive: ${isActive}`);
            }
        } catch (error) {
            console.error(`[onEnrollmentUpdated] Error:`, error);
            throw error;
        }
    });

/**
 * 등록 정보 삭제 시 courseMembers 자동 삭제
 * 
 * enrollments 컬렉션에서 문서가 삭제되면:
 * 1. 해당 enrollmentId를 가진 courseMembers 문서 찾기
 * 2. courseMembers 문서 삭제
 */
export const onEnrollmentDeleted = functions.firestore
    .document('enrollments/{enrollmentId}')
    .onDelete(async (snap: QueryDocumentSnapshot, context: EventContext) => {

        const enrollmentId = context.params.enrollmentId;

        try {
            console.log(`[onEnrollmentDeleted] enrollmentId: ${enrollmentId}`);

            // courseMembers 컬렉션에서 해당 enrollmentId를 가진 문서 찾기
            const courseMemberQuery = admin.firestore()
                .collection('courseMembers')
                .where('enrollmentId', '==', enrollmentId)
                .limit(1);

            const snapshot = await courseMemberQuery.get();

            if (!snapshot.empty) {
                const doc = snapshot.docs[0];
                await doc.ref.delete();

                console.log(`[onEnrollmentDeleted] Deleted courseMember: ${doc.id} for enrollment ${enrollmentId}`);
            } else {
                console.warn(`[onEnrollmentDeleted] CourseMember not found for enrollmentId: ${enrollmentId}`);
            }
        } catch (error) {
            console.error(`[onEnrollmentDeleted] Error processing enrollment ${enrollmentId}:`, error);
            throw error;
        }
    });

/**
 * placeMemberships 생성 시 pendingMembers의 courseIds로 enrollments 자동 생성
 * 
 * 일반 유저가 로그인하여 placeMemberships가 생성되면,
 * 해당 pendingMembers의 courseIds를 읽어서 enrollments를 생성합니다.
 */
export const onPlaceMembershipCreated = functions.firestore
    .document('placeMemberships/{membershipId}')
    .onCreate(async (snap: QueryDocumentSnapshot, context: EventContext) => {
        const membership = snap.data();
        const membershipId = context.params.membershipId;
        const userId = membership.userId as string;
        const placeId = membership.placeId as string;
        const status = membership.status as string;

        // pending 상태인 경우 관리자에게 알림 전송
        if (status === 'pending') {
            try {
                // 사용자 정보 조회
                const userDoc = await admin.firestore().collection('users').doc(userId).get();
                if (!userDoc.exists) {
                    console.warn(`[onPlaceMembershipCreated] User not found: ${userId}`);
                } else {
                    const userData = userDoc.data();
                    const userName = userData?.name || '사용자';

                    // 플레이스 정보 조회
                    const placeDoc = await admin.firestore().collection('places').doc(placeId).get();
                    if (placeDoc.exists) {
                        const placeData = placeDoc.data();
                        const placeName = placeData?.name || '플레이스';

                        // 해당 플레이스의 모든 관리자 조회
                        const adminUsersSnapshot = await admin.firestore()
                            .collection('adminUsers')
                            .where('placeIds', 'array-contains', placeId)
                            .get();

                        if (!adminUsersSnapshot.empty) {
                            // 각 관리자에게 알림 생성
                            const notificationPromises = adminUsersSnapshot.docs.map((adminDoc) => {
                                const adminData = adminDoc.data();
                                const adminUserId = adminData.userId;

                                return createNotification({
                                    userId: adminUserId,
                                    type: 'system',
                                    title: '새 가입 요청',
                                    body: `${userName}님이 ${placeName} 가입을 요청했습니다`,
                                    placeId,
                                    data: {
                                        membershipId,
                                        userId,
                                        placeId,
                                    },
                                    isAdmin: true,
                                });
                            });

                            await Promise.all(notificationPromises);
                            console.log(`[onPlaceMembershipCreated] Created notifications for ${adminUsersSnapshot.docs.length} admins`);
                        }
                    }
                }
            } catch (error) {
                console.error(`[onPlaceMembershipCreated] Error creating notifications:`, error);
            }
            // pending 상태일 때는 enrollments 생성하지 않고 종료
            return;
        }

        // approved 상태일 때만 enrollments 생성
        if (status !== 'approved') {
            return;
        }

        try {
            logFunctionStart('onPlaceMembershipCreated', { membershipId });

            // pendingMembers에서 courseIds 찾기
            // 전화번호로 찾아야 하는데, placeMemberships에는 전화번호가 없음
            // pendingMembers는 placeId + phoneNumber 조합으로 찾아야 함
            // 하지만 placeMemberships에는 userId만 있음
            // 따라서 users 컬렉션에서 phoneNumber를 가져와야 함
            const userDoc = await admin.firestore().collection('users').doc(userId).get();
            if (!userDoc.exists) {
                logWarn('onPlaceMembershipCreated', { message: `User ${userId} not found` });
                return;
            }

            const userData = userDoc.data();
            const phoneNumber = userData?.phoneNumber as string | undefined;
            if (!phoneNumber) {
                logWarn('onPlaceMembershipCreated', { message: `User ${userId} has no phoneNumber` });
                return;
            }

            // pendingMembers에서 courseIds 찾기 (placeId + phoneNumber 조합)
            const pendingId = `${placeId}_${phoneNumber}`;
            const pendingDoc = await admin.firestore().collection('pendingMembers').doc(pendingId).get();

            if (!pendingDoc.exists) {
                logWarn('onPlaceMembershipCreated', { message: `No pendingMembers found for placeId ${placeId}, phoneNumber ${phoneNumber}` });
                return;
            }

            const pendingData = pendingDoc.data();

            // 새로운 구조: courseEnrollments 우선 사용 (없으면 기존 courseIds 사용)
            const courseEnrollments = pendingData?.courseEnrollments as any[] | undefined;
            const courseIds = courseEnrollments != null
                ? courseEnrollments.map((e: any) => e.courseId as string)
                : (pendingData?.courseIds as string[] | undefined);

            if (!courseIds || courseIds.length === 0) {
                logWarn('onPlaceMembershipCreated', { message: `No courseIds in pendingMembers for placeId ${placeId}` });
                return;
            }

            // 기존 enrollments 확인 (중복 방지)
            const existingEnrollmentsQuery = admin.firestore()
                .collection('enrollments')
                .where('userId', '==', userId)
                .where('placeId', '==', placeId)
                .where('courseId', 'in', courseIds);

            const existingEnrollmentsSnapshot = await existingEnrollmentsQuery.get();
            const existingCourseIds = new Set(
                existingEnrollmentsSnapshot.docs.map(doc => doc.data().courseId as string)
            );

            // enrollments 생성
            // place에서 course 정보 가져오기 (defaultTotalReservations 사용)
            const placeDoc = await admin.firestore().collection('places').doc(placeId).get();
            if (!placeDoc.exists) {
                logWarn('onPlaceMembershipCreated', { message: `Place ${placeId} not found` });
                return;
            }

            const placeData = placeDoc.data();
            const courses = (placeData?.courses as any[]) || [];

            const enrollmentTime = admin.firestore.Timestamp.now();
            const batch = admin.firestore().batch();
            let createdCount = 0;

            for (const courseId of courseIds) {
                // 이미 등록된 코스는 스킵
                if (existingCourseIds.has(courseId)) {
                    continue;
                }

                // courseEnrollments에서 개별 설정 가져오기
                let enrollmentConfig: any = null;
                if (courseEnrollments != null) {
                    enrollmentConfig = courseEnrollments.find((e: any) => e.courseId === courseId);
                }

                // Course에서 기본값 가져오기
                const course = courses.find((c: any) => c.id === courseId);
                const defaultTotalReservations = course?.defaultTotalReservations ?? 10;

                // 개별 설정 또는 기본값 사용
                const totalReservations = enrollmentConfig?.totalReservations as number | undefined
                    ?? defaultTotalReservations;

                // 유효기간 설정
                let validFrom: Date;
                let validUntil: Date;
                if (enrollmentConfig?.validFrom) {
                    validFrom = new Date(enrollmentConfig.validFrom);
                } else {
                    validFrom = enrollmentTime.toDate();
                }

                if (enrollmentConfig?.validUntil) {
                    validUntil = new Date(enrollmentConfig.validUntil);
                } else {
                    validUntil = new Date(enrollmentTime.toDate());
                    validUntil.setFullYear(validUntil.getFullYear() + 1); // 기본값: 1년 후
                }

                const enrollmentRef = admin.firestore().collection('enrollments').doc();
                batch.set(enrollmentRef, {
                    userId: userId,
                    courseId: courseId,
                    placeId: placeId,
                    enrolledAt: enrollmentTime,
                    validFrom: admin.firestore.Timestamp.fromDate(validFrom),
                    validUntil: admin.firestore.Timestamp.fromDate(validUntil),
                    totalReservations: totalReservations,
                    remainingReservations: totalReservations,
                });

                createdCount++;
            }

            if (createdCount > 0) {
                await batch.commit();
                logFunctionSuccess('onPlaceMembershipCreated', { message: `Created ${createdCount} enrollments for user ${userId}, place ${placeId}` });
            } else {
                logWarn('onPlaceMembershipCreated', { message: `No enrollments created (all already exist) for user ${userId}, place ${placeId}` });
            }

            // pendingMembers 삭제 (enrollments 생성 완료 후)
            // enrollments가 생성되었거나 이미 존재하는 경우, pendingMembers는 더 이상 필요 없음
            await pendingDoc.ref.delete();
            logFunctionSuccess('onPlaceMembershipCreated', { message: `Deleted pendingMembers ${pendingId} after enrollment creation` });
        } catch (error) {
            logFunctionError('onPlaceMembershipCreated', error, { membershipId });
            throw error;
        }
    });

/**
 * 주기적 데이터 검증 (매일 새벽 2시)
 * 
 * sessionReservations의 reservedCount와 실제 reservations 수를 비교하여
 * 불일치가 있으면 자동으로 수정
 */
export const validateDataConsistency = functions.pubsub
    .schedule('every 24 hours')
    .timeZone('Asia/Seoul')
    .onRun(async (context: EventContext) => {
        console.log('[validateDataConsistency] DISABLED (server callable transaction is the source of truth).');
        return;
        console.log('[validateDataConsistency] Starting data validation...');

        try {
            // 서울 시간대 기준으로 7일 전 계산
            const seoulNow = getSeoulDateTime();
            const sevenDaysAgo = new Date(seoulNow.getTime() - 7 * 24 * 60 * 60 * 1000);

            const sessionReservations = await admin.firestore()
                .collection('sessionReservations')
                .where('lastUpdated', '>', admin.firestore.Timestamp.fromDate(sevenDaysAgo))
                .get();

            let fixedCount = 0;
            let errorCount = 0;

            for (const doc of sessionReservations.docs) {
                try {
                    const data = doc.data();

                    // 실제 reservations 수 계산 (플레이스 서브컬렉션에서 조회)
                    const placeId = data.placeId || '';
                    if (!placeId) {
                        console.warn('[validateDataConsistency] placeId가 없어 예약 검증을 건너뜁니다.');
                        continue;
                    }
                    const actualReservations = await admin.firestore()
                        .collection('places')
                        .doc(placeId)
                        .collection('reservations')
                        .where('courseId', '==', data.courseId)
                        .where('dayOfWeek', '==', data.dayOfWeek)
                        .where('startTime', '==', data.startTime)
                        .where('reservedDateString', '==', data.date)
                        .get();

                    const actualCount = actualReservations.size;
                    const expectedCount = data.reservedCount || 0;

                    if (actualCount !== expectedCount) {
                        console.warn(
                            `[validateDataConsistency] Mismatch found: ${data.sessionId} on ${data.date}. ` +
                            `Expected: ${expectedCount}, Actual: ${actualCount}`
                        );

                        // 자동 수정
                        await doc.ref.update({
                            reservedCount: actualCount,
                            lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                            _lastValidated: admin.firestore.FieldValue.serverTimestamp(),
                            _validationFixed: true,
                        });

                        fixedCount++;

                        // 관리자에게 알림 전송
                        try {
                            const placeId = data.placeId as string;
                            const sessionId = data.sessionId as string;
                            const date = data.date as string;

                            // 해당 플레이스의 모든 관리자 조회
                            const adminUsersSnapshot = await admin.firestore()
                                .collection('adminUsers')
                                .where('placeIds', 'array-contains', placeId)
                                .get();

                            if (!adminUsersSnapshot.empty) {
                                const notificationPromises = adminUsersSnapshot.docs.map((adminDoc) => {
                                    const adminData = adminDoc.data();
                                    const adminUserId = adminData.userId;

                                    return createNotification({
                                        userId: adminUserId,
                                        type: 'system',
                                        title: '데이터 불일치 감지',
                                        body: `${sessionId}의 예약 수가 일치하지 않습니다 (${date}). 자동으로 수정되었습니다.`,
                                        placeId,
                                        data: {
                                            sessionId,
                                            date,
                                            placeId,
                                            expectedCount,
                                            actualCount,
                                        },
                                        isAdmin: true,
                                    });
                                });

                                await Promise.all(notificationPromises);
                            }
                        } catch (alertError) {
                            console.error(`[validateDataConsistency] Error sending alert:`, alertError);
                        }
                    }
                } catch (error) {
                    console.error(`[validateDataConsistency] Error validating ${doc.id}:`, error);
                    errorCount++;
                }
            }

            console.log(
                `[validateDataConsistency] Validation completed. ` +
                `Checked: ${sessionReservations.size}, Fixed: ${fixedCount}, Errors: ${errorCount}`
            );
        } catch (error) {
            console.error('[validateDataConsistency] Fatal error:', error);
            throw error;
        }
    });

// ==================== Helper Functions ====================

/**
 * 서울 시간대 설정
 */
const SEOUL_TIMEZONE = 'Asia/Seoul';

/**
 * Date 객체를 서울 시간대 기준으로 "YYYY-MM-DD" 형식으로 변환
 */
function formatDateToSeoul(date: Date): string {
    // UTC Timestamp를 서울 시간대로 변환
    const seoulDate = new Date(date.toLocaleString('en-US', { timeZone: SEOUL_TIMEZONE }));
    return formatDate(seoulDate);
}

/**
 * 날짜를 "YYYY-MM-DD" 형식으로 변환 (로컬 시간 기준)
 */
function formatDate(date: Date): string {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

/**
 * Firestore Timestamp를 서울 시간대 기준 날짜 문자열로 변환
 */
function formatTimestampToSeoulDate(timestamp: admin.firestore.Timestamp): string {
    const date = timestamp.toDate();
    return formatDateToSeoul(date);
}

/**
 * Place에서 Course 찾기
 */
// Place -> Course 조회는 functions/src/course_catalog.ts 로 이동

/**
 * Course에서 Session 찾기
 */
function findSession(course: any, dayOfWeek: number, startTime: string): any {
    if (!course.sessions || !Array.isArray(course.sessions)) {
        return null;
    }
    return course.sessions.find(
        (s: any) => s.dayOfWeek === dayOfWeek && s.startTime === startTime
    ) || null;
}

/**
 * 서울 시간대 기준 현재 시간 가져오기 (정확한 시:분 포함)
 */
function getSeoulDateTime(): Date {
    const now = new Date();
    // UTC 시간을 서울 시간대로 변환 (UTC+9)
    const seoulOffset = 9 * 60; // 9시간 = 540분
    const utcTime = now.getTime() + (now.getTimezoneOffset() * 60000);
    const seoulTime = new Date(utcTime + (seoulOffset * 60000));
    return seoulTime;
}

/**
 * 예약 가능 여부 검증 (세션 시작 1시간 전까지 예약 가능)
 * 
 * - 과거 날짜: 예약 불가
 * - 오늘 날짜: 세션 시작 1시간 전까지 예약 가능 (정확한 시:분 비교)
 * - 미래 날짜: 예약 가능 (자리가 있으면)
 */
async function checkReservationAvailability(
    dayOfWeek: number,
    startTime: string,
    dateString: string
): Promise<boolean> {
    // 서울 시간대 기준 현재 시간 (정확한 시:분 포함)
    const seoulNow = getSeoulDateTime();

    // 오늘 날짜 (서울 시간대 기준, 시간 제거)
    const todayString = `${seoulNow.getFullYear()}-${pad2(seoulNow.getMonth() + 1)}-${pad2(seoulNow.getDate())}`;
    const seoulToday = seoulDateOnly(todayString);

    // 예약 날짜 (서울 시간대 기준, 시간 제거)
    const reservationDateOnly = seoulDateOnly(dateString);

    // 날짜 비교
    const isToday = reservationDateOnly.getTime() === seoulToday.getTime();
    const isFuture = reservationDateOnly.getTime() > seoulToday.getTime();

    if (isFuture) {
        // 미래 날짜는 항상 예약 가능 (자리가 있으면)
        return true;
    }

    if (isToday) {
        // 오늘인 경우: 세션 시작 1시간 전까지 예약 가능
        // startTime 형식: "HH:MM" (예: "13:00")
        const [hour, minute] = startTime.split(':').map(Number);

        if (isNaN(hour) || isNaN(minute)) {
            console.error(`[checkReservationAvailability] Invalid startTime format: ${startTime}`);
            return false;
        }

        // 세션 시작 시간 (서울 시간대 기준, 오늘 날짜)
        const sessionStartTime = makeSeoulDateTime(
            seoulNow.getFullYear(),
            seoulNow.getMonth() + 1,
            seoulNow.getDate(),
            hour,
            minute
        );

        // 세션 시작 1시간 전 (정확한 시:분:초)
        const oneHourBefore = new Date(sessionStartTime.getTime() - 60 * 60 * 1000);

        // 현재 시간이 세션 시작 1시간 전보다 이전이어야 함
        const canReserve = seoulNow < oneHourBefore;

        if (!canReserve) {
            console.log(
                `[checkReservationAvailability] Reservation too late. ` +
                `Now: ${seoulNow.toISOString()}, ` +
                `Session: ${sessionStartTime.toISOString()}, ` +
                `OneHourBefore: ${oneHourBefore.toISOString()}`
            );
        }

        return canReserve;
    }

    // 과거 날짜는 예약 불가
    return false;
}

/**
 * 특정 날짜의 수용인원 가져오기
 * dateCapacityOverrides를 확인하고, 없으면 기본 capacity 반환
 */
async function getCapacityForDate(
    placeId: string,
    courseId: string,
    dayOfWeek: number,
    startTime: string,
    dateString: string,
    defaultCapacity: number
): Promise<number> {
    const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;

    // dateCapacityOverrides 확인
    const overrideQuery = admin.firestore()
        .collection('dateCapacityOverrides')
        .where('sessionId', '==', sessionId)
        .where('date', '==', dateString)
        .limit(1);

    const snapshot = await overrideQuery.get();

    if (!snapshot.empty) {
        return snapshot.docs[0].data().capacity;
    }

    return defaultCapacity;
}

/**
 * 전화번호 정규화 (숫자만 추출, 국가코드 처리)
 */
function normalizePhoneNumber(phoneNumber: string): string {
    // 숫자만 추출
    let normalized = phoneNumber.replace(/\D/g, '');

    // +82로 시작하는 경우 0으로 변환
    if (normalized.startsWith('82')) {
        normalized = '0' + normalized.substring(2);
    }

    // 0으로 시작하지 않으면 0 추가
    if (!normalized.startsWith('0')) {
        normalized = '0' + normalized;
    }

    return normalized;
}

/**
 * 관리자 PIN 인증
 * 
 * 전화번호와 PIN을 받아서 adminUsers 컬렉션에서 확인
 * PIN이 맞으면 성공, 틀리면 에러 반환
 */
export const authenticateAdmin = functions.https.onCall(async (data, context) => {
    const { phoneNumber, verificationCode, pin } = data;

    console.log('[authenticateAdmin] Received data:', {
        phoneNumber: phoneNumber ? `${phoneNumber.substring(0, 3)}***` : 'null',
        verificationCode: verificationCode ? '***' : 'null',
        pin: pin ? '***' : 'null',
        pinLength: pin ? pin.length : 0,
    });

    // 입력 검증 (verificationCode는 빈 문자열일 수 있음 - waiting 화면에서 관리자로 진행하기)
    if (!phoneNumber || !pin) {
        console.error('[authenticateAdmin] Missing required fields:', { phoneNumber: !!phoneNumber, pin: !!pin });
        throw new functions.https.HttpsError(
            'invalid-argument',
            'phoneNumber, pin이 모두 필요합니다.'
        );
    }

    try {
        // 전화번호 정규화
        const normalizedPhone = normalizePhoneNumber(phoneNumber);
        console.log(`[authenticateAdmin] Phone normalization - Original: "${phoneNumber}", Normalized: "${normalizedPhone}"`);
        console.log(`[authenticateAdmin] PIN received - Length: ${pin.length}, Value: "${pin}"`);

        // 1. adminUsers에서 전화번호로 관리자 찾기
        const adminQuery = admin.firestore()
            .collection('adminUsers')
            .where('phoneNumber', '==', normalizedPhone)
            .limit(1);

        const adminSnapshot = await adminQuery.get();

        if (adminSnapshot.empty) {
            console.error(`[authenticateAdmin] Admin not found for phone: "${normalizedPhone}"`);
            throw new functions.https.HttpsError(
                'not-found',
                '관리자로 등록되지 않은 전화번호입니다.'
            );
        }

        const adminDoc = adminSnapshot.docs[0];
        const adminData = adminDoc.data();

        console.log(`[authenticateAdmin] Found admin - ID: ${adminDoc.id}, userId: ${adminData.userId}`);
        console.log(`[authenticateAdmin] PIN comparison - Stored: "${adminData.authPin}" (type: ${typeof adminData.authPin}, length: ${String(adminData.authPin).length}), Input: "${pin}" (type: ${typeof pin}, length: ${pin.length})`);

        // 3. PIN 확인
        if (!adminData.authPin) {
            console.error('[authenticateAdmin] PIN not set for admin');
            throw new functions.https.HttpsError(
                'failed-precondition',
                'PIN이 등록되지 않았습니다. PIN 등록이 필요합니다.'
            );
        }

        // PIN 검증 (문자열로 변환하여 비교, 공백 제거)
        const storedPin = String(adminData.authPin).trim();
        const inputPin = String(pin).trim();

        console.log(`[authenticateAdmin] PIN comparison after trim - Stored: "${storedPin}" (length: ${storedPin.length}), Input: "${inputPin}" (length: ${inputPin.length}), Match: ${storedPin === inputPin}`);
        console.log(`[authenticateAdmin] PIN character codes - Stored: [${Array.from(storedPin).map(c => c.charCodeAt(0)).join(', ')}], Input: [${Array.from(inputPin).map(c => c.charCodeAt(0)).join(', ')}]`);

        if (storedPin !== inputPin) {
            console.error(`[authenticateAdmin] PIN mismatch - Stored: "${storedPin}", Input: "${inputPin}"`);
            throw new functions.https.HttpsError(
                'permission-denied',
                'PIN이 올바르지 않습니다.'
            );
        }

        console.log('[authenticateAdmin] PIN verification successful');

        // 4. 성공 - 관리자 정보 반환
        return {
            success: true,
            userId: adminData.userId,
            name: adminData.name,
            phoneNumber: adminData.phoneNumber,
            placeIds: adminData.placeIds || [],
        };
    } catch (error) {
        // 이미 HttpsError인 경우 그대로 throw
        if (error instanceof functions.https.HttpsError) {
            throw error;
        }

        // 기타 에러는 내부 서버 에러로 변환
        console.error('[authenticateAdmin] Error:', error);
        throw new functions.https.HttpsError(
            'internal',
            '관리자 인증 중 오류가 발생했습니다.',
            error
        );
    }
});

/**
 * 관리자 PIN 등록 (서버에서 adminUsers 문서 생성/업데이트)
 *
 * - 클라이언트는 Firestore rules상 adminUsers를 직접 create/update 할 수 없으므로(권한 상승 위험)
 *   Callable Function + Admin SDK로만 등록한다.
 * - 현재 로그인된 Firebase Auth 사용자(context.auth.uid)의 phoneNumber와 입력 phoneNumber가 일치할 때만 허용.
 */
export const registerAdminPin = functions.https.onCall(async (data, context) => {
    const functionName = 'registerAdminPin';
    logFunctionStart(functionName, { userId: context.auth?.uid });

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const uid = context.auth.uid;
    const phoneNumber = String(data?.phoneNumber ?? '');
    const name = String(data?.name ?? '관리자');
    const pin = String(data?.pin ?? '');

    if (!phoneNumber || !pin) {
        throw new functions.https.HttpsError('invalid-argument', 'phoneNumber, pin이 필요합니다.');
    }
    if (pin.trim().length !== 6) {
        throw new functions.https.HttpsError('invalid-argument', 'PIN은 6자리여야 합니다.');
    }

    const normalizedPhone = normalizePhoneNumber(phoneNumber);

    // Firebase Auth 사용자 phoneNumber와 일치하는지 확인
    let authPhone = '';
    try {
        const userRecord = await admin.auth().getUser(uid);
        authPhone = userRecord.phoneNumber ? normalizePhoneNumber(userRecord.phoneNumber) : '';
    } catch (e) {
        // userRecord 조회 실패 시에도 진행은 막는다(안전)
        throw new functions.https.HttpsError('internal', '사용자 정보를 확인할 수 없습니다.');
    }

    if (authPhone && normalizedPhone && authPhone !== normalizedPhone) {
        throw new functions.https.HttpsError('permission-denied', '전화번호가 일치하지 않습니다.');
    }

    const db = admin.firestore();
    const adminRef = db.collection('adminUsers').doc(uid);
    const adminSnap = await adminRef.get();
    const existing = adminSnap.exists ? (adminSnap.data() as any) : null;

    // 이미 PIN이 등록된 관리자인 경우(루프 방지용)
    if (existing?.authPin && String(existing.authPin).trim().length > 0) {
        throw new functions.https.HttpsError('already-exists', '이미 등록된 관리자입니다.');
    }

    const placeIds = Array.isArray(existing?.placeIds) ? existing.placeIds : [];

    await adminRef.set(
        {
            userId: uid,
            name,
            phoneNumber: normalizedPhone,
            authPin: pin.trim(),
            placeIds,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            ...(adminSnap.exists ? {} : { createdAt: admin.firestore.FieldValue.serverTimestamp() }),
        },
        { merge: true },
    );

    logFunctionSuccess(functionName, { userId: uid });
    return { success: true, userId: uid, name, phoneNumber: normalizedPhone, placeIds };
});

/**
 * ==================== Reservations (Callable, Source of Truth) ====================
 *
 * rollingWindow / weeklyRelease 반영 방법:
 * - "어떤 문서를 업데이트해서 오픈시킨다"가 아니라
 * - 예약 시점(now)에 policy로 openAt을 계산하고, now < openAt이면 거절한다.
 *
 * 즉, 오픈은 '상태 업데이트'가 아니라 '계산'이다(정합성 최강).
 */

export const createReservation = functions.https.onCall(async (data, context) => {
    const functionName = 'createReservation';
    logFunctionStart(functionName, { userId: context.auth?.uid, ...data });

    if (!context.auth?.uid) {
        logFunctionError(functionName, new Error('Unauthenticated'), { data });
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const callerId = context.auth.uid;
    const placeId = String(data?.placeId ?? '');
    const courseId = String(data?.courseId ?? '');
    const dayOfWeek = Number(data?.dayOfWeek ?? 0);
    const startTime = String(data?.startTime ?? '');
    const reservedDateString = String(data?.reservedDateString ?? '');
    const force = data?.force === true; // 관리자 강제 추가(명시적 확인을 거친 경우에만 true)

    // 관리자가 다른 사용자를 위해 예약 생성 시 userId 파라미터 사용
    // 없으면 호출자 본인의 예약 생성
    const requestedUserId = String(data?.userId ?? '').trim();
    let userId: string;
    let isAdminCreatingForUser = false;

    if (requestedUserId && requestedUserId !== callerId) {
        // 다른 사용자를 위해 예약 생성 시도 - 관리자 권한 확인
        if (!requestedUserId || requestedUserId.length === 0) {
            throw new functions.https.HttpsError('invalid-argument', '유효하지 않은 userId입니다.');
        }
        try {
            await assertAdminUid(callerId);
            userId = requestedUserId;
            isAdminCreatingForUser = true;
            console.log(`[createReservation] Admin ${callerId} creating reservation for user ${userId}`);
        } catch (error) {
            logFunctionError(functionName, error as Error, { callerId, requestedUserId });
            throw new functions.https.HttpsError('permission-denied', '다른 사용자를 위해 예약을 생성할 권한이 없습니다.');
        }
    } else {
        // 본인 예약 생성
        userId = callerId;
    }

    // userId 검증 (최종 확인)
    if (!userId || userId.length === 0) {
        logFunctionError(functionName, new Error('Invalid userId'), { callerId, requestedUserId, userId });
        throw new functions.https.HttpsError('invalid-argument', '유효하지 않은 userId입니다.');
    }

    if (!placeId || !courseId || !startTime || !reservedDateString || !Number.isFinite(dayOfWeek)) {
        logFunctionError(functionName, new Error('Invalid arguments'), { placeId, courseId, dayOfWeek, startTime, reservedDateString });
        throw new functions.https.HttpsError('invalid-argument', 'placeId, courseId, dayOfWeek, startTime, reservedDateString이 필요합니다.');
    }



    const db = admin.firestore();
    const seoulNow = getSeoulDateTime();
    const now = seoulNow; // 서울 시간대 통일 (클라이언트와 일관성 유지)

    const policyRef = db.collection('coursePolicies').doc(courseId);
    const placeRef = db.collection('places').doc(placeId);

    // 동일 유저 중복 예약 방지(최소한)
    // (트랜잭션 내 query를 지원하므로 transaction.get(query)로 처리)

    try {
        return await db.runTransaction(async (tx) => {
            // 1) enrollment 검증 (pending 멤버는 pendingMembers에서 조회)
            const isPendingMember = userId.startsWith('pending_');
            let remainingReservations: number;
            let validFrom: Date;
            let validUntil: Date;
            let enrollmentDoc: admin.firestore.QueryDocumentSnapshot | null = null;
            // pending 멤버의 경우 이미 읽은 문서를 나중에 재사용하기 위해 저장
            let pendingDocForUpdate: admin.firestore.DocumentSnapshot | null = null;
            let pendingDataForUpdate: any = null;

            if (isPendingMember) {
                // pending 멤버: pendingMembers에서 조회
                // userId 형식: "pending_placeId_phoneNumber" 또는 "pending_pendingId"
                // pendingId는 "placeId_phoneNumber" 형식
                const pendingId = userId.replace('pending_', '');
                const pendingRef = db.collection('pendingMembers').doc(pendingId);
                const pendingDoc = await tx.get(pendingRef);

                if (!pendingDoc.exists) {
                    throw new functions.https.HttpsError('failed-precondition', '등록된 코스가 아닙니다.');
                }

                const pendingData = pendingDoc.data() as any;
                // 나중에 업데이트할 때 재사용하기 위해 저장
                pendingDocForUpdate = pendingDoc;
                pendingDataForUpdate = pendingData;
                const courseEnrollments = pendingData?.courseEnrollments as any[] | undefined;

                if (!courseEnrollments || courseEnrollments.length === 0) {
                    throw new functions.https.HttpsError('failed-precondition', '등록된 코스가 아닙니다.');
                }

                // 해당 코스의 enrollment 찾기
                const courseEnrollment = courseEnrollments.find((ce: any) => ce?.courseId === courseId);
                if (!courseEnrollment) {
                    throw new functions.https.HttpsError('failed-precondition', '등록된 코스가 아닙니다.');
                }

                // remainingReservations가 없으면 totalReservations를 사용 (하위 호환성)
                const totalReservations = Number(courseEnrollment?.totalReservations ?? 0);
                remainingReservations = Number(courseEnrollment?.remainingReservations ?? totalReservations);
                const validFromRaw = courseEnrollment?.validFrom;
                const validUntilRaw = courseEnrollment?.validUntil;
                const createdAtRaw = pendingData?.createdAt;
                const createdAtDate =
                    (createdAtRaw instanceof admin.firestore.Timestamp)
                        ? createdAtRaw.toDate()
                        : (typeof createdAtRaw === 'string')
                            ? new Date(createdAtRaw)
                            : (createdAtRaw instanceof Date)
                                ? createdAtRaw
                                : new Date(0);

                if (validFromRaw instanceof admin.firestore.Timestamp) {
                    validFrom = validFromRaw.toDate();
                } else if (typeof validFromRaw === 'string') {
                    validFrom = new Date(validFromRaw);
                } else {
                    validFrom = createdAtDate;
                }

                if (validUntilRaw instanceof admin.firestore.Timestamp) {
                    validUntil = validUntilRaw.toDate();
                } else if (typeof validUntilRaw === 'string') {
                    validUntil = new Date(validUntilRaw);
                } else {
                    validUntil = new Date(createdAtDate);
                    validUntil.setFullYear(validUntil.getFullYear() + 1);
                }
            } else {
                // 일반 멤버: enrollments에서 조회
                const enrollmentQuery = db
                    .collection('enrollments')
                    .where('userId', '==', userId)
                    .where('courseId', '==', courseId)
                    .limit(1);

                const enrollmentSnap = await tx.get(enrollmentQuery as any);
                if (enrollmentSnap.empty) {
                    throw new functions.https.HttpsError('failed-precondition', '등록된 코스가 아닙니다.');
                }
                enrollmentDoc = enrollmentSnap.docs[0] as admin.firestore.QueryDocumentSnapshot;
                const enrollmentData = enrollmentDoc.data() as any;
                remainingReservations = Number((enrollmentData?.remainingReservations ?? 0) as any);
                validFrom = (enrollmentData?.validFrom instanceof admin.firestore.Timestamp)
                    ? enrollmentData.validFrom.toDate()
                    : (enrollmentData?.validFrom ? new Date(enrollmentData.validFrom) : new Date(0));
                validUntil = (enrollmentData?.validUntil instanceof admin.firestore.Timestamp)
                    ? enrollmentData.validUntil.toDate()
                    : (enrollmentData?.validUntil ? new Date(enrollmentData.validUntil) : new Date(0));
            }

            // 날짜만 비교 (시간 무시) - validUntil 당일까지 예약 가능
            // 서울 시간대 기준으로 날짜만 추출
            const todayString = `${seoulNow.getFullYear()}-${pad2(seoulNow.getMonth() + 1)}-${pad2(seoulNow.getDate())}`;
            const today = seoulDateOnly(todayString);

            // validFrom, validUntil도 서울 시간대 기준으로 날짜만 추출
            const validFromString = `${validFrom.getFullYear()}-${pad2(validFrom.getMonth() + 1)}-${pad2(validFrom.getDate())}`;
            const validUntilString = `${validUntil.getFullYear()}-${pad2(validUntil.getMonth() + 1)}-${pad2(validUntil.getDate())}`;
            const validFromDate = seoulDateOnly(validFromString);
            const validUntilDate = seoulDateOnly(validUntilString);

            const enrollmentCanReserve =
                today >= validFromDate && today <= validUntilDate && remainingReservations > 0;

            console.log(`[createReservation] enrollment check: userId=${userId}, isPending=${isPendingMember}, remainingReservations=${remainingReservations}, today=${todayString}, validFrom=${validFromString}, validUntil=${validUntilString}, canReserve=${enrollmentCanReserve}`);

            // 2) place + course + session
            const placeDoc = await tx.get(placeRef);
            if (!placeDoc.exists) {
                throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
            }
            const place = placeDoc.data()!;
            const course = findCourse(place, courseId);
            if (!course) {
                throw new functions.https.HttpsError('not-found', '코스를 찾을 수 없습니다.');
            }
            // 3) 정책 로드(active/scheduled/effectiveFrom)
            const policyDoc = await tx.get(policyRef);
            const policyData = policyDoc.exists ? (policyDoc.data() as CoursePolicyDoc) : null;
            const policy = selectEffectivePolicy(now, policyData, { courseId, placeId });

            // 4) 세션 찾기 (정기 일정 또는 비정기 일정)
            const session = findSession(course, dayOfWeek, startTime);
            const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
            let capacity: number;
            let isOverrideSession = false; // override 세션인지 여부

            if (!session) {
                // 정기 일정이 없으면 비정기 일정(courseOverrides) 확인
                const overrideQuery = db
                    .collection('courseOverrides')
                    .where('courseId', '==', courseId)
                    .where('placeId', '==', placeId)
                    .where('date', '==', reservedDateString)
                    .where('dayOfWeek', '==', dayOfWeek)
                    .where('startTime', '==', startTime)
                    .where('isCancelled', '==', false)
                    .limit(1);
                const overrideSnap = await tx.get(overrideQuery as any);

                if (overrideSnap.empty) {
                    throw new functions.https.HttpsError('not-found', '세션을 찾을 수 없습니다.');
                }

                const overrideData = overrideSnap.docs[0].data() as any;
                capacity = Number(overrideData?.capacity ?? 0);
                isOverrideSession = true; // override 세션으로 표시
            } else {
                // 정기 일정인 경우 capacity 확인 (dateCapacityOverrides 우선)
                const overrideQuery = db
                    .collection('dateCapacityOverrides')
                    .where('placeId', '==', placeId)
                    .where('sessionId', '==', sessionId)
                    .where('date', '==', reservedDateString)
                    .limit(1);
                const overrideSnap = await tx.get(overrideQuery as any);
                const overrideCap = !overrideSnap.empty
                    ? Number(((overrideSnap.docs[0].data() as any)?.capacity ?? 0) as any)
                    : undefined;
                capacity = Number.isFinite(overrideCap) ? (overrideCap as number) : Number(session.capacity ?? 0);
            }

            // 5) sessionReservations (deterministic doc id)
            const srRef = db.collection('sessionReservations').doc(`${sessionId}_${reservedDateString}`);
            const srDoc = await tx.get(srRef);
            const currentReservedCount = srDoc.exists ? Number(srDoc.data()?.reservedCount ?? 0) : 0;
            const isCancelled = srDoc.exists ? Boolean((srDoc.data() as any)?.isCancelled ?? false) : false;
            if (isCancelled) {
                throw new functions.https.HttpsError('failed-precondition', '취소된 세션입니다.');
            }

            // 6) 중복 예약(유저가 이미 같은 세션/날짜 예약) - 플레이스 서브컬렉션에서 조회
            const dupQuery = db
                .collection('places')
                .doc(placeId)
                .collection('reservations')
                .where('userId', '==', userId)
                .where('courseId', '==', courseId)
                .where('dayOfWeek', '==', dayOfWeek)
                .where('startTime', '==', startTime)
                .where('reservedDateString', '==', reservedDateString)
                .limit(1);
            const dupSnap = await tx.get(dupQuery as any);
            if (!dupSnap.empty) {
                throw new functions.https.HttpsError('already-exists', '이미 예약된 세션입니다.');
            }

            // 7) 미리 열린 주차 확인 (관리자가 미리 예약 열기한 주차인지)
            const reservedDate = seoulDateOnly(reservedDateString);
            const weekStart = startOfWeekMondaySeoul(reservedDateString);
            const weekStartDateString = `${weekStart.getUTCFullYear()}-${pad2(weekStart.getUTCMonth() + 1)}-${pad2(weekStart.getUTCDate())}`;
            const bookingWeekOpenDocId = `${placeId}_${courseId}_${weekStartDateString}`;
            const bookingWeekOpenDoc = await tx.get(db.collection('bookingWeekOpens').doc(bookingWeekOpenDocId));
            const isBookingWeekOpened = bookingWeekOpenDoc.exists;

            // 8) 중앙 정책 엔진(서버 버전)으로 최종 검증
            // 관리자가 다른 사용자를 위해 예약 생성 시: 정원 초과/오픈 전/마감 전은 허용, 과거 날짜만 차단
            // ⚠️ override 세션(비정기 일정)인 경우 오픈 정책을 건너뛰고 즉시 예약 가능하도록 함
            // ⚠️ 미리 열린 주차인 경우도 오픈 정책을 건너뛰고 즉시 예약 가능하도록 함
            const eligibility = evaluateReservation({
                now,
                policy,
                sessionDateString: reservedDateString,
                startTime,
                capacity,
                reservedCount: currentReservedCount,
                enrollmentCanReserve,
                // override 세션이거나 "미리 열린 주차"면 오픈 정책을 건너뛰기
                skipOpenPolicy: isOverrideSession || isBookingWeekOpened,
                isBookingWeekOpened,
            });

            if (!eligibility.canReserve) {
                if (isAdminCreatingForUser) {
                    // ✅ 관리자라도 절대 우회 불가: 과거 날짜 / 크레딧·유효기간
                    if (eligibility.reason === ReservationLockReason.pastDate) {
                        throw new functions.https.HttpsError('failed-precondition', '과거 날짜는 예약할 수 없습니다.', { reason: eligibility.reason });
                    }
                    if (eligibility.reason === ReservationLockReason.noCreditsOrExpired) {
                        throw new functions.https.HttpsError(
                            'failed-precondition',
                            '남은 예약 횟수가 없거나 유효 기간이 만료된 회원은 예약을 추가할 수 없습니다.',
                            { reason: eligibility.reason },
                        );
                    }

                    // ⚠️ 관리자 “강제 추가”가 가능한 케이스는 명시적 force=true일 때만 허용
                    const forceableReasons = new Set([
                        ReservationLockReason.full,
                        ReservationLockReason.closedBeforeStart,
                        ReservationLockReason.notOpenedYet,
                    ]);
                    if (forceableReasons.has(eligibility.reason as any)) {
                        if (!force) {
                            // UI에서 "강제 추가" 확인 다이얼로그를 띄울 수 있도록 상세 정보 반환
                            throwRequiresForce({
                                reason: eligibility.reason,
                                openAt: eligibility.openAt ? eligibility.openAt.toISOString() : null,
                                capacity,
                                reservedCount: currentReservedCount,
                                closeBeforeMinutes: policy.closeBeforeMinutes ?? 60,
                            });
                        }
                        console.log(`[createReservation] Admin force create: ${eligibility.reason}`);
                    } else {
                        // 예기치 않은 reason이면 안전하게 차단
                        throw new functions.https.HttpsError('failed-precondition', '정책상 예약을 추가할 수 없습니다.', { reason: eligibility.reason });
                    }
                } else {
                    // 일반 사용자: 정책 그대로 적용 (override/미리열기면 evaluateReservation이 openPolicy를 이미 스킵)
                    if (eligibility.reason === ReservationLockReason.notOpenedYet && eligibility.openAt) {
                        throw new functions.https.HttpsError(
                            'failed-precondition',
                            '아직 예약 오픈 전입니다.',
                            { reason: eligibility.reason, openAt: eligibility.openAt.toISOString() },
                        );
                    }
                    switch (eligibility.reason) {
                        case ReservationLockReason.noCreditsOrExpired:
                            throw new functions.https.HttpsError('failed-precondition', '예약 가능한 횟수가 없거나 유효 기간이 만료되었습니다.');
                        case ReservationLockReason.pastDate:
                            throw new functions.https.HttpsError('failed-precondition', '과거 날짜는 예약할 수 없습니다.');
                        case ReservationLockReason.full:
                            throw new functions.https.HttpsError('resource-exhausted', '예약 가능한 인원이 없습니다.');
                        case ReservationLockReason.closedBeforeStart:
                            throw new functions.https.HttpsError('failed-precondition', `세션 시작 ${policy.closeBeforeMinutes}분 전까지만 예약 가능합니다.`);
                        case ReservationLockReason.notOpenedYet:
                            throw new functions.https.HttpsError('failed-precondition', '아직 예약 오픈 전입니다.');
                        case ReservationLockReason.none:
                            break;
                    }
                }
            }

            // 8) reservation 생성 (플레이스 서브컬렉션)
            const reservationRef = db
                .collection('places')
                .doc(placeId)
                .collection('reservations')
                .doc();
            tx.set(reservationRef, {
                id: reservationRef.id,
                userId,
                courseId,
                placeId,
                dayOfWeek,
                startTime,
                reservedAt: admin.firestore.FieldValue.serverTimestamp(),
                reservedDate: admin.firestore.Timestamp.fromDate(reservedDate),
                reservedDateString: reservedDateString,
            });

            // 9) sessionReservations upsert + reservedCount++
            await incrementSessionReservedCountUpsert(tx, db, {
                sessionId,
                srRef,
                srDoc,
                courseId,
                placeId,
                dayOfWeek,
                startTime,
                reservedDateString,
                capacity,
                currentReservedCount,
            });

            // 10) enrollment remainingReservations-- (pending 멤버는 pendingMembers 업데이트)
            // 불변식: remainingReservations는 음수가 되면 안 됨 (관리자도 크레딧/기간은 우회 불가)
            if (remainingReservations <= 0) {
                throw new functions.https.HttpsError(
                    'failed-precondition',
                    '남은 예약 횟수가 없습니다.',
                    { reason: ReservationLockReason.noCreditsOrExpired },
                );
            }

            if (isPendingMember) {
                // pending 멤버: pendingMembers의 courseEnrollments 업데이트
                // 이미 트랜잭션 초반에 읽은 pendingDoc를 재사용 (읽기 후 쓰기 규칙 준수)
                if (pendingDocForUpdate && pendingDocForUpdate.exists) {
                    const courseEnrollments = (pendingDataForUpdate?.courseEnrollments as any[] | undefined) ?? [];
                    const updatedEnrollments = courseEnrollments.map((ce: any) => {
                        if (ce?.courseId === courseId) {
                            const total = Number(ce?.totalReservations ?? 0);
                            const remainingBase = Number(ce?.remainingReservations ?? total);
                            return {
                                ...ce,
                                // remainingReservations가 없던 레거시 데이터는 totalReservations를 기준으로 차감
                                remainingReservations: Math.max(0, remainingBase - 1),
                            };
                        }
                        return ce;
                    });
                    tx.update(pendingDocForUpdate.ref, { courseEnrollments: updatedEnrollments });
                }
            } else {
                // 일반 멤버: enrollments 업데이트
                if (enrollmentDoc) {
                    tx.update(enrollmentDoc.ref, { remainingReservations: remainingReservations - 1 });
                }
            }

            const result = {
                id: reservationRef.id,
                userId,
                courseId,
                placeId,
                dayOfWeek,
                startTime,
                reservedDateString,
            };
            logFunctionSuccess(functionName, { reservationId: reservationRef.id, courseId, reservedDateString });

            // 11) 예약 생성 성공 알림 전송 (트랜잭션 외부에서)
            // 코스명을 포함한 알림 메시지 생성
            const courseName = getCourseName(place, courseId);
            const notificationBody = `${courseName} - ${reservedDateString} ${startTime}`;

            // 트랜잭션 완료 후 알림 생성 (트랜잭션 외부에서 실행)
            createNotification({
                userId,
                type: 'reservation',
                title: `${courseName} 예약이 완료되었습니다`,
                body: notificationBody,
                placeId,
                data: {
                    reservationId: reservationRef.id,
                    courseId,
                    placeId,
                },
                isAdmin: false,
            }).catch((error) => {
                console.error(`[createReservation] Error creating notification:`, error);
            });

            return result;
        });
    } catch (error) {
        logFunctionError(functionName, error as Error, { userId, courseId, reservedDateString });
        throw error;
    }
});

// admin 권한 헬퍼는 functions/src/admin_auth.ts 로 이동

/**
 * 코스 등록(수강) 취소 (관리자)
 *
 * 요구사항:
 * - 등록 취소 시, 해당 코스의 "미래 예약"이 남아 있으면 경고 후 연쇄 취소 옵션 제공
 * - 연쇄 취소를 선택하면( cascade=true ) 미래 예약을 모두 취소(예약자 알림 포함)한 뒤 등록을 만료 처리
 *
 * 주의:
 * - 이미 시작된 세션(세션 시작 시각 <= now)은 취소 대상에서 제외 (정합성/악용 방지)
 */
export const cancelEnrollment = functions.https.onCall(async (data, context) => {
    const functionName = 'cancelEnrollment';
    logFunctionStart(functionName, { userId: context.auth?.uid, ...data });

    if (!context.auth?.uid) {
        logFunctionError(functionName, new Error('Unauthenticated'), { data });
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const callerId = context.auth.uid;
    const placeId = String(data?.placeId ?? '');
    const targetUserId = String(data?.userId ?? '');
    const courseId = String(data?.courseId ?? '');
    const cascade = data?.cascade === true;

    if (!placeId || !targetUserId || !courseId) {
        throw new functions.https.HttpsError(
            'invalid-argument',
            'placeId, userId, courseId가 필요합니다.',
        );
    }

    // place 단위 관리자만 가능
    await assertAdminForPlaceUid(callerId, placeId);

    const db = admin.firestore();
    const now = getSeoulDateTime();
    const todayString = `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`;

    // 코스명 조회 (UI 경고/알림에 "코스명 그대로" 쓰기 위해)
    const place = await getPlaceOrThrow(placeId);
    const courseName = getCourseName(place, courseId);

    // 미래 예약 조회 (오늘 포함, reservedDateString 기준)
    const reservationsSnap = await db
        .collection('places')
        .doc(placeId)
        .collection('reservations')
        .where('userId', '==', targetUserId)
        .where('courseId', '==', courseId)
        .where('reservedDateString', '>=', todayString)
        .get();

    // 실제 취소 가능한 예약만 필터링(세션 시작 전)
    const cancellable = reservationsSnap.docs.filter((doc) => {
        const r = doc.data() as any;
        const startTime = String(r?.startTime ?? '');
        const dateStr = String(r?.reservedDateString ?? '');
        if (!startTime || !dateStr) return false;
        const { y, mo, d } = parseYYYYMMDD(dateStr);
        const { h, m } = parseHHmm(startTime);
        const sessionStart = makeSeoulDateTime(y, mo, d, h, m);
        return now.getTime() < sessionStart.getTime();
    });

    if (cancellable.length > 0 && !cascade) {
        throwRequiresCascade({
            courseId,
            courseName,
            reservationCount: cancellable.length,
        });
    }

    // enrollment 조회
    const enrollmentQuery = db
        .collection('enrollments')
        .where('userId', '==', targetUserId)
        .where('courseId', '==', courseId)
        .where('placeId', '==', placeId)
        .limit(1);
    const enrollmentSnap = await enrollmentQuery.get();
    const enrollmentDoc = enrollmentSnap.empty ? null : enrollmentSnap.docs[0];
    if (!enrollmentDoc) {
        throw new functions.https.HttpsError('failed-precondition', '등록 정보를 찾을 수 없습니다.');
    }

    const toCancel = cancellable;
    if (toCancel.length > 450) {
        // 트랜잭션 write 한도 방지 (예약 1건당 최소 2 write: reservation delete + sr decrement)
        throw new functions.https.HttpsError(
            'resource-exhausted',
            '취소할 예약이 너무 많아 한 번에 처리할 수 없습니다.',
            { reservationCount: toCancel.length },
        );
    }

    // 트랜잭션: 예약 삭제 + sessionReservations decrement + enrollment 삭제
    await db.runTransaction(async (tx) => {
        // 예약 취소 처리
        for (const doc of toCancel) {
            const r = doc.data() as any;
            const dayOfWeek = Number(r?.dayOfWeek ?? 0);
            const startTime = String(r?.startTime ?? '');
            const reservedDateString = String(r?.reservedDateString ?? '');
            if (!startTime || !reservedDateString || !Number.isFinite(dayOfWeek)) continue;

            const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
            const srRef = db.collection('sessionReservations').doc(`${sessionId}_${reservedDateString}`);
            const srDoc = await tx.get(srRef);
            if (srDoc.exists) {
                tx.update(srRef, {
                    reservedCount: admin.firestore.FieldValue.increment(-1),
                    lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                });
            }

            tx.delete(doc.ref);
        }

        // ✅ 수강 취소는 "만료 처리"가 아니라 enrollment 문서 자체를 삭제한다.
        // - UI에서 코스가 완전히 제거되어야 함
        // - onEnrollmentDeleted 트리거가 courseMembers를 자동 정리함
        tx.delete(enrollmentDoc.ref);
    });

    // 사용자 알림(1회, 집계)
    if (toCancel.length > 0) {
        await createNotification({
            userId: targetUserId,
            type: 'system',
            title: `${courseName} 등록이 취소되었습니다`,
            body: `${courseName} 등록 취소로 인해 향후 예약 ${toCancel.length}건이 취소되었습니다.`,
            placeId,
            data: {
                courseId,
                placeId,
                reservationCount: toCancel.length,
                kind: 'enrollment-cancel-cascade',
            },
            isAdmin: false,
        });
    }

    logFunctionSuccess(functionName, { callerId, placeId, targetUserId, courseId, cancelledReservations: toCancel.length, cascade });
    return { success: true, cancelledReservations: toCancel.length, courseName };
});

/**
 * 멤버 삭제(플레이스에서 추방) (관리자)
 *
 * 목표:
 * - 해당 플레이스의 접근을 완전히 제거한다.
 *
 * 처리:
 * - placeMemberships 삭제 (userId_placeId)
 * - enrollments 삭제 (userId + placeId)
 * - courseMembers 삭제 (userId + placeId)  // enrollments 삭제 트리거로도 정리되지만, 레거시/정합성 위해 한번 더 정리
 * - places/{placeId}/reservations 중 해당 userId 예약 삭제 (onReservationDeleted가 sessionReservations reservedCount 정리)
 * - pendingMembers(placeId_phoneNumber) 문서 삭제 (있으면)
 */
export const removeMemberFromPlace = functions.https.onCall(async (data, context) => {
    const functionName = 'removeMemberFromPlace';
    logFunctionStart(functionName, { userId: context.auth?.uid, ...data });

    if (!context.auth?.uid) {
        logFunctionError(functionName, new Error('Unauthenticated'), { data });
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const callerId = context.auth.uid;
    const placeId = String(data?.placeId ?? '');
    const targetUserId = String(data?.userId ?? '');
    const phoneNumberRaw = String(data?.phoneNumber ?? '');

    if (!placeId || !targetUserId) {
        throw new functions.https.HttpsError(
            'invalid-argument',
            'placeId, userId가 필요합니다.',
        );
    }

    // place 단위 관리자만 가능
    await assertAdminForPlaceUid(callerId, placeId);

    const db = admin.firestore();

    // 1) placeMemberships 삭제 (고정 docId 우선)
    const membershipId = `${targetUserId}_${placeId}`;
    const membershipRef = db.collection('placeMemberships').doc(membershipId);
    const membershipDoc = await membershipRef.get();
    if (membershipDoc.exists) {
        await membershipRef.delete();
    } else {
        // 혹시 레거시 docId가 있을 수 있어 query로 한번 더 정리
        await deleteByQuery(
            db,
            db.collection('placeMemberships')
                .where('userId', '==', targetUserId)
                .where('placeId', '==', placeId),
        );
    }

    // 2) enrollments 삭제 (userId + placeId)
    const deletedEnrollments = await deleteByQuery(
        db,
        db.collection('enrollments')
            .where('userId', '==', targetUserId)
            .where('placeId', '==', placeId),
    );

    // 3) courseMembers 삭제 (userId + placeId)
    const deletedCourseMembers = await deleteByQuery(
        db,
        db.collection('courseMembers')
            .where('userId', '==', targetUserId)
            .where('placeId', '==', placeId),
    );

    // 4) reservations 삭제 (places/{placeId}/reservations)
    // ✅ 정합성: 현재 트리거(onReservationDeleted)는 비활성화되어 있으므로,
    // 여기서 직접 sessionReservations.reservedCount도 함께 감소시켜야 함.
    const reservationsSnap = await db
        .collection('places')
        .doc(placeId)
        .collection('reservations')
        .where('userId', '==', targetUserId)
        .get();

    let deletedReservations = 0;
    if (!reservationsSnap.empty) {
        const docs = reservationsSnap.docs;
        const chunkSize = 200; // worst-case (delete 200 + sr update 200) < 500 writes

        for (let i = 0; i < docs.length; i += chunkSize) {
            const chunk = docs.slice(i, i + chunkSize);
            const srDecrements = new Map<string, number>();

            for (const d of chunk) {
                const r = d.data() as any;
                const courseId = String(r?.courseId ?? '');
                const dayOfWeek = Number(r?.dayOfWeek ?? 0);
                const startTime = String(r?.startTime ?? '');
                const reservedDateString = String(r?.reservedDateString ?? '');
                if (!courseId || !startTime || !reservedDateString || !Number.isFinite(dayOfWeek)) continue;
                const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
                const srKey = `${sessionId}_${reservedDateString}`;
                srDecrements.set(srKey, (srDecrements.get(srKey) ?? 0) + 1);
            }

            await db.runTransaction(async (tx) => {
                // read sr docs first (read-before-write)
                const srDocs = new Map<string, FirebaseFirestore.DocumentSnapshot>();
                for (const srKey of srDecrements.keys()) {
                    const srRef = db.collection('sessionReservations').doc(srKey);
                    srDocs.set(srKey, await tx.get(srRef));
                }

                // update sr reservedCount (clamp >= 0)
                for (const [srKey, dec] of srDecrements.entries()) {
                    const srRef = db.collection('sessionReservations').doc(srKey);
                    const srDoc = srDocs.get(srKey)!;
                    if (!srDoc.exists) continue;
                    const current = Number((srDoc.data() as any)?.reservedCount ?? 0);
                    const next = Math.max(0, current - dec);
                    tx.update(srRef, {
                        reservedCount: next,
                        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                    });
                }

                // delete reservations
                for (const d of chunk) {
                    tx.delete(d.ref);
                }
            });

            deletedReservations += chunk.length;
        }
    }

    // 5) pendingMembers 삭제 (있으면)
    const phoneDigits = phoneNumberRaw.replace(/[^\d]/g, '');
    let deletedPending = 0;
    if (phoneDigits) {
        const pendingId = `${placeId}_${phoneDigits}`;
        const pendingRef = db.collection('pendingMembers').doc(pendingId);
        const pendingDoc = await pendingRef.get();
        if (pendingDoc.exists) {
            await pendingRef.delete();
            deletedPending = 1;
        } else {
            // 레거시/오염 데이터 정리: placeId + phoneNumber로도 한번 더
            deletedPending = await deleteByQuery(
                db,
                db.collection('pendingMembers')
                    .where('placeId', '==', placeId)
                    .where('phoneNumber', '==', phoneDigits),
            );
        }
    }

    logFunctionSuccess(functionName, {
        callerId,
        placeId,
        targetUserId,
        deletedEnrollments,
        deletedCourseMembers,
        deletedReservations,
        deletedPending,
    });

    return {
        success: true,
        deletedEnrollments,
        deletedCourseMembers,
        deletedReservations,
        deletedPending,
    };
});

/**
 * 코스 일정(세션 템플릿) 업데이트 (관리자)
 *
 * 목표: "예약이 있는 세션은 삭제/시간변경 불가"를 서버에서 강제
 * - 삭제/변경 대상 세션에 미래 예약(sessionReservations.reservedCount>0, date>=today)이 있으면 실패
 * - UI는 details.requiresBulkMove를 받아 일괄 이동/세션 취소를 유도
 */
export const updateCourseSchedule = functions.https.onCall(async (data, context) => {
    const functionName = 'updateCourseSchedule';
    logFunctionStart(functionName, { userId: context.auth?.uid, ...data });

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const callerId = context.auth.uid;
    const placeId = String(data?.placeId ?? '');
    const courseId = String(data?.courseId ?? '');
    const sessions = Array.isArray(data?.sessions) ? data.sessions : [];

    if (!placeId || !courseId) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId와 courseId가 필요합니다.');
    }

    await assertAdminForPlaceUid(callerId, placeId);

    const db = admin.firestore();
    const now = getSeoulDateTime();
    const todayString = `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`;

    // place + course 조회 (코스명 그대로 사용)
    const place = await getPlaceOrThrow(placeId);
    const courseName = getCourseName(place, courseId);

    // 기존 세션 맵(키: day_start)
    const course = findCourse(place, courseId);
    if (!course) {
        throw new functions.https.HttpsError('not-found', '코스를 찾을 수 없습니다.');
    }
    const oldSessions = Array.isArray(course.sessions) ? course.sessions : [];
    const oldMap = new Map<string, any>();
    for (const s of oldSessions) {
        const d = Number((s as any)?.dayOfWeek ?? 0);
        const st = String((s as any)?.startTime ?? '');
        if (!Number.isFinite(d) || !st) continue;
        oldMap.set(`${d}_${st}`, s);
    }

    // 신규 세션 맵
    const newMap = new Map<string, any>();
    for (const s of sessions) {
        const d = Number((s as any)?.dayOfWeek ?? 0);
        const st = String((s as any)?.startTime ?? '');
        const et = String((s as any)?.endTime ?? '');
        const cap = Number((s as any)?.capacity ?? 0);
        if (!Number.isFinite(d) || d < 1 || d > 7 || !st || !et || !Number.isFinite(cap) || cap <= 0) {
            throw new functions.https.HttpsError('invalid-argument', 'sessions 데이터가 올바르지 않습니다.');
        }
        // 간단한 시간 형식 검증 (parseHHmm은 invalid-argument로 던짐)
        parseHHmm(st);
        parseHHmm(et);
        newMap.set(`${d}_${st}`, { dayOfWeek: d, startTime: st, endTime: et, capacity: cap });
    }

    // 요일별 겹침 검사 (서버도 최소한 보장)
    const byDay = new Map<number, any[]>();
    for (const v of newMap.values()) {
        const d = Number(v.dayOfWeek);
        byDay.set(d, [...(byDay.get(d) ?? []), v]);
    }
    for (const [, list] of byDay.entries()) {
        const sorted = [...list].sort((a, b) => {
            const aa = parseHHmm(String(a.startTime));
            const bb = parseHHmm(String(b.startTime));
            return aa.h * 60 + aa.m - (bb.h * 60 + bb.m);
        });
        for (let i = 0; i < sorted.length; i++) {
            const a = sorted[i];
            const aStart = parseHHmm(String(a.startTime));
            const aEnd = parseHHmm(String(a.endTime));
            const aStartMin = aStart.h * 60 + aStart.m;
            const aEndMin = aEnd.h * 60 + aEnd.m;
            if (aStartMin >= aEndMin) {
                throw new functions.https.HttpsError('invalid-argument', '세션 시간이 유효하지 않습니다.');
            }
            for (let j = i + 1; j < sorted.length; j++) {
                const b = sorted[j];
                const bStart = parseHHmm(String(b.startTime));
                const bEnd = parseHHmm(String(b.endTime));
                const bStartMin = bStart.h * 60 + bStart.m;
                const bEndMin = bEnd.h * 60 + bEnd.m;
                if (aStartMin < bEndMin && aEndMin > bStartMin) {
                    throw new functions.https.HttpsError('failed-precondition', '세션 시간이 겹칩니다.');
                }
            }
        }
    }

    // 삭제/변경된 세션에 미래 예약이 있으면 차단
    const removedKeys: string[] = [];
    const modifiedKeys: string[] = [];

    for (const key of oldMap.keys()) {
        if (!newMap.has(key)) removedKeys.push(key);
    }
    for (const key of newMap.keys()) {
        if (!oldMap.has(key)) continue;
        const oldS = oldMap.get(key);
        const newS = newMap.get(key);
        const oldEnd = String((oldS as any)?.endTime ?? '');
        const oldCap = Number((oldS as any)?.capacity ?? 0);
        if (oldEnd !== String(newS.endTime) || oldCap !== Number(newS.capacity)) {
            modifiedKeys.push(key);
        }
    }

    async function hasFutureReservationsForSessionKey(key: string): Promise<boolean> {
        const [dStr, st] = key.split('_');
        const d = Number(dStr);
        const sid = `${courseId}_${d}_${st}`;
        const q = db
            .collection('sessionReservations')
            .where('sessionId', '==', sid)
            .where('reservedCount', '>', 0)
            .where('date', '>=', todayString)
            .limit(1);
        const snap = await q.get();
        return !snap.empty;
    }

    for (const key of removedKeys) {
        if (await hasFutureReservationsForSessionKey(key)) {
            const [dStr, st] = key.split('_');
            throwRequiresBulkMove({
                courseId,
                courseName,
                dayOfWeek: Number(dStr),
                startTime: st,
                operation: 'delete',
            });
        }
    }
    for (const key of modifiedKeys) {
        if (await hasFutureReservationsForSessionKey(key)) {
            const [dStr, st] = key.split('_');
            throwRequiresBulkMove({
                courseId,
                courseName,
                dayOfWeek: Number(dStr),
                startTime: st,
                operation: 'modify',
            });
        }
    }

    // place courses 업데이트 (sessions만 교체)
    const placeRef = db.collection('places').doc(placeId);
    await db.runTransaction(async (tx) => {
        const placeDoc = await tx.get(placeRef);
        if (!placeDoc.exists) {
            throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
        }
        const placeData = placeDoc.data() as any;
        const courses = Array.isArray(placeData?.courses) ? placeData.courses : [];
        let found = false;
        const updatedCourses = courses.map((c: any) => {
            if (String(c?.id ?? '') !== courseId) return c;
            found = true;
            return {
                ...c,
                sessions: Array.from(newMap.values()),
            };
        });
        if (!found) {
            throw new functions.https.HttpsError('not-found', '코스를 찾을 수 없습니다.');
        }
        tx.update(placeRef, { courses: updatedCourses });
    });

    logFunctionSuccess(functionName, { callerId, placeId, courseId, removed: removedKeys.length, modified: modifiedKeys.length });
    return { success: true, courseName };
});

/**
 * 플레이스 삭제 (관리자)
 *
 * 클라이언트에서 대량 삭제를 수행하면 rules/권한/속도 문제로 쉽게 깨지므로
 * 서버에서만 수행하도록 중앙화합니다.
 *
 * 정책:
 * - 예약이 있어도 서버에서 모두 삭제 후 플레이스 삭제 (예약 취소 별도 불필요)
 */
export const deletePlace = functions.https.onCall(async (data, context) => {
    const functionName = 'deletePlace';
    logFunctionStart(functionName, { userId: context.auth?.uid, ...data });

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const callerId = context.auth.uid;
    const placeId = String(data?.placeId ?? '');
    if (!placeId) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId가 필요합니다.');
    }

    await assertAdminForPlaceUid(callerId, placeId);

    const db = admin.firestore();

    // place 존재 확인 및 코스 ID 수집 (coursePolicies 삭제용)
    const placeDoc = await db.collection('places').doc(placeId).get();
    if (!placeDoc.exists) {
        throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
    }
    const placeData = placeDoc.data() as any;
    const courseIds = ((placeData?.courses as any[]) || []).map((c: any) => c?.id).filter(Boolean) as string[];

    // 하위/관련 데이터 정리 (예약 포함 전부 서버에서 삭제)
    const deletedReservations = await deleteCollectionByPath(db, `places/${placeId}/reservations`);
    const deletedEnrollments = await deleteByQuery(
        db,
        db.collection('enrollments').where('placeId', '==', placeId),
    );
    const deletedCourseMembers = await deleteByQuery(
        db,
        db.collection('courseMembers').where('placeId', '==', placeId),
    );
    const deletedPlaceMemberships = await deleteByQuery(
        db,
        db.collection('placeMemberships').where('placeId', '==', placeId),
    );
    const deletedPendingMembers = await deleteByQuery(
        db,
        db.collection('pendingMembers').where('placeId', '==', placeId),
    );
    const deletedStories = await deleteByQuery(
        db,
        db.collection('stories').where('placeId', '==', placeId),
    );
    const deletedPromotions = await deleteByQuery(
        db,
        db.collection('promotions').where('placeId', '==', placeId),
    );
    const deletedSessionReservations = await deleteByQuery(
        db,
        db.collection('sessionReservations').where('placeId', '==', placeId),
    );
    const deletedNotifications = await deleteByQuery(
        db,
        db.collection('notifications').where('placeId', '==', placeId),
    );
    const deletedBookingWeekOpens = await deleteByQuery(
        db,
        db.collection('bookingWeekOpens').where('placeId', '==', placeId),
    );
    const deletedDateCapacityOverrides = await deleteByQuery(
        db,
        db.collection('dateCapacityOverrides').where('placeId', '==', placeId),
    );
    const deletedCourseOverrides = await deleteByQuery(
        db,
        db.collection('courseOverrides').where('placeId', '==', placeId),
    );
    let deletedCoursePolicies = 0;
    for (const courseId of courseIds) {
        const policyRef = db.collection('coursePolicies').doc(courseId);
        const policySnap = await policyRef.get();
        if (policySnap.exists) {
            await policyRef.delete();
            deletedCoursePolicies++;
        }
    }

    await db.collection('places').doc(placeId).delete();

    logFunctionSuccess(functionName, {
        callerId,
        placeId,
        deletedReservations,
        deletedEnrollments,
        deletedCourseMembers,
        deletedPlaceMemberships,
        deletedPendingMembers,
        deletedStories,
        deletedPromotions,
        deletedSessionReservations,
        deletedNotifications,
        deletedBookingWeekOpens,
        deletedDateCapacityOverrides,
        deletedCourseOverrides,
        deletedCoursePolicies,
    });
    return { success: true };
});

/**
 * 회원탈퇴 (본인 계정 삭제)
 *
 * - 호출자는 반드시 본인(context.auth.uid === userId)이어야 함.
 * - 관리자이며 소속 플레이스가 있으면 탈퇴 불가 (먼저 플레이스 삭제 요청).
 * - Firestore: users, placeMemberships, enrollments, courseMembers, reservations(+ sessionReservations 정리), pendingMembers, notifications, adminUsers 정리
 * - Firebase Auth 사용자 삭제 (마지막에 수행)
 */
export const deleteUserAccount = functions.https.onCall(async (data, context) => {
    const functionName = 'deleteUserAccount';
    logFunctionStart(functionName, { userId: context.auth?.uid });

    if (!context.auth?.uid) {
        logFunctionError(functionName, new Error('Unauthenticated'), {});
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const callerUid = context.auth.uid;
    const userId = String(data?.userId ?? '').trim();

    if (!userId || userId !== callerUid) {
        logFunctionError(functionName, new Error('Forbidden: only self'), { callerUid, userId });
        throw new functions.https.HttpsError('permission-denied', '본인 계정만 탈퇴할 수 있습니다.');
    }

    const db = admin.firestore();

    try {
        // 0) 관리자이며 소속 플레이스가 있으면 탈퇴 거부 (먼저 플레이스 삭제 요청)
        const adminRef = db.collection('adminUsers').doc(userId);
        const adminDoc = await adminRef.get();
        if (adminDoc.exists) {
            const adminData = adminDoc.data() as { placeIds?: string[] };
            const placeIds = Array.isArray(adminData?.placeIds) ? adminData.placeIds : [];
            if (placeIds.length > 0) {
                logFunctionError(functionName, new Error('Admin has places'), { userId, placeCount: placeIds.length });
                throw new functions.https.HttpsError(
                    'failed-precondition',
                    '관리자인 경우 소속 플레이스를 먼저 삭제해주세요.',
                );
            }
        }

        // 1) users 문서 조회 (phoneNumber 등 후속 정리용)
        const userRef = db.collection('users').doc(userId);
        const userDoc = await userRef.get();
        const userData = userDoc.exists ? userDoc.data() : null;
        const phoneNumber = userData?.phoneNumber ? String(userData.phoneNumber).replace(/\D/g, '') : '';

        // 2) placeMemberships 삭제 및 placeId 수집
        const membershipsSnap = await db.collection('placeMemberships').where('userId', '==', userId).get();
        const placeIds = [...new Set(membershipsSnap.docs.map((d) => d.data().placeId as string))];
        const deletedMemberships = await deleteByQuery(
            db,
            db.collection('placeMemberships').where('userId', '==', userId),
        );
        console.log(`[${functionName}] Deleted placeMemberships: ${deletedMemberships}, placeIds: ${placeIds.join(', ')}`);

        // 3) enrollments 삭제
        const deletedEnrollments = await deleteByQuery(
            db,
            db.collection('enrollments').where('userId', '==', userId),
        );
        console.log(`[${functionName}] Deleted enrollments: ${deletedEnrollments}`);

        // 4) courseMembers 삭제
        const deletedCourseMembers = await deleteByQuery(
            db,
            db.collection('courseMembers').where('userId', '==', userId),
        );
        console.log(`[${functionName}] Deleted courseMembers: ${deletedCourseMembers}`);

        // 5) 예약 삭제 + sessionReservations.reservedCount 정리 (일반 유저 남은 예약 반영)
        let deletedReservations = 0;
        for (const placeId of placeIds) {
            const reservationsSnap = await db
                .collection('places')
                .doc(placeId)
                .collection('reservations')
                .where('userId', '==', userId)
                .get();
            if (reservationsSnap.empty) continue;

            // sessionReservations 키별로 감소할 개수 집계
            const srDecrements = new Map<string, number>();
            const reservationRefs: FirebaseFirestore.DocumentReference[] = [];
            for (const doc of reservationsSnap.docs) {
                const r = doc.data() as { courseId?: string; dayOfWeek?: number; startTime?: string; reservedDateString?: string };
                const courseId = String(r?.courseId ?? '');
                const dayOfWeek = Number(r?.dayOfWeek ?? 0);
                const startTime = String(r?.startTime ?? '');
                const dateStr = String(r?.reservedDateString ?? '');
                if (!courseId || !startTime || !dateStr) continue;
                const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
                const srKey = `${sessionId}_${dateStr}`;
                srDecrements.set(srKey, (srDecrements.get(srKey) ?? 0) + 1);
                reservationRefs.push(doc.ref);
            }

            // sessionReservations 문서 읽어서 reservedCount 감소 후 업데이트
            for (const [srKey, decrement] of srDecrements.entries()) {
                const srRef = db.collection('sessionReservations').doc(srKey);
                const srSnap = await srRef.get();
                if (srSnap.exists) {
                    const current = Number((srSnap.data()?.reservedCount ?? 0) as number);
                    await srRef.update({
                        reservedCount: Math.max(0, current - decrement),
                        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                    });
                    console.log(`[${functionName}] sessionReservations ${srKey} reservedCount ${current} -> ${Math.max(0, current - decrement)}`);
                }
            }

            // 예약 문서 일괄 삭제 (배치 400개 제한)
            const batchSize = 400;
            for (let i = 0; i < reservationRefs.length; i += batchSize) {
                const batch = db.batch();
                reservationRefs.slice(i, i + batchSize).forEach((ref) => batch.delete(ref));
                await batch.commit();
                deletedReservations += Math.min(batchSize, reservationRefs.length - i);
            }
        }
        console.log(`[${functionName}] Deleted reservations: ${deletedReservations}`);

        // 6) pendingMembers 삭제 (phoneNumber로 검색)
        let deletedPending = 0;
        if (phoneNumber) {
            deletedPending = await deleteByQuery(
                db,
                db.collection('pendingMembers').where('phoneNumber', '==', phoneNumber),
            );
            console.log(`[${functionName}] Deleted pendingMembers (phoneNumber): ${deletedPending}`);
        }

        // 7) notifications 삭제
        const deletedNotifications = await deleteByQuery(
            db,
            db.collection('notifications').where('userId', '==', userId),
        );
        console.log(`[${functionName}] Deleted notifications: ${deletedNotifications}`);

        // 8) users 문서 삭제
        if (userDoc.exists) {
            await userRef.delete();
            console.log(`[${functionName}] Deleted users doc: ${userId}`);
        }

        // 9) adminUsers 문서 삭제 (doc id가 uid인 경우)
        if (adminDoc.exists) {
            await adminRef.delete();
            console.log(`[${functionName}] Deleted adminUsers doc for: ${userId}`);
        }

        // 10) Firebase Auth 사용자 삭제 (마지막에 수행)
        await admin.auth().deleteUser(userId);
        console.log(`[${functionName}] Deleted Firebase Auth user: ${userId}`);

        logFunctionSuccess(functionName, {
            userId,
            deletedMemberships,
            deletedEnrollments,
            deletedCourseMembers,
            deletedReservations,
            deletedPending,
            deletedNotifications,
        });
        return { success: true };
    } catch (error) {
        logFunctionError(functionName, error as Error, { userId });
        if (error instanceof functions.https.HttpsError) throw error;
        console.error(`[${functionName}] Error:`, error);
        throw new functions.https.HttpsError(
            'internal',
            '회원탈퇴 처리 중 오류가 발생했습니다.',
            (error as Error).message,
        );
    }
});

/**
 * ==================== Firebase Cloud Messaging (FCM) ====================
 */

/**
 * 알림 생성 헬퍼 함수
 * Firestore에 알림을 생성하면 onNotificationCreated 트리거가 자동으로 FCM 푸시를 전송합니다.
 */
async function createNotification({
    userId,
    type,
    title,
    body,
    placeId,
    data,
    isAdmin = false,
}: {
    userId: string;
    type: 'reservation' | 'story' | 'promotion' | 'system';
    title: string;
    body: string;
    placeId?: string;
    data?: Record<string, any>;
    isAdmin?: boolean;
}): Promise<void> {
    try {
        await admin.firestore().collection('notifications').add({
            userId,
            type,
            title,
            body,
            placeId: placeId || null,
            data: data || {},
            isRead: false,
            isAdminNotification: isAdmin,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        console.log(`[createNotification] Created notification for user ${userId}, type: ${type}`);
    } catch (error) {
        console.error(`[createNotification] Error creating notification:`, error);
        // 알림 생성 실패해도 메인 로직은 계속 진행
    }
}

/**
 * FCM 푸시 알림 전송 헬퍼 함수
 */
async function sendPushNotification({
    userId,
    title,
    body,
    data,
}: {
    userId: string;
    title: string;
    body: string;
    data?: Record<string, any>;
}): Promise<void> {
    try {
        // 사용자 정보 조회
        const userDoc = await admin.firestore().collection('users').doc(userId).get();
        if (!userDoc.exists) {
            console.warn(`[sendPushNotification] User not found: ${userId}`);
            return;
        }

        const userData = userDoc.data();
        const fcmToken = userData?.fcmToken;

        // 알림 설정 확인
        const notificationsEnabled = userData?.notificationsEnabled !== false; // 기본값 true

        if (!fcmToken) {
            console.warn(`[sendPushNotification] No FCM token for user: ${userId}`);
            return;
        }

        if (!notificationsEnabled) {
            console.log(`[sendPushNotification] Notifications disabled for user: ${userId}`);
            return;
        }

        // FCM 메시지 구성
        const message: admin.messaging.Message = {
            token: fcmToken,
            notification: {
                title,
                body,
            },
            data: data ? Object.fromEntries(
                Object.entries(data).map(([key, value]) => [key, String(value)])
            ) : undefined,
            android: {
                priority: 'high' as const,
                notification: {
                    channelId: 'default',
                    sound: 'default',
                },
            },
            apns: {
                payload: {
                    aps: {
                        sound: 'default',
                        badge: 1,
                    },
                },
            },
        };

        // FCM 전송
        const response = await admin.messaging().send(message);
        console.log(`[sendPushNotification] Successfully sent message to ${userId}: ${response}`);
    } catch (error) {
        console.error(`[sendPushNotification] Error sending push notification to ${userId}:`, error);
        // FCM 전송 실패해도 알림 생성은 계속 진행
    }
}

/**
 * 알림 생성 시 FCM 푸시 알림도 함께 전송
 */
export const onNotificationCreated = functions.firestore
    .document('notifications/{notificationId}')
    .onCreate(async (snap: QueryDocumentSnapshot, context: EventContext) => {
        const notification = snap.data();
        const notificationId = context.params.notificationId;

        try {
            await sendPushNotification({
                userId: notification.userId,
                title: notification.title || '알림',
                body: notification.body || '',
                data: {
                    notificationId,
                    type: notification.type || 'system',
                    ...(notification.data || {}),
                },
            });
        } catch (error) {
            console.error(`[onNotificationCreated] Error sending push notification:`, error);
        }
    });


/**
 * 플레이스 가입 요청 승인/거절 시 사용자에게 알림 전송
 */
export const onPlaceMembershipUpdated = functions.firestore
    .document('placeMemberships/{membershipId}')
    .onUpdate(async (change: Change<QueryDocumentSnapshot>, context: EventContext) => {
        const before = change.before.data();
        const after = change.after.data();
        const membershipId = context.params.membershipId;

        // pending -> approved 또는 pending -> rejected로 변경된 경우에만 알림 전송
        if (before.status !== 'pending' || after.status === 'pending') {
            return;
        }

        try {
            const userId = after.userId;
            const placeId = after.placeId;

            // 플레이스 정보 조회
            const placeDoc = await admin.firestore().collection('places').doc(placeId).get();
            if (!placeDoc.exists) {
                console.warn(`[onPlaceMembershipUpdated] Place not found: ${placeId}`);
                return;
            }
            const placeData = placeDoc.data();
            const placeName = placeData?.name || '플레이스';

            if (after.status === 'approved') {
                // 승인 알림
                await createNotification({
                    userId,
                    type: 'system',
                    title: '가입이 승인되었습니다',
                    body: `${placeName} 가입이 승인되었습니다`,
                    placeId,
                    data: {
                        membershipId,
                        placeId,
                    },
                    isAdmin: false,
                });
            } else if (after.status === 'rejected') {
                // 거절 알림
                const rejectedReason = String(after.rejectedReason || '');
                const body = rejectedReason.length > 0
                    ? `${placeName} 가입이 거절되었습니다. 사유: ${rejectedReason}`
                    : `${placeName} 가입이 거절되었습니다`;

                await createNotification({
                    userId,
                    type: 'system',
                    title: '가입이 거절되었습니다',
                    body,
                    placeId,
                    data: {
                        membershipId,
                        placeId,
                    },
                    isAdmin: false,
                });
            }

            console.log(`[onPlaceMembershipUpdated] Created notification for user ${userId}, status: ${after.status}`);
        } catch (error) {
            console.error(`[onPlaceMembershipUpdated] Error creating notification:`, error);
        }
    });

/**
 * 등록 연장 요청 상태 변경 시 사용자에게 알림 전송 (승인/거절 시)
 */
export const onExtensionRequestUpdated = functions.firestore
    .document('enrollments/{enrollmentId}/extensionRequests/{requestId}')
    .onUpdate(async (change: Change<QueryDocumentSnapshot>, context: EventContext) => {
        const before = change.before.data();
        const after = change.after.data();
        const enrollmentId = context.params.enrollmentId;
        const requestId = context.params.requestId;

        // pending -> approved 또는 pending -> rejected로 변경된 경우에만 알림 전송
        if (before.status !== 'pending' || after.status === 'pending') {
            return;
        }

        try {
            // enrollment 정보 조회
            const enrollmentDoc = await admin.firestore().collection('enrollments').doc(enrollmentId).get();
            if (!enrollmentDoc.exists) {
                console.warn(`[onExtensionRequestUpdated] Enrollment not found: ${enrollmentId}`);
                return;
            }

            const enrollmentData = enrollmentDoc.data();
            const userId = enrollmentData?.userId as string;
            const courseId = enrollmentData?.courseId as string;
            const placeId = enrollmentData?.placeId as string;

            // 코스 정보 조회
            const placeDoc = await admin.firestore().collection('places').doc(placeId).get();
            if (!placeDoc.exists) {
                console.warn(`[onExtensionRequestUpdated] Place not found: ${placeId}`);
                return;
            }
            const placeData = placeDoc.data();
            const courses = (placeData?.courses as any[]) || [];
            const course = courses.find((c: any) => c.id === courseId);
            const courseName = course?.name || courseId;

            if (after.status === 'approved') {
                // 등록 연장 승인 알림
                await createNotification({
                    userId,
                    type: 'system',
                    title: `${courseName} 등록 연장이 승인되었습니다`,
                    body: `${courseName} 등록 연장이 승인되었습니다`,
                    placeId,
                    data: {
                        enrollmentId,
                        requestId,
                        userId,
                        courseId,
                        placeId,
                    },
                    isAdmin: false,
                });
                console.log(`[onExtensionRequestUpdated] Created approval notification for user: ${userId}`);
            }
            // 거절 알림 제거 (등록 연장 요청 기능 제거로 인해)
        } catch (error) {
            console.error(`[onExtensionRequestUpdated] Error creating notifications:`, error);
        }
    });

/**
 * 방문일 알림 (세션 시작 3시간 전)
 * 매 5분마다 실행하여 3시간 후 시작하는 세션의 예약자에게 알림 전송 (한 번만)
 */
export const sendUpcomingSessionNotifications = functions.pubsub
    .schedule('every 5 minutes')
    .timeZone('Asia/Seoul')
    .onRun(async (context: EventContext) => {
        try {
            const now = getSeoulDateTime();
            const inThreeHours = new Date(now.getTime() + 3 * 60 * 60 * 1000);

            // 3시간 후의 날짜와 시간 계산
            const targetDateString = formatDate(inThreeHours); // "YYYY-MM-DD"
            const targetHour = inThreeHours.getHours();
            const targetMinute = inThreeHours.getMinutes();
            const targetHHmm = `${pad2(targetHour)}:${pad2(targetMinute)}`;

            console.log(`[sendUpcomingSessionNotifications] Checking for sessions at ${targetDateString} ${targetHHmm}`);

            // 모든 플레이스의 예약 조회 (2시간 후 날짜와 시간으로 필터링)
            const placesSnapshot = await admin.firestore().collection('places').get();
            let totalNotifications = 0;

            for (const placeDoc of placesSnapshot.docs) {
                const placeId = placeDoc.id;
                const placeData = placeDoc.data();

                // 해당 플레이스의 예약 조회
                const reservationsSnapshot = await admin.firestore()
                    .collection('places')
                    .doc(placeId)
                    .collection('reservations')
                    .where('reservedDateString', '==', targetDateString)
                    .where('startTime', '==', targetHHmm)
                    .get();

                if (reservationsSnapshot.empty) {
                    continue;
                }

                // 코스 정보 가져오기
                const courses = (placeData?.courses as any[]) || [];
                const courseMap = new Map<string, any>();
                courses.forEach((course: any) => {
                    courseMap.set(course.id, course);
                });

                // 각 예약에 대해 알림 전송 (중복 방지: 오늘 이미 보낸 알림인지 확인)
                const notificationPromises = reservationsSnapshot.docs.map(async (reservationDoc) => {
                    const reservation = reservationDoc.data();
                    const userId = reservation.userId as string;
                    const courseId = reservation.courseId as string;
                    const reservationId = reservationDoc.id;

                    // 이미 오늘 알림을 보냈는지 확인 (중복 방지)
                    const todayString = formatDate(now);
                    const notificationQuery = await admin.firestore()
                        .collection('notifications')
                        .where('userId', '==', userId)
                        .where('type', '==', 'reservation')
                        .where('data.reservationId', '==', reservationId)
                        .where('data.reminderType', '==', 'upcoming')
                        .where('createdAt', '>=', admin.firestore.Timestamp.fromDate(seoulDateOnly(todayString)))
                        .limit(1)
                        .get();

                    if (!notificationQuery.empty) {
                        // 이미 오늘 알림을 보냄
                        return;
                    }

                    // 코스 정보 가져오기
                    const course = courseMap.get(courseId);
                    const courseName = course?.name || courseId;

                    // 알림 생성 (3시간 전, 한 번만)
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: `${courseName} 곧 세션이 시작됩니다`,
                        body: `${courseName} - ${targetDateString} ${targetHHmm} (3시간 전)`,
                        placeId,
                        data: {
                            reservationId,
                            courseId,
                            placeId,
                            reminderType: 'upcoming',
                        },
                        isAdmin: false,
                    });

                    totalNotifications++;
                });

                await Promise.all(notificationPromises);
            }

            console.log(`[sendUpcomingSessionNotifications] Sent ${totalNotifications} notifications for sessions at ${targetDateString} ${targetHHmm}`);
            return { success: true, notificationsSent: totalNotifications };
        } catch (error) {
            console.error(`[sendUpcomingSessionNotifications] Error:`, error);
            throw error;
        }
    });

/**
 * 주기적 예약 데이터 정리 (매일 새벽 3시)
 * 
 * - 30일 이상 지난 빈 sessionReservations 삭제
 * - 데이터 일관성 검증 (선택적)
 */
export const cleanupOldReservations = functions.pubsub
    .schedule('0 3 * * *') // 매일 새벽 3시 (서울 시간)
    .timeZone('Asia/Seoul')
    .onRun(async (context: EventContext) => {
        const functionName = 'cleanupOldReservations';
        console.log(`[${functionName}] Starting cleanup...`);

        try {
            const seoulNow = getSeoulDateTime();
            const thirtyDaysAgo = new Date(seoulNow.getTime() - 30 * 24 * 60 * 60 * 1000);
            const thirtyDaysAgoString = formatDate(thirtyDaysAgo);

            // 1. 30일 이상 지난 빈 sessionReservations 삭제
            const emptySessionReservations = await admin.firestore()
                .collection('sessionReservations')
                .where('reservedCount', '==', 0)
                .where('date', '<', thirtyDaysAgoString)
                .get();

            let deletedCount = 0;
            for (const doc of emptySessionReservations.docs) {
                try {
                    await doc.ref.delete();
                    deletedCount++;
                } catch (error) {
                    console.error(`[${functionName}] Error deleting sessionReservation ${doc.id}:`, error);
                }
            }

            console.log(`[${functionName}] Deleted ${deletedCount} old empty sessionReservations`);
            return { success: true, deletedCount };
        } catch (error) {
            console.error(`[${functionName}] Fatal error:`, error);
            throw error;
        }
    });

/**
 * 등록 기간 만료 임박 알림 (7일 이내 만료)
 * 매일 새벽 2시에 실행
 */
export const sendExpiringEnrollmentNotifications = functions.pubsub
    .schedule('0 2 * * *') // 매일 새벽 2시 (서울 시간)
    .timeZone('Asia/Seoul')
    .onRun(async (context: EventContext) => {
        try {
            const now = getSeoulDateTime();
            const in7Days = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);

            // 7일 이내 만료되는 등록 조회
            const enrollmentsSnapshot = await admin.firestore()
                .collection('enrollments')
                .where('validUntil', '<=', admin.firestore.Timestamp.fromDate(in7Days))
                .where('validUntil', '>', admin.firestore.Timestamp.fromDate(now))
                .get();

            console.log(`[sendExpiringEnrollmentNotifications] Found ${enrollmentsSnapshot.docs.length} expiring enrollments`);

            let totalNotifications = 0;

            for (const enrollmentDoc of enrollmentsSnapshot.docs) {
                const enrollment = enrollmentDoc.data();
                const userId = enrollment.userId as string;
                const courseId = enrollment.courseId as string;
                const placeId = enrollment.placeId as string;
                const enrollmentId = enrollmentDoc.id;

                // validUntil 날짜 계산
                const validUntil = (enrollment.validUntil as admin.firestore.Timestamp).toDate();
                const daysUntilExpiry = Math.ceil((validUntil.getTime() - now.getTime()) / (24 * 60 * 60 * 1000));

                // 이미 오늘 알림을 보냈는지 확인 (중복 방지)
                const todayString = formatDate(now);
                const notificationQuery = await admin.firestore()
                    .collection('notifications')
                    .where('userId', '==', userId)
                    .where('type', '==', 'system')
                    .where('data.enrollmentId', '==', enrollmentId)
                    .where('data.reminderType', '==', 'expiring')
                    .where('createdAt', '>=', admin.firestore.Timestamp.fromDate(seoulDateOnly(todayString)))
                    .limit(1)
                    .get();

                if (!notificationQuery.empty) {
                    // 이미 오늘 알림을 보냄
                    continue;
                }

                // 코스 정보 조회
                const placeDoc = await admin.firestore().collection('places').doc(placeId).get();
                if (!placeDoc.exists) {
                    continue;
                }
                const placeData = placeDoc.data();
                const courses = (placeData?.courses as any[]) || [];
                const course = courses.find((c: any) => c.id === courseId);
                const courseName = course?.name || courseId;

                // 알림 생성
                await createNotification({
                    userId,
                    type: 'system',
                    title: `${courseName} 등록 기간이 곧 만료됩니다`,
                    body: `${courseName} 등록 기간이 ${daysUntilExpiry}일 후 만료됩니다`,
                    placeId,
                    data: {
                        enrollmentId,
                        courseId,
                        placeId,
                        reminderType: 'expiring',
                        daysUntilExpiry,
                    },
                    isAdmin: false,
                });

                totalNotifications++;
            }

            console.log(`[sendExpiringEnrollmentNotifications] Sent ${totalNotifications} notifications`);
            return { success: true, notificationsSent: totalNotifications };
        } catch (error) {
            console.error(`[sendExpiringEnrollmentNotifications] Error:`, error);
            throw error;
        }
    });

/**
 * 일괄 예약 이동 (관리자)
 *
 * 여러 예약을 단일 트랜잭션으로 이동합니다.
 * - 관리자 권한으로 정원을 초과해서도 이동 가능
 * - 트랜잭션 write 한도 고려 (최대 450건)
 */
export const batchMoveReservations = functions.https.onCall(async (data, context) => {
    const functionName = 'batchMoveReservations';
    logFunctionStart(functionName, { userId: context.auth?.uid, reservationIds: data?.reservationIds?.length });

    if (!context.auth?.uid) {
        logFunctionError(functionName, new Error('Unauthenticated'), { data });
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    await assertAdminUid(context.auth.uid);

    const reservationIds = Array.isArray(data?.reservationIds) ? data.reservationIds.map(String) : [];
    const placeId = String(data?.placeId ?? '');
    const newDayOfWeek = Number(data?.newDayOfWeek ?? 0);
    const newStartTime = String(data?.newStartTime ?? '');
    const newReservedDateString = String(data?.newReservedDateString ?? '');

    if (reservationIds.length === 0) {
        throw new functions.https.HttpsError('invalid-argument', '예약 ID 목록이 필요합니다.');
    }
    if (!placeId || !newStartTime || !newReservedDateString || !Number.isFinite(newDayOfWeek)) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId, newDayOfWeek, newStartTime, newReservedDateString이 필요합니다.');
    }
    if (reservationIds.length > 200) {
        throw new functions.https.HttpsError('invalid-argument', '한 번에 최대 200건까지 이동할 수 있습니다.');
    }
    parseYYYYMMDD(newReservedDateString); // validate

    const db = admin.firestore();
    const now = getSeoulDateTime();
    const todayString = `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`;
    if (seoulDateOnly(newReservedDateString).getTime() < seoulDateOnly(todayString).getTime()) {
        throw new functions.https.HttpsError('failed-precondition', '과거 날짜로는 이동할 수 없습니다.');
    }

    // 트랜잭션 외부에서 사용할 변수들
    const results: Array<{ reservationId: string; success: boolean; error?: string }> = [];
    const userIds = new Set<string>();
    let reservationsByCourse: Map<string, Array<{ doc: FirebaseFirestore.DocumentSnapshot; ref: FirebaseFirestore.DocumentReference }>> = new Map();

    return await db.runTransaction(async (tx) => {
        // 1) 모든 예약 조회 (선행 read)
        const reservationRefs = reservationIds.map((id: string) =>
            db.collection('places').doc(placeId).collection('reservations').doc(id)
        );
        const reservationDocs = await Promise.all(reservationRefs.map((ref: FirebaseFirestore.DocumentReference) => tx.get(ref)));

        // 2) 예약 데이터 검증 및 그룹화
        reservationsByCourse = new Map();
        for (let i = 0; i < reservationDocs.length; i++) {
            const doc = reservationDocs[i];
            if (!doc.exists) {
                results.push({ reservationId: reservationIds[i], success: false, error: '예약을 찾을 수 없습니다.' });
                continue;
            }

            const reservation = doc.data() as any;
            const courseId = String(reservation?.courseId ?? '');
            const userId = String(reservation?.userId ?? '');
            const oldDayOfWeek = Number(reservation?.dayOfWeek ?? 0);
            const oldStartTime = String(reservation?.startTime ?? '');
            const oldReservedDateString = String(reservation?.reservedDateString ?? '');

            if (!courseId || !userId || !oldStartTime || !oldReservedDateString) {
                results.push({ reservationId: reservationIds[i], success: false, error: '예약 데이터가 올바르지 않습니다.' });
                continue;
            }

            // 같은 세션으로 이동하려는 경우 스킵
            if (oldDayOfWeek === newDayOfWeek && oldStartTime === newStartTime && oldReservedDateString === newReservedDateString) {
                results.push({ reservationId: reservationIds[i], success: true });
                continue;
            }

            userIds.add(userId);
            if (!reservationsByCourse.has(courseId)) {
                reservationsByCourse.set(courseId, []);
            }
            reservationsByCourse.get(courseId)!.push({ doc, ref: reservationRefs[i] });
        }

        // 3) 코스별 capacity 확인 (새로운 sessionReservations 생성 시 사용)
        const capacities = new Map<string, number>();
        const placeDoc = await tx.get(db.collection('places').doc(placeId));
        if (!placeDoc.exists) {
            throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
        }
        const place = placeDoc.data()!;

        for (const [courseId] of reservationsByCourse.entries()) {
            const newSessionId = `${courseId}_${newDayOfWeek}_${newStartTime}`;
            const newSrRef = db.collection('sessionReservations').doc(`${newSessionId}_${newReservedDateString}`);
            const newSrDoc = await tx.get(newSrRef);

            const capacityFromSr = newSrDoc.exists ? Number(newSrDoc.data()?.capacity ?? 0) : 0;
            let capacity = Number.isFinite(capacityFromSr) && capacityFromSr > 0 ? capacityFromSr : 0;

            if (!(Number.isFinite(capacity) && capacity > 0)) {
                const course = findCourse(place, courseId);
                if (!course) throw new functions.https.HttpsError('not-found', `코스를 찾을 수 없습니다: ${courseId}`);
                const session = findSession(course, newDayOfWeek, newStartTime);

                if (!session) {
                    // 정기 일정이 없으면 비정기 일정(courseOverrides) 확인
                    const overrideQuery = db
                        .collection('courseOverrides')
                        .where('courseId', '==', courseId)
                        .where('placeId', '==', placeId)
                        .where('date', '==', newReservedDateString)
                        .where('dayOfWeek', '==', newDayOfWeek)
                        .where('startTime', '==', newStartTime)
                        .where('isCancelled', '==', false)
                        .limit(1);
                    const overrideSnap = await tx.get(overrideQuery as any);

                    if (overrideSnap.empty) {
                        throw new functions.https.HttpsError('not-found', '세션을 찾을 수 없습니다.');
                    }

                    const overrideData = overrideSnap.docs[0].data() as any;
                    capacity = Number(overrideData?.capacity ?? 0);
                } else {
                    // 정기 일정인 경우 capacity 확인 (dateCapacityOverrides 우선)
                    const overrideQuery = db.collection('dateCapacityOverrides')
                        .where('sessionId', '==', newSessionId)
                        .where('date', '==', newReservedDateString)
                        .limit(1);
                    const overrideSnap = await tx.get(overrideQuery as any);
                    const overrideCap = !overrideSnap.empty
                        ? Number(((overrideSnap.docs[0].data() as any)?.capacity ?? 0) as any)
                        : undefined;
                    capacity = Number.isFinite(overrideCap) ? (overrideCap as number) : Number(session.capacity ?? 0);
                }
            }

            // 계산된 capacity 저장 (새로운 sessionReservations 생성 시 사용)
            capacities.set(courseId, capacity);

            // 관리자 일괄 이동은 정원 무시 (관리자 권한)
            // 정원 체크 없이 이동 허용
        }

        // 4) 모든 old/new sessionReservations 조회 (선행 read)
        const srRefs = new Map<string, { oldRef: FirebaseFirestore.DocumentReference; newRef: FirebaseFirestore.DocumentReference; oldDoc?: FirebaseFirestore.DocumentSnapshot; newDoc?: FirebaseFirestore.DocumentSnapshot }>();

        for (const [courseId, reservations] of reservationsByCourse.entries()) {
            for (const { doc } of reservations) {
                const reservation = doc.data() as any;
                const oldDayOfWeek = Number(reservation?.dayOfWeek ?? 0);
                const oldStartTime = String(reservation?.startTime ?? '');
                const oldReservedDateString = String(reservation?.reservedDateString ?? '');

                const oldSessionId = `${courseId}_${oldDayOfWeek}_${oldStartTime}`;
                const newSessionId = `${courseId}_${newDayOfWeek}_${newStartTime}`;
                const srKey = `${oldSessionId}_${oldReservedDateString}_${newSessionId}_${newReservedDateString}`;

                if (!srRefs.has(srKey)) {
                    const oldSrRef = db.collection('sessionReservations').doc(`${oldSessionId}_${oldReservedDateString}`);
                    const newSrRef = db.collection('sessionReservations').doc(`${newSessionId}_${newReservedDateString}`);
                    const [oldSrDoc, newSrDoc] = await Promise.all([tx.get(oldSrRef), tx.get(newSrRef)]);
                    srRefs.set(srKey, { oldRef: oldSrRef, newRef: newSrRef, oldDoc: oldSrDoc, newDoc: newSrDoc });
                }
            }
        }

        // 5) 예약 업데이트 및 sessionReservations 업데이트 (write)
        for (const [courseId, reservations] of reservationsByCourse.entries()) {
            for (const { doc, ref } of reservations) {
                const reservation = doc.data() as any;
                const oldDayOfWeek = Number(reservation?.dayOfWeek ?? 0);
                const oldStartTime = String(reservation?.startTime ?? '');
                const oldReservedDateString = String(reservation?.reservedDateString ?? '');

                const oldSessionId = `${courseId}_${oldDayOfWeek}_${oldStartTime}`;
                const newSessionId = `${courseId}_${newDayOfWeek}_${newStartTime}`;
                const srKey = `${oldSessionId}_${oldReservedDateString}_${newSessionId}_${newReservedDateString}`;
                const sr = srRefs.get(srKey)!;

                // reservation 업데이트
                tx.update(ref, {
                    dayOfWeek: newDayOfWeek,
                    startTime: newStartTime,
                    reservedDateString: newReservedDateString,
                    reservedDate: admin.firestore.Timestamp.fromDate(seoulDateOnly(newReservedDateString)),
                });

                // old sessionReservations decrement
                if (sr.oldDoc?.exists) {
                    const currentOld = Number(sr.oldDoc.data()?.reservedCount ?? 0);
                    tx.update(sr.oldRef, {
                        reservedCount: Math.max(0, currentOld - 1),
                        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                    });
                }

                // new sessionReservations increment
                if (sr.newDoc?.exists) {
                    const currentNew = Number(sr.newDoc.data()?.reservedCount ?? 0);
                    tx.update(sr.newRef, {
                        reservedCount: currentNew + 1,
                        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                    });
                } else {
                    // 새로운 sessionReservations 생성 시 올바른 capacity 설정
                    const capacity = capacities.get(courseId) ?? 0;
                    tx.set(sr.newRef, {
                        sessionId: newSessionId,
                        courseId,
                        placeId,
                        dayOfWeek: newDayOfWeek,
                        startTime: newStartTime,
                        date: newReservedDateString,
                        capacity: capacity, // 계산된 capacity 사용
                        reservedCount: 1,
                        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                        createdAt: admin.firestore.FieldValue.serverTimestamp(),
                    });
                }

                results.push({ reservationId: ref.id, success: true });
            }
        }

        logFunctionSuccess(functionName, { reservationIds: reservationIds.length, moved: results.filter(r => r.success).length });
        return { success: true, results, movedCount: results.filter(r => r.success).length };
    }).then(async (result) => {
        // 트랜잭션 완료 후 알림 생성 (트랜잭션 밖에서 실행)
        if (result?.success && userIds.size > 0) {
            try {
                const place = await getPlaceOrThrow(placeId);
                const courseName = getCourseName(place, Array.from(reservationsByCourse.keys())[0]) || '코스';
                const formatDate = (dateStr: string): string => {
                    const { y, mo, d } = parseYYYYMMDD(dateStr);
                    return `${y}년 ${mo}월 ${d}일`;
                };
                const newDateFormatted = formatDate(newReservedDateString);

                // 각 사용자에게 알림 전송
                for (const userId of userIds) {
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: `${courseName} 예약이 변경되었습니다`,
                        body: `${courseName} - ${newDateFormatted} ${newStartTime}로 변경되었습니다.`,
                        placeId,
                        data: {
                            reservationIds: reservationIds,
                            courseId: Array.from(reservationsByCourse.keys())[0],
                            placeId,
                        },
                        isAdmin: false,
                    });
                }
            } catch (error) {
                console.error(`[batchMoveReservations] Error creating notifications:`, error);
            }
        }
        return result;
    }).catch((error) => {
        logFunctionError(functionName, error, { reservationIds: reservationIds.length, placeId });
        throw error;
    });
});

/**
 * 일괄 예약 취소 (관리자)
 *
 * 여러 예약을 단일 트랜잭션으로 취소합니다.
 * - 관리자 권한으로 1시간 제한 우회 가능 (단, 이미 시작된 세션은 취소 불가)
 * - 트랜잭션 write 한도 고려 (최대 450건)
 */
export const batchCancelReservations = functions.https.onCall(async (data, context) => {
    const functionName = 'batchCancelReservations';
    logFunctionStart(functionName, { userId: context.auth?.uid, reservationIds: data?.reservationIds?.length });

    if (!context.auth?.uid) {
        logFunctionError(functionName, new Error('Unauthenticated'), { data });
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const callerId = context.auth.uid;
    const reservationIds = Array.isArray(data?.reservationIds) ? data.reservationIds.map(String) : [];
    const placeId = String(data?.placeId ?? '');

    if (reservationIds.length === 0) {
        throw new functions.https.HttpsError('invalid-argument', '예약 ID 목록이 필요합니다.');
    }
    if (!placeId) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId가 필요합니다.');
    }
    if (reservationIds.length > 200) {
        throw new functions.https.HttpsError('invalid-argument', '한 번에 최대 200건까지 취소할 수 있습니다.');
    }

    const db = admin.firestore();
    const seoulNow = getSeoulDateTime();
    const isAdminForThisPlace = await isAdminForPlaceUid(callerId, placeId);
    if (!isAdminForThisPlace) {
        throw new functions.https.HttpsError('permission-denied', '해당 플레이스에 대한 관리자 권한이 필요합니다.');
    }

    const results: Array<{ reservationId: string; success: boolean; error?: string }> = [];
    const userIds = new Set<string>();
    const courseIds = new Set<string>();

    // 트랜잭션 밖에서 예약 조회 및 검증
    const reservationRefs = reservationIds.map((id: string) =>
        db.collection('places').doc(placeId).collection('reservations').doc(id)
    );
    const reservationDocs = await Promise.all(reservationRefs.map((ref: FirebaseFirestore.DocumentReference) => ref.get()));

    // 예약 데이터 검증 및 취소 가능 여부 확인
    const reservationsToCancel: Array<{ doc: FirebaseFirestore.DocumentSnapshot; ref: FirebaseFirestore.DocumentReference; reservation: any }> = [];

    for (let i = 0; i < reservationDocs.length; i++) {
        const doc = reservationDocs[i];
        if (!doc.exists) {
            results.push({ reservationId: reservationIds[i], success: false, error: '예약을 찾을 수 없습니다.' });
            continue;
        }

        const reservation = doc.data() as any;
        const reservationUserId = String(reservation?.userId ?? '');
        const courseId = String(reservation?.courseId ?? '');
        const dayOfWeek = Number(reservation?.dayOfWeek ?? 0);
        const startTime = String(reservation?.startTime ?? '');
        const reservedDateString = String(reservation?.reservedDateString ?? '');

        if (!reservationUserId || !courseId || !startTime || !reservedDateString || !Number.isFinite(dayOfWeek)) {
            results.push({ reservationId: reservationIds[i], success: false, error: '예약 데이터가 올바르지 않습니다.' });
            continue;
        }

        // 취소 가능 여부 검증 (이미 시작된 세션은 취소 불가)
        let y: number, mo: number, d: number, h: number, m: number;
        try {
            const parsedDate = parseYYYYMMDD(reservedDateString);
            y = parsedDate.y;
            mo = parsedDate.mo;
            d = parsedDate.d;
            const parsedTime = parseHHmm(startTime);
            h = parsedTime.h;
            m = parsedTime.m;
        } catch (error) {
            results.push({ reservationId: reservationIds[i], success: false, error: '날짜/시간 형식이 올바르지 않습니다.' });
            continue;
        }

        const sessionStart = makeSeoulDateTime(y, mo, d, h, m);
        if (seoulNow.getTime() >= sessionStart.getTime()) {
            results.push({ reservationId: reservationIds[i], success: false, error: '이미 시작된 세션은 취소할 수 없습니다.' });
            continue;
        }

        userIds.add(reservationUserId);
        courseIds.add(courseId);
        reservationsToCancel.push({ doc, ref: reservationRefs[i], reservation });
    }

    // 트랜잭션 밖에서 enrollment 조회
    const enrollmentRefs = new Map<string, FirebaseFirestore.DocumentReference>();
    const enrollmentDocs = new Map<string, FirebaseFirestore.DocumentSnapshot>();
    const pendingRefs = new Map<string, FirebaseFirestore.DocumentReference>(); // key: pendingId (placeId_phoneNumber)

    for (const { reservation } of reservationsToCancel) {
        const userId = String(reservation.userId);
        const courseId = String(reservation.courseId);
        const enrollmentId = `${userId}_${placeId}_${courseId}`;

        // pending 멤버는 enrollments가 아니라 pendingMembers.courseEnrollments로 크레딧 복구해야 함
        if (userId.startsWith('pending_')) {
            const pendingId = userId.replace('pending_', '');
            if (pendingId) {
                pendingRefs.set(pendingId, db.collection('pendingMembers').doc(pendingId));
            }
            continue;
        }

        if (!enrollmentRefs.has(enrollmentId)) {
            const enrollmentQuery = db
                .collection('enrollments')
                .where('userId', '==', userId)
                .where('courseId', '==', courseId)
                .where('placeId', '==', placeId)
                .limit(1);
            const enrollmentSnap = await enrollmentQuery.get();
            if (!enrollmentSnap.empty) {
                const enrollmentDoc = enrollmentSnap.docs[0];
                enrollmentRefs.set(enrollmentId, enrollmentDoc.ref);
                enrollmentDocs.set(enrollmentId, enrollmentDoc);
            }
        }
    }

    return await db.runTransaction(async (tx) => {
        // 트랜잭션 내부에서 enrollment 문서 다시 읽기 (트랜잭션 규칙 준수)
        const enrollmentDocsInTx = new Map<string, FirebaseFirestore.DocumentSnapshot>();
        for (const [enrollmentId, ref] of enrollmentRefs.entries()) {
            enrollmentDocsInTx.set(enrollmentId, await tx.get(ref));
        }
        const pendingDocsInTx = new Map<string, FirebaseFirestore.DocumentSnapshot>();
        for (const [pendingId, ref] of pendingRefs.entries()) {
            pendingDocsInTx.set(pendingId, await tx.get(ref));
        }

        // 2) 모든 sessionReservations 조회 (선행 read)
        const srRefs = new Map<string, { ref: FirebaseFirestore.DocumentReference; doc: FirebaseFirestore.DocumentSnapshot }>();

        for (const { reservation } of reservationsToCancel) {
            const courseId = String(reservation.courseId);
            const dayOfWeek = Number(reservation.dayOfWeek);
            const startTime = String(reservation.startTime);
            const reservedDateString = String(reservation.reservedDateString);
            const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
            const srKey = `${sessionId}_${reservedDateString}`;

            if (!srRefs.has(srKey)) {
                const ref = db.collection('sessionReservations').doc(srKey);
                srRefs.set(srKey, { ref, doc: await tx.get(ref) });
            }
        }

        // 3) enrollment remainingReservations 업데이트 (write)
        const enrollmentUpdates = new Map<string, { remaining: number; total: number }>();
        const pendingCreditAdds = new Map<string, Map<string, number>>(); // pendingId -> (courseId -> count)

        for (const { reservation } of reservationsToCancel) {
            const userId = String(reservation.userId);
            const courseId = String(reservation.courseId);
            const enrollmentId = `${userId}_${placeId}_${courseId}`;
            const enrollmentDoc = enrollmentDocsInTx.get(enrollmentId);

            if (userId.startsWith('pending_')) {
                const pendingId = userId.replace('pending_', '');
                if (pendingId) {
                    if (!pendingCreditAdds.has(pendingId)) pendingCreditAdds.set(pendingId, new Map());
                    const m = pendingCreditAdds.get(pendingId)!;
                    m.set(courseId, (m.get(courseId) ?? 0) + 1);
                }
                continue;
            }

            if (enrollmentDoc?.exists) {
                if (!enrollmentUpdates.has(enrollmentId)) {
                    const enrollmentData = enrollmentDoc.data() as any;
                    const remaining = Number((enrollmentData?.remainingReservations ?? 0) as any);
                    const total = Number((enrollmentData?.totalReservations ?? 0) as any);
                    enrollmentUpdates.set(enrollmentId, { remaining, total });
                }
                const update = enrollmentUpdates.get(enrollmentId)!;
                update.remaining = Math.min(update.total, update.remaining + 1);
            }
        }

        for (const [enrollmentId, update] of enrollmentUpdates.entries()) {
            const ref = enrollmentRefs.get(enrollmentId)!;
            tx.update(ref, { remainingReservations: update.remaining });
        }

        // pendingMembers 크레딧 복구
        for (const [pendingId, byCourse] of pendingCreditAdds.entries()) {
            const pendingDoc = pendingDocsInTx.get(pendingId);
            if (!pendingDoc?.exists) continue;
            const pendingData = pendingDoc.data() as any;
            if (!Array.isArray(pendingData?.courseEnrollments)) continue;
            const courseEnrollments = pendingData.courseEnrollments;
            const updated = courseEnrollments.map((ce: any) => {
                const ceCourseId = String(ce?.courseId ?? '');
                const add = byCourse.get(ceCourseId) ?? 0;
                if (add <= 0) return ce;
                const total = Number(ce?.totalReservations ?? 0);
                const remainingBase = Number(ce?.remainingReservations ?? total);
                const newRemaining = Math.min(total, remainingBase + add);
                return { ...ce, remainingReservations: newRemaining };
            });
            tx.update(pendingDoc.ref, { courseEnrollments: updated });
        }

        // 4) sessionReservations reservedCount 업데이트 (write)
        const srUpdates = new Map<string, number>();

        for (const { reservation } of reservationsToCancel) {
            const courseId = String(reservation.courseId);
            const dayOfWeek = Number(reservation.dayOfWeek);
            const startTime = String(reservation.startTime);
            const reservedDateString = String(reservation.reservedDateString);
            const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
            const srKey = `${sessionId}_${reservedDateString}`;

            if (!srUpdates.has(srKey)) {
                const sr = srRefs.get(srKey)!;
                if (sr.doc.exists) {
                    srUpdates.set(srKey, Number(sr.doc.data()?.reservedCount ?? 0));
                } else {
                    srUpdates.set(srKey, 0);
                }
            }
            srUpdates.set(srKey, Math.max(0, srUpdates.get(srKey)! - 1));
        }

        for (const [srKey, newCount] of srUpdates.entries()) {
            const sr = srRefs.get(srKey)!;
            if (sr.doc.exists) {
                tx.update(sr.ref, {
                    reservedCount: newCount,
                    lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                });
            }
        }

        // 5) 예약 삭제 (write)
        for (const { ref } of reservationsToCancel) {
            tx.delete(ref);
            results.push({ reservationId: ref.id, success: true });
        }

        logFunctionSuccess(functionName, { reservationIds: reservationIds.length, cancelled: results.filter(r => r.success).length });
        return { success: true, results, cancelledCount: results.filter(r => r.success).length };
    }).then(async (result) => {
        // 트랜잭션 완료 후 알림 생성 (트랜잭션 밖에서 실행)
        if (result?.success && userIds.size > 0) {
            try {
                const place = await getPlaceOrThrow(placeId);
                const courseName = getCourseName(place, Array.from(courseIds)[0]) || '코스';

                // 각 사용자에게 알림 전송
                for (const userId of userIds) {
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: `${courseName} 예약이 취소되었습니다`,
                        body: `${courseName} 예약이 취소되었습니다.`,
                        placeId,
                        data: {
                            reservationIds: reservationIds,
                            courseId: Array.from(courseIds)[0],
                            placeId,
                        },
                        isAdmin: false,
                    });
                }
            } catch (error) {
                console.error(`[batchCancelReservations] Error creating notifications:`, error);
            }
        }
        return result;
    }).catch((error) => {
        logFunctionError(functionName, error, { reservationIds: reservationIds.length, placeId });
        throw error;
    });
});

/**
 * 플레이스 서버 검색 (이름/위치 포함 검색)
 * - 인증 불필요 (공개 검색)
 * - 최대 100건 반환
 */
export const searchPlaces = functions.https.onCall(async (data, context) => {
    const functionName = 'searchPlaces';
    const query = typeof data?.query === 'string' ? (data.query as string).trim().toLowerCase() : '';
    logFunctionStart(functionName, { queryLength: query.length });

    if (query.length === 0) {
        logFunctionSuccess(functionName, { count: 0 });
        return { places: [] };
    }

    const db = admin.firestore();
    const snapshot = await db.collection('places').limit(300).get();
    const maxResults = 100;
    const places: { id: string; name: string; adminId: string; description?: string; location?: string; imageUrl?: string; appBarText?: string; greetingText?: string; courses: unknown[] }[] = [];

    for (const doc of snapshot.docs) {
        if (places.length >= maxResults) break;
        const d = doc.data();
        const name = (d.name as string) || '';
        const location = (d.location as string) || '';
        const nameMatch = name.toLowerCase().includes(query);
        const locationMatch = location.toLowerCase().includes(query);
        if (!nameMatch && !locationMatch) continue;

        places.push({
            id: doc.id,
            name: name,
            adminId: (d.adminId as string) ?? '',
            description: d.description as string | undefined,
            location: location || undefined,
            imageUrl: d.imageUrl as string | undefined,
            appBarText: d.appBarText as string | undefined,
            greetingText: d.greetingText as string | undefined,
            courses: (d.courses as unknown[]) || [],
        });
    }

    logFunctionSuccess(functionName, { count: places.length });
    return { places };
});

