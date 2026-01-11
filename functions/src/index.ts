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
    const openWeekStart = addDaysUtc(weekStart, -(7 * (w.weeksAhead ?? 1)));
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
}: {
    now: Date;
    policy: CoursePolicy;
    sessionDateString: string;
    startTime: string;
    capacity: number;
    reservedCount: number;
    enrollmentCanReserve: boolean;
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

    // 4) 오픈 정책
    const openAt = computeOpenAt({ policy, sessionDateString });
    if (openAt && now.getTime() < openAt.getTime()) {
        return { canReserve: false, reason: ReservationLockReason.notOpenedYet, openAt };
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
            const db = admin.firestore();
            const userId = String(enrollment.userId ?? '');
            const placeId = String(enrollment.placeId ?? '');
            const courseId = String(enrollment.courseId ?? '');

            // 디버깅/관리자 콘솔 가독성을 위해 이름을 denormalize
            let userName = userId;
            let courseName = courseId;
            try {
                if (userId) {
                    const userDoc = await db.collection('users').doc(userId).get();
                    const name = (userDoc.exists ? (userDoc.data() as any)?.name : undefined) as string | undefined;
                    const trimmed = (name ?? '').trim();
                    if (trimmed) userName = trimmed;
                }
            } catch (e) {
                console.warn('[onEnrollmentCreated] Failed to fetch user name', { userId, e });
            }

            try {
                if (placeId && courseId) {
                    const place = await getPlaceOrThrow(placeId);
                    courseName = getCourseName(place, courseId);
                }
            } catch (e) {
                console.warn('[onEnrollmentCreated] Failed to fetch course name', { placeId, courseId, e });
            }

            // enrollments + courseMembers를 함께 갱신
            const enrollmentRef = db.collection('enrollments').doc(enrollmentId);
            const courseMemberRef = db.collection('courseMembers').doc();
            const batch = db.batch();

            // 🔎 Firebase 콘솔 디버깅용 필드 (denormalized)
            batch.set(
                enrollmentRef,
                { userName, courseName },
                { merge: true },
            );

            // courseMembers 컬렉션에 추가
            batch.set(courseMemberRef, {
                userId,
                courseId,
                placeId,
                enrollmentId: enrollmentId,
                enrolledAt: enrollment.enrolledAt || admin.firestore.FieldValue.serverTimestamp(),
                isActive: true,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            await batch.commit();

            console.log(`[onEnrollmentCreated] Created courseMember for user ${userId}, course ${courseId}`);
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

        // status 제거로 항상 멤버이므로 enrollments 생성 진행

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

            // enrollments 생성 (트랜잭션으로 중복 방지)
            // place에서 course 정보 가져오기 (defaultTotalReservations 사용)
            const placeDoc = await admin.firestore().collection('places').doc(placeId).get();
            if (!placeDoc.exists) {
                logWarn('onPlaceMembershipCreated', { message: `Place ${placeId} not found` });
                return;
            }

            const placeData = placeDoc.data();
            const courses = (placeData?.courses as any[]) || [];

            const enrollmentTime = admin.firestore.Timestamp.now();
            let createdCount = 0;

            // ✅ 트랜잭션으로 enrollments 생성 (race condition 방지)
            await admin.firestore().runTransaction(async (transaction) => {
                for (const courseId of courseIds) {
                    // ✅ 고정 ID 사용으로 중복 생성 완전 방지
                    const enrollmentId = `${userId}_${placeId}_${courseId}`;
                    const enrollmentRef = admin.firestore().collection('enrollments').doc(enrollmentId);

                    // ✅ 트랜잭션 내부에서 중복 확인
                    const existingEnrollment = await transaction.get(enrollmentRef);
                    if (existingEnrollment.exists) {
                        logWarn('onPlaceMembershipCreated', { message: `Enrollment already exists: ${enrollmentId}` });
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

                    transaction.set(enrollmentRef, {
                        id: enrollmentId,
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
            });

            if (createdCount > 0) {
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
    // 고정ID 패턴: ${sessionId}_${date}
    const overrideId = `${sessionId}_${dateString}`;
    const overrideRef = admin.firestore().collection('dateCapacityOverrides').doc(overrideId);
    const overrideDoc = await overrideRef.get();

    if (overrideDoc.exists) {
        return overrideDoc.data()!.capacity;
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

    // reservedDateString 검증
    const { y, mo, d } = parseYYYYMMDD(reservedDateString);
    const reservedDate = makeSeoulDateTime(y, mo, d, 0, 0);

    const db = admin.firestore();
    const seoulNow = getSeoulDateTime();
    const now = seoulNow; // 서울 시간대 통일 (클라이언트와 일관성 유지)

    const policyRef = db.collection('coursePolicies').doc(courseId);
    const placeRef = db.collection('places').doc(placeId);

    // 동일 유저 중복 예약 방지(최소한)
    // (트랜잭션 내 query를 지원하므로 transaction.get(query)로 처리)

    return await db.runTransaction(async (tx) => {
        // 1) enrollment 검증
        // ✅ 런타임 쿼리 0 정책: enrollments는 반드시 고정 ID(`${userId}_${placeId}_${courseId}`)여야 한다.
        // - 만약 없으면 데이터가 아직 마이그레이션되지 않은 상태이므로 실패 처리한다.
        const enrollmentId = `${userId}_${placeId}_${courseId}`;
        const enrollmentRef = db.collection('enrollments').doc(enrollmentId);
        const enrollmentDoc = await tx.get(enrollmentRef);
        if (!enrollmentDoc.exists) {
            throw new functions.https.HttpsError(
                'failed-precondition',
                '등록된 코스가 아닙니다. (enrollments 마이그레이션이 필요합니다)',
                { enrollmentId, placeId, courseId },
            );
        }

        const enrollmentData = enrollmentDoc.data() as any;
        const remainingReservations = Number((enrollmentData?.remainingReservations ?? 0) as any);
        const validFrom = (enrollmentData?.validFrom instanceof admin.firestore.Timestamp)
            ? enrollmentData.validFrom.toDate()
            : (enrollmentData?.validFrom ? new Date(enrollmentData.validFrom) : new Date(0));
        const validUntil = (enrollmentData?.validUntil instanceof admin.firestore.Timestamp)
            ? enrollmentData.validUntil.toDate()
            : (enrollmentData?.validUntil ? new Date(enrollmentData.validUntil) : new Date(0));

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
        const session = findSession(course, dayOfWeek, startTime);
        if (!session) {
            throw new functions.https.HttpsError('not-found', '세션을 찾을 수 없습니다.');
        }

        // 3) 정책 로드(active/scheduled/effectiveFrom)
        const policyDoc = await tx.get(policyRef);
        const policyData = policyDoc.exists ? (policyDoc.data() as CoursePolicyDoc) : null;
        const policy = selectEffectivePolicy(now, policyData, { courseId, placeId });

        // 4) capacity(override 우선) - 고정ID 패턴: ${sessionId}_${date}
        const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
        const overrideId = `${sessionId}_${reservedDateString}`;
        const overrideRef = db.collection('dateCapacityOverrides').doc(overrideId);
        const overrideDoc = await tx.get(overrideRef);
        const overrideCap = overrideDoc.exists
            ? Number(((overrideDoc.data() as any)?.capacity ?? 0) as any)
            : undefined;
        const capacity = Number.isFinite(overrideCap) ? (overrideCap as number) : Number(session.capacity ?? 0);

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

        // 7) 중앙 정책 엔진(서버 버전)으로 최종 검증
        // 관리자가 다른 사용자를 위해 예약 생성 시: 정원 초과/오픈 전/마감 전은 허용, 과거 날짜만 차단
        const eligibility = evaluateReservation({
            now,
            policy,
            sessionDateString: reservedDateString,
            startTime,
            capacity,
            reservedCount: currentReservedCount,
            enrollmentCanReserve,
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
                // 일반 사용자: 모든 정책 검증 적용
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

        // 10) enrollment remainingReservations--
        // 불변식: remainingReservations는 음수가 되면 안 됨 (관리자도 크레딧/기간은 우회 불가)
        if (remainingReservations <= 0) {
            throw new functions.https.HttpsError(
                'failed-precondition',
                '남은 예약 횟수가 없습니다.',
                { reason: ReservationLockReason.noCreditsOrExpired },
            );
        }
        tx.update(enrollmentRef, { remainingReservations: remainingReservations - 1 });

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
    }).catch((error) => {
        logFunctionError(functionName, error, { userId, courseId, reservedDateString });
        throw error;
    });
});

export const cancelReservation = functions.https.onCall(async (data, context) => {
    const functionName = 'cancelReservation';
    logFunctionStart(functionName, { userId: context.auth?.uid, reservationId: data?.reservationId });

    if (!context.auth?.uid) {
        logFunctionError(functionName, new Error('Unauthenticated'), { data });
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const callerId = context.auth.uid;
    const reservationId = String(data?.reservationId ?? '');
    const placeId = String(data?.placeId ?? '');
    if (!reservationId || !placeId) {
        logFunctionError(functionName, new Error('Invalid arguments'), { reservationId, placeId });
        throw new functions.https.HttpsError('invalid-argument', 'reservationId와 placeId가 필요합니다.');
    }

    const db = admin.firestore();

    // 관리자(해당 플레이스) 여부: 관리자는 타인 예약도 취소 가능 + 1시간 제한 우회(단, 시작 후 취소는 차단)
    const isAdminForThisPlace = await isAdminForPlaceUid(callerId, placeId);

    // 트랜잭션 외부에서 사용할 변수들
    let courseId = '';
    let reservedDateString = '';
    let startTime = '';
    let reservationUserId = '';

    return await db.runTransaction(async (tx) => {
        // 플레이스 서브컬렉션에서 예약 조회
        const reservationRef = db
            .collection('places')
            .doc(placeId)
            .collection('reservations')
            .doc(reservationId);
        const reservationDoc = await tx.get(reservationRef);
        if (!reservationDoc.exists) {
            throw new functions.https.HttpsError('not-found', '예약을 찾을 수 없습니다.');
        }

        const reservation = reservationDoc.data()!;
        reservationUserId = String(reservation.userId ?? '');
        if (!reservationUserId) {
            throw new functions.https.HttpsError('failed-precondition', '예약 데이터가 올바르지 않습니다. (userId 누락)');
        }

        // 권한: 본인 예약이거나, 해당 place 관리자만
        if (!isAdminForThisPlace && reservationUserId !== callerId) {
            throw new functions.https.HttpsError('permission-denied', '본인의 예약만 취소할 수 있습니다.');
        }

        courseId = String(reservation.courseId ?? '');
        const dayOfWeek = Number(reservation.dayOfWeek ?? 0);
        startTime = String(reservation.startTime ?? '');
        reservedDateString = String(reservation.reservedDateString ?? '');

        console.log(`[cancelReservation] Reservation data: courseId=${courseId}, dayOfWeek=${dayOfWeek}, startTime=${startTime}, reservedDateString=${reservedDateString}`);

        if (!courseId || !placeId || !startTime || !reservedDateString || !Number.isFinite(dayOfWeek)) {
            console.error(`[cancelReservation] Invalid reservation data: courseId=${courseId}, placeId=${placeId}, startTime=${startTime}, reservedDateString=${reservedDateString}, dayOfWeek=${dayOfWeek}`);
            throw new functions.https.HttpsError('failed-precondition', '예약 데이터가 올바르지 않습니다.');
        }

        // 취소 가능 여부 검증
        // - 일반 사용자: 세션 시작 1시간 전까지만 취소 가능
        // - 관리자: 1시간 제한은 우회 가능하되, 이미 시작된 세션은 취소 불가(정합성/악용 방지)
        const seoulNow = getSeoulDateTime();
        console.log(`[cancelReservation] Seoul now: ${seoulNow.toISOString()}`);

        let y: number, mo: number, d: number, h: number, m: number;
        try {
            const parsedDate = parseYYYYMMDD(reservedDateString);
            y = parsedDate.y;
            mo = parsedDate.mo;
            d = parsedDate.d;
        } catch (error) {
            console.error(`[cancelReservation] Error parsing date: ${reservedDateString}`, error);
            throw new functions.https.HttpsError('failed-precondition', `날짜 형식이 올바르지 않습니다: ${reservedDateString}`);
        }

        try {
            const parsedTime = parseHHmm(startTime);
            h = parsedTime.h;
            m = parsedTime.m;
        } catch (error) {
            console.error(`[cancelReservation] Error parsing time: ${startTime}`, error);
            throw new functions.https.HttpsError('failed-precondition', `시간 형식이 올바르지 않습니다: ${startTime}`);
        }

        const sessionStart = makeSeoulDateTime(y, mo, d, h, m);
        console.log(`[cancelReservation] Session start: ${sessionStart.toISOString()}`);
        const closeAt = new Date(sessionStart.getTime() - 60 * 60_000); // 1시간 전
        if (isAdminForThisPlace) {
            if (seoulNow.getTime() >= sessionStart.getTime()) {
                throw new functions.https.HttpsError(
                    'failed-precondition',
                    '이미 시작된 세션은 취소할 수 없습니다.'
                );
            }
        } else {
            if (seoulNow.getTime() >= closeAt.getTime()) {
                throw new functions.https.HttpsError(
                    'failed-precondition',
                    '세션 시작 1시간 전까지만 취소 가능합니다.'
                );
            }
        }

        // ✅ Firestore 트랜잭션 규칙: 모든 read가 write보다 먼저 수행되어야 함.
        // ✅ 최적화: 쿼리 대신 고정 ID로 직접 문서 참조 (훨씬 빠름)
        // 아래에서 enrollment/sr 문서를 "먼저 읽고", 이후 update/delete를 수행한다.

        // 1) enrollment 조회(선행 read) - 고정 ID 패턴 사용으로 쿼리 대신 직접 참조
        const enrollmentId = `${reservationUserId}_${placeId}_${courseId}`;
        const enrollmentRef = db.collection('enrollments').doc(enrollmentId);
        const enrollmentDoc = await tx.get(enrollmentRef);

        // 2) sessionReservations 조회(선행 read)
        const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
        const srRef = db.collection('sessionReservations').doc(`${sessionId}_${reservedDateString}`);
        const srDoc = await tx.get(srRef);

        // 3) enrollment remainingReservations++ (최대 total까지) (write)
        if (enrollmentDoc.exists) {
            const enrollmentData = enrollmentDoc.data() as any;
            const remaining = Number((enrollmentData?.remainingReservations ?? 0) as any);
            const total = Number((enrollmentData?.totalReservations ?? 0) as any);
            const newRemaining = Math.min(total, remaining + 1);
            console.log(`[cancelReservation] Restoring enrollment credits. userId=${reservationUserId}, courseId=${courseId}, remaining=${remaining} -> ${newRemaining}, total=${total}`);
            tx.update(enrollmentRef, { remainingReservations: newRemaining });
        } else {
            console.warn(`[cancelReservation] Enrollment not found. enrollmentId=${enrollmentId} (skip credit restore)`);
        }

        // 4) sessionReservations reservedCount-- (존재하는 경우만) (write)
        if (srDoc.exists) {
            const current = Number((srDoc.data() as any)?.reservedCount ?? 0);
            const newCount = Math.max(0, current - 1);
            console.log(`[cancelReservation] Decrementing sessionReservations. sessionId=${sessionId}, date=${reservedDateString}, count=${current} -> ${newCount}`);
            tx.update(srRef, {
                reservedCount: newCount,
                lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
            });
        } else {
            console.log(`[cancelReservation] SessionReservation not found. sessionId=${sessionId}, date=${reservedDateString} (skip decrement)`);
        }

        // reservation delete
        console.log(`[cancelReservation] Deleting reservation: ${reservationId}`);
        tx.delete(reservationRef);
        logFunctionSuccess(functionName, { reservationId, courseId, reservedDateString, callerId, reservationUserId, isAdminForThisPlace });

        return { success: true };
    }).then(async (result) => {
        // 트랜잭션 성공 후 알림 전송 (트랜잭션 외부에서)
        try {
            const place = await getPlaceOrThrow(placeId);
            const courseName = getCourseName(place, courseId);
            const notificationBody = `${courseName} - ${reservedDateString} ${startTime}`;
            await createNotification({
                userId: reservationUserId,
                type: 'reservation',
                title: `${courseName} 예약이 취소되었습니다`,
                body: notificationBody,
                placeId,
                data: {
                    reservationId,
                    courseId,
                    placeId,
                },
                isAdmin: false,
            });
        } catch (error) {
            console.error(`[cancelReservation] Error creating notification:`, error);
            // 알림 실패해도 예약 취소는 성공한 것으로 처리
        }
        return result;
    }).catch((error) => {
        logFunctionError(functionName, error, { callerId, reservationId, placeId, isAdminForThisPlace });

        // 이미 HttpsError인 경우 그대로 throw
        if (error instanceof functions.https.HttpsError) {
            throw error;
        }

        // 일반 Error인 경우 INTERNAL 에러로 변환 (에러 메시지 포함)
        const errorMessage = error instanceof Error ? error.message : String(error);
        const errorStack = error instanceof Error ? error.stack : undefined;
        console.error(`[cancelReservation] Unexpected error:`, errorMessage, errorStack);

        throw new functions.https.HttpsError(
            'internal',
            `예약 취소 중 오류가 발생했습니다: ${errorMessage}`,
            { originalError: errorMessage, stack: errorStack }
        );
    });
});

/**
 * (자동 복구) 과거 phone_{010...} 형태의 "가짜 userId"로 생성된 데이터가 있는 경우,
 * 현재 로그인한 UID로 enrollments/placeMemberships/courseMembers/reservations의 userId를 이관한다.
 *
 * - 클라이언트의 과거 버그로 인해 "전화번호 1개 = 유저 2개"가 되는 현상을 자동으로 치유.
 * - 호출자는 본인(로그인 UID)만 이관 가능 (phoneNumber 기반으로 legacy id를 계산).
 */
export const reconcileLegacyPhoneUser = functions.https.onCall(async (data, context) => {
    const functionName = 'reconcileLegacyPhoneUser';
    logFunctionStart(functionName, { userId: context.auth?.uid });

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const uid = context.auth.uid;
    const phoneNumberRaw = String(data?.phoneNumber ?? '');
    const phoneNumber = normalizePhoneNumber(phoneNumberRaw);
    if (!phoneNumber || phoneNumber.length < 10) {
        throw new functions.https.HttpsError('invalid-argument', 'phoneNumber가 필요합니다.');
    }

    const legacyUserId = `phone_${phoneNumber}`;
    if (legacyUserId === uid) {
        return { success: true, migrated: false, message: 'already canonical' };
    }

    const db = admin.firestore();

    const result = {
        success: true,
        migrated: false,
        legacyUserId,
        uid,
        moved: {
            enrollments: 0,
            courseMembers: 0,
            placeMembershipsUpdated: 0,
            placeMembershipsDeleted: 0,
            reservations: 0,
        },
    };

    // 1) users 문서 보장 (uid)
    const uidUserRef = db.collection('users').doc(uid);
    const uidUserDoc = await uidUserRef.get();
    if (!uidUserDoc.exists) {
        // 최소 필드만 생성 (클라이언트가 이후 상세를 채움)
        await uidUserRef.set({
            userId: uid,
            phoneNumber,
            placeIds: [],
            adminForPlaces: [],
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
    } else {
        // phoneNumber 누락 시 보강
        await uidUserRef.set({
            phoneNumber,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
    }

    // 2) enrollments userId 이관
    const enrollmentsSnap = await db.collection('enrollments').where('userId', '==', legacyUserId).get();
    if (!enrollmentsSnap.empty) {
        const batch = db.batch();
        enrollmentsSnap.docs.forEach((d) => {
            batch.update(d.ref, { userId: uid });
        });
        await batch.commit();
        result.moved.enrollments = enrollmentsSnap.size;
        result.migrated = true;
    }

    // 3) courseMembers userId 이관
    const cmSnap = await db.collection('courseMembers').where('userId', '==', legacyUserId).get();
    if (!cmSnap.empty) {
        const batch = db.batch();
        cmSnap.docs.forEach((d) => {
            batch.update(d.ref, { userId: uid });
        });
        await batch.commit();
        result.moved.courseMembers = cmSnap.size;
        result.migrated = true;
    }

    // 4) placeMemberships 이관 (동일 placeId가 uid에 이미 있으면 legacy는 삭제)
    const legacyMembershipsSnap = await db.collection('placeMemberships').where('userId', '==', legacyUserId).get();
    if (!legacyMembershipsSnap.empty) {
        // uid가 가진 placeId 목록
        const uidMembershipsSnap = await db.collection('placeMemberships').where('userId', '==', uid).get();
        const uidPlaceIds = new Set(uidMembershipsSnap.docs.map((d) => String((d.data() as any)?.placeId ?? '')));

        const batch = db.batch();
        legacyMembershipsSnap.docs.forEach((d) => {
            const placeId = String((d.data() as any)?.placeId ?? '');
            if (placeId && uidPlaceIds.has(placeId)) {
                batch.delete(d.ref);
                result.moved.placeMembershipsDeleted++;
            } else {
                batch.update(d.ref, { userId: uid });
                result.moved.placeMembershipsUpdated++;
            }
        });
        await batch.commit();
        result.migrated = true;
    }

    // 5) reservations(userId) 이관: collectionGroup로 전 플레이스 서브컬렉션 검색
    const reservationsSnap = await db.collectionGroup('reservations').where('userId', '==', legacyUserId).get();
    if (!reservationsSnap.empty) {
        // batch(500 제한) 분할
        let idx = 0;
        while (idx < reservationsSnap.docs.length) {
            const batch = db.batch();
            const slice = reservationsSnap.docs.slice(idx, idx + 450);
            slice.forEach((d) => batch.update(d.ref, { userId: uid }));
            await batch.commit();
            idx += slice.length;
            result.moved.reservations += slice.length;
        }
        result.migrated = true;
    }

    // 6) legacy users 문서 삭제 (있으면)
    const legacyUserRef = db.collection('users').doc(legacyUserId);
    const legacyUserDoc = await legacyUserRef.get();
    if (legacyUserDoc.exists) {
        await legacyUserRef.delete().catch(() => undefined);
        result.migrated = true;
    }

    logFunctionSuccess(functionName, result as any);
    return result;
});

/**
 * (마이그레이션) enrollments 문서 ID를 `${userId}_${placeId}_${courseId}` 형태로 정규화한다.
 *
 * 목적:
 * - createReservation/cancelReservation에서 "쿼리 없이" 고정 docRef로 빠르게 조회 가능하게 만들기
 * - 과거 자동 ID/다른 ID로 만들어진 enrollments를 정리
 *
 * 동작:
 * - userId는 호출자 UID로 고정(본인 데이터만)
 * - placeId는 인자로 받음(legacy 문서에 placeId가 없을 수 있어 필수)
 * - placeId가 없거나(placeId missing) placeId가 일치하는 enrollments만 대상으로 삼음
 * - 이미 고정 ID인 문서는 placeId 보정(merge)만 수행
 *
 * 주의:
 * - 문서 rename은 불가능하므로 "copy + delete"로 처리한다.
 */
export const normalizeEnrollmentDocIds = functions.https.onCall(async (data, context) => {
    const functionName = 'normalizeEnrollmentDocIds';
    logFunctionStart(functionName, { userId: context.auth?.uid, placeId: data?.placeId });

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const userId = context.auth.uid;
    const placeId = String(data?.placeId ?? '').trim();
    if (!placeId) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId가 필요합니다.');
    }

    const db = admin.firestore();

    // 본인 enrollments만 스캔(마이그레이션 작업이므로 쿼리 허용)
    const snap = await db.collection('enrollments').where('userId', '==', userId).get();
    let touched = 0;
    let created = 0;
    let deleted = 0;

    const batch = db.batch();

    for (const doc of snap.docs) {
        const e = doc.data() as any;
        const courseId = String(e?.courseId ?? '').trim();
        const docPlaceId = e?.placeId == null ? null : String(e.placeId).trim();
        if (!courseId) continue;

        // legacy 문서(placeId 없음)는 호출자가 지정한 placeId로 정규화
        if (docPlaceId != null && docPlaceId !== placeId) {
            continue;
        }

        const fixedId = `${userId}_${placeId}_${courseId}`;
        const fixedRef = db.collection('enrollments').doc(fixedId);

        touched++;

        if (doc.id === fixedId) {
            // 이미 고정 ID면 placeId 누락만 보정
            batch.set(fixedRef, { id: fixedId, placeId }, { merge: true });
            continue;
        }

        // copy + delete
        batch.set(
            fixedRef,
            {
                ...e,
                id: fixedId,
                userId,
                courseId,
                placeId,
                migratedFrom: doc.id,
                migratedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
        );
        batch.delete(doc.ref);
        created++;
        deleted++;
    }

    await batch.commit();
    logFunctionSuccess(functionName, { userId, placeId, touched, created, deleted });
    return { success: true, userId, placeId, touched, created, deleted };
});

/**
 * (관리자) enrollments 전체를 고정 ID(`${userId}_${placeId}_${courseId}`)로 마이그레이션 (폴백/런타임쿼리 제거용)
 *
 * - 페이지네이션 지원: startAfterDocId + batchSize
 * - 배치 커밋 제한(500 writes) 고려: 한 문서 이동은 (copy + delete) 2 writes
 * - placeId가 문서에 없으면 docId에서 place_/course_ 패턴으로 파싱 시도
 */
export const migrateEnrollmentsToFixedIds = functions.https.onCall(async (data, context) => {
    const functionName = 'migrateEnrollmentsToFixedIds';
    logFunctionStart(functionName, { userId: context.auth?.uid, data });

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    // 위험 작업: 관리자만 실행
    await assertAdminUid(context.auth.uid);

    const db = admin.firestore();
    const batchSizeRaw = Number(data?.batchSize ?? 200);
    const batchSize = Math.min(Math.max(1, batchSizeRaw), 250); // 250 docs * 2 writes = 500 writes
    const startAfterDocId = String(data?.startAfterDocId ?? '').trim();
    const dryRun = data?.dryRun === true;

    let q = db.collection('enrollments').orderBy(admin.firestore.FieldPath.documentId()).limit(batchSize);
    if (startAfterDocId) {
        q = q.startAfter(startAfterDocId);
    }

    const snap = await q.get();
    if (snap.empty) {
        return { success: true, done: true, processed: 0, migrated: 0, skipped: 0, nextStartAfterDocId: null };
    }

    const docs = snap.docs;
    const nextStartAfter = docs[docs.length - 1].id;

    const parseIdsFromDocId = (docId: string): { placeId?: string; courseId?: string } => {
        const m = docId.match(/_(place_[^_]+)_(course_[^_]+)$/);
        if (!m) return {};
        return { placeId: m[1], courseId: m[2] };
    };

    // fixedRef 존재 여부를 미리 읽어두기(덮어쓰기 방지)
    const toCheck: FirebaseFirestore.DocumentReference[] = [];
    const planned: Array<{
        src: FirebaseFirestore.QueryDocumentSnapshot;
        fixedId: string;
        fixedRef: FirebaseFirestore.DocumentReference;
        alreadyFixed: boolean;
    }> = [];

    let skipped = 0;
    for (const doc of docs) {
        const e = doc.data() as any;
        const userId = String(e?.userId ?? '').trim();
        let placeId = e?.placeId == null ? '' : String(e.placeId).trim();
        let courseId = String(e?.courseId ?? '').trim();

        if (!placeId || !courseId) {
            const parsed = parseIdsFromDocId(doc.id);
            placeId = placeId || String(parsed.placeId ?? '').trim();
            courseId = courseId || String(parsed.courseId ?? '').trim();
        }

        if (!userId || !placeId || !courseId) {
            skipped++;
            continue;
        }

        const fixedId = `${userId}_${placeId}_${courseId}`;
        const fixedRef = db.collection('enrollments').doc(fixedId);
        const alreadyFixed = doc.id === fixedId;
        planned.push({ src: doc, fixedId, fixedRef, alreadyFixed });
        if (!alreadyFixed) toCheck.push(fixedRef);
    }

    const fixedDocs = toCheck.length > 0 ? await db.getAll(...toCheck) : [];
    const fixedExists = new Map<string, boolean>();
    for (const d of fixedDocs) fixedExists.set(d.ref.path, d.exists);

    let migrated = 0;
    if (!dryRun) {
        const batch = db.batch();
        for (const p of planned) {
            const e = p.src.data() as any;
            if (p.alreadyFixed) {
                // 필드 보정만(필수 필드)
                batch.set(
                    p.fixedRef,
                    { id: p.fixedId, userId: String(e.userId), placeId: String(e.placeId ?? p.fixedId.split('_')[1]), courseId: String(e.courseId) },
                    { merge: true },
                );
                continue;
            }

            const exists = fixedExists.get(p.fixedRef.path) === true;
            if (!exists) {
                // full copy (최초 생성)
                batch.set(
                    p.fixedRef,
                    {
                        ...e,
                        id: p.fixedId,
                        userId: String(e.userId),
                        placeId: String(e.placeId ?? p.fixedId.split('_')[1]),
                        courseId: String(e.courseId),
                        migratedFrom: p.src.id,
                        migratedAt: admin.firestore.FieldValue.serverTimestamp(),
                    },
                    { merge: true },
                );
            } else {
                // 이미 canonical이 존재하면 카운터를 덮어쓰지 않도록 최소 필드만 보정
                batch.set(
                    p.fixedRef,
                    {
                        id: p.fixedId,
                        userId: String(e.userId),
                        placeId: String(e.placeId ?? p.fixedId.split('_')[1]),
                        courseId: String(e.courseId),
                        migratedFrom: admin.firestore.FieldValue.arrayUnion(p.src.id),
                        migratedAt: admin.firestore.FieldValue.serverTimestamp(),
                    },
                    { merge: true },
                );
            }
            batch.delete(p.src.ref);
            migrated++;
        }
        await batch.commit();
    } else {
        migrated = planned.filter((p) => !p.alreadyFixed).length;
    }

    const processed = docs.length;
    const done = docs.length < batchSize;
    logFunctionSuccess(functionName, { processed, migrated, skipped, nextStartAfterDocId: done ? null : nextStartAfter, dryRun });
    return {
        success: true,
        done,
        processed,
        migrated,
        skipped,
        nextStartAfterDocId: done ? null : nextStartAfter,
        dryRun,
    };
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

    const toCancel = cancellable;
    if (toCancel.length > 450) {
        // 트랜잭션 write 한도 방지 (예약 1건당 최소 2 write: reservation delete + sr decrement)
        throw new functions.https.HttpsError(
            'resource-exhausted',
            '취소할 예약이 너무 많아 한 번에 처리할 수 없습니다.',
            { reservationCount: toCancel.length },
        );
    }

    // ✅ 최적화: 고정ID 패턴 사용 (쿼리 대신 직접 참조)
    const enrollmentId = `${targetUserId}_${placeId}_${courseId}`;
    const enrollmentRef = db.collection('enrollments').doc(enrollmentId);

    // 트랜잭션: 예약 삭제 + sessionReservations decrement + enrollment 삭제
    // ✅ Firestore 트랜잭션 규칙: 모든 read가 write보다 먼저 수행되어야 함.
    await db.runTransaction(async (tx) => {
        // 1) enrollment 조회(선행 read) - 고정ID 패턴 사용
        const enrollmentDoc = await tx.get(enrollmentRef);
        if (!enrollmentDoc.exists) {
            throw new functions.https.HttpsError('failed-precondition', '등록 정보를 찾을 수 없습니다.');
        }

        // 2) 모든 sessionReservations 조회(선행 read)
        const srRefs: Array<{ ref: FirebaseFirestore.DocumentReference; doc: FirebaseFirestore.DocumentSnapshot }> = [];
        for (const doc of toCancel) {
            const r = doc.data() as any;
            const dayOfWeek = Number(r?.dayOfWeek ?? 0);
            const startTime = String(r?.startTime ?? '');
            const reservedDateString = String(r?.reservedDateString ?? '');
            if (!startTime || !reservedDateString || !Number.isFinite(dayOfWeek)) continue;

            const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
            const srRef = db.collection('sessionReservations').doc(`${sessionId}_${reservedDateString}`);
            const srDoc = await tx.get(srRef);
            srRefs.push({ ref: srRef, doc: srDoc });
        }

        // 3) 예약 취소 처리(write)
        for (let i = 0; i < toCancel.length; i++) {
            const doc = toCancel[i];
            const sr = srRefs[i];
            if (!sr) continue;

            if (sr.doc.exists) {
                tx.update(sr.ref, {
                    reservedCount: admin.firestore.FieldValue.increment(-1),
                    lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                });
            }

            tx.delete(doc.ref);
        }

        // 4) enrollment 문서 삭제 (관계 완전 제거)
        tx.delete(enrollmentRef);
    });

    // enrollments 하위 서브컬렉션 정리 (문서 삭제 후에도 서브컬렉션은 남을 수 있음)
    await Promise.all([
        deleteCollectionByPath(db, `enrollments/${enrollmentId}/reenrollmentHistory`),
        deleteCollectionByPath(db, `enrollments/${enrollmentId}/adminActions`),
        deleteCollectionByPath(db, `enrollments/${enrollmentId}/extensionRequests`),
    ]);

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
 * 회원 탈퇴/추방 (관리자)
 *
 * 정책:
 * - 코스 수강취소: enrollments만 삭제 (placeMembership 유지) => cancelEnrollment 사용
 * - 회원탈퇴(플레이스에서 제거): placeMembership 삭제 + 해당 place의 모든 enrollments 삭제
 *
 * 주의:
 * - enrollments 삭제는 onEnrollmentDeleted 트리거를 통해 courseMembers 정리됨
 * - enrollments 하위 서브컬렉션은 별도로 삭제해야 함
 */
export const removeMemberFromPlace = functions.https.onCall(async (data, context) => {
    const functionName = 'removeMemberFromPlace';
    logFunctionStart(functionName, { userId: context.auth?.uid, ...data });

    const placeId = String(data?.placeId ?? '');
    const targetUserId = String(data?.userId ?? '');
    const phoneNumber = String(data?.phoneNumber ?? ''); // optional (pendingMembers 정리용)
    const adminUserId = String(data?.adminUserId ?? ''); // 관리자 userId (Firebase Auth 미사용 시)

    if (!placeId || !targetUserId) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId, userId가 필요합니다.');
    }

    // 관리자 권한 확인 (Firebase Auth 또는 adminUserId 사용)
    let callerId: string;
    if (context.auth?.uid) {
        // Firebase Auth로 로그인한 경우
        callerId = context.auth.uid;
        await assertAdminForPlaceUid(callerId, placeId);
    } else if (adminUserId) {
        // 관리자가 Firebase Auth 없이 로그인한 경우 (PIN 인증)
        callerId = adminUserId;
        await assertAdminForPlaceUid(callerId, placeId);
    } else {
        logFunctionError(functionName, new Error('Unauthenticated'), { data });
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const db = admin.firestore();

    // 1) placeMemberships 삭제 (과거 랜덤 docId 중복 가능 → query로 모두 삭제)
    const membershipSnap = await db
        .collection('placeMemberships')
        .where('userId', '==', targetUserId)
        .where('placeId', '==', placeId)
        .get();

    let deletedMemberships = 0;
    if (!membershipSnap.empty) {
        const batch = db.batch();
        membershipSnap.docs.forEach((doc) => {
            batch.delete(doc.ref);
            deletedMemberships++;
        });
        await batch.commit();
    }

    // 2) enrollments 삭제 (place 단위로 전부)
    const enrollSnap = await db
        .collection('enrollments')
        .where('userId', '==', targetUserId)
        .where('placeId', '==', placeId)
        .get();

    const enrollmentIds: string[] = [];
    let deletedEnrollments = 0;
    if (!enrollSnap.empty) {
        // 최대 500건 제한 고려 (단순 split)
        const docs = enrollSnap.docs;
        for (let i = 0; i < docs.length; i += 450) {
            const chunk = docs.slice(i, i + 450);
            const batch = db.batch();
            chunk.forEach((doc) => {
                enrollmentIds.push(doc.id);
                batch.delete(doc.ref);
                deletedEnrollments++;
            });
            await batch.commit();
        }
    }

    // 2-1) enrollments 하위 서브컬렉션 정리
    await Promise.all(
        enrollmentIds.flatMap((enrollmentId) => ([
            deleteCollectionByPath(db, `enrollments/${enrollmentId}/reenrollmentHistory`),
            deleteCollectionByPath(db, `enrollments/${enrollmentId}/adminActions`),
            deleteCollectionByPath(db, `enrollments/${enrollmentId}/extensionRequests`),
        ])),
    );

    // 3) pendingMembers 정리(선택)
    let deletedPending = false;
    if (phoneNumber) {
        const pendingId = `${placeId}_${phoneNumber}`;
        try {
            const ref = db.collection('pendingMembers').doc(pendingId);
            const doc = await ref.get();
            if (doc.exists) {
                await ref.delete();
                deletedPending = true;
            }
        } catch (e) {
            console.warn('[removeMemberFromPlace] pendingMembers delete failed (ignore)', { placeId, phoneNumber, e });
        }
    }

    logFunctionSuccess(functionName, {
        callerId,
        placeId,
        targetUserId,
        deletedMemberships,
        deletedEnrollments,
        deletedPending,
    });

    return {
        success: true,
        deletedMemberships,
        deletedEnrollments,
        deletedPending,
    };
});

/**
 * 유저 계정 삭제 (본인 탈퇴)
 *
 * 정책:
 * - 본인만 호출 가능 (callerId == targetUserId)
 * - 모든 플레이스에서 제거:
 *   - placeMemberships 삭제
 *   - enrollments 삭제 (하위 서브컬렉션 포함)
 *   - reservations 삭제 (모든 플레이스)
 *   - pendingMembers 삭제
 * - courseMembers는 onEnrollmentDeleted 트리거로 자동 삭제됨
 * - Firebase Auth 계정 삭제
 * - users 문서 삭제
 */
export const deleteUserAccount = functions.https.onCall(async (data, context) => {
    const functionName = 'deleteUserAccount';
    logFunctionStart(functionName, { userId: context.auth?.uid });

    if (!context.auth?.uid) {
        logFunctionError(functionName, new Error('Unauthenticated'), { data });
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const callerId = context.auth.uid;
    const targetUserId = String(data?.userId ?? callerId); // 기본값: 호출자 본인

    // 본인만 삭제 가능
    if (callerId !== targetUserId) {
        logFunctionError(functionName, new Error('Forbidden'), { callerId, targetUserId });
        throw new functions.https.HttpsError('permission-denied', '본인의 계정만 삭제할 수 있습니다.');
    }

    const db = admin.firestore();
    const results = {
        deletedMemberships: 0,
        deletedEnrollments: 0,
        deletedPending: 0,
    };

    try {
        // 1) 모든 placeMemberships 조회
        const membershipSnap = await db
            .collection('placeMemberships')
            .where('userId', '==', targetUserId)
            .get();

        const placeIds = new Set<string>();
        if (!membershipSnap.empty) {
            // placeId 수집
            membershipSnap.docs.forEach((doc) => {
                const placeId = String((doc.data() as any)?.placeId ?? '');
                if (placeId) placeIds.add(placeId);
            });

            // placeMemberships 삭제
            const batch = db.batch();
            membershipSnap.docs.forEach((doc) => {
                batch.delete(doc.ref);
                results.deletedMemberships++;
            });
            await batch.commit();
        }

        // 2) 모든 enrollments 삭제 (모든 플레이스)
        const enrollSnap = await db
            .collection('enrollments')
            .where('userId', '==', targetUserId)
            .get();

        const enrollmentIds: string[] = [];
        if (!enrollSnap.empty) {
            const docs = enrollSnap.docs;
            for (let i = 0; i < docs.length; i += 450) {
                const chunk = docs.slice(i, i + 450);
                const batch = db.batch();
                chunk.forEach((doc) => {
                    enrollmentIds.push(doc.id);
                    batch.delete(doc.ref);
                    results.deletedEnrollments++;
                });
                await batch.commit();
            }

            // enrollments 하위 서브컬렉션 정리
            await Promise.all(
                enrollmentIds.flatMap((enrollmentId) => ([
                    deleteCollectionByPath(db, `enrollments/${enrollmentId}/reenrollmentHistory`),
                    deleteCollectionByPath(db, `enrollments/${enrollmentId}/adminActions`),
                    deleteCollectionByPath(db, `enrollments/${enrollmentId}/extensionRequests`),
                ])),
            );
        }

        // 3) reservations는 삭제하지 않음 (히스토리 보존)

        // 4) pendingMembers 삭제 (모든 플레이스)
        if (placeIds.size > 0) {
            // phoneNumber 가져오기 (users 문서에서)
            let phoneNumber = '';
            try {
                const userDoc = await db.collection('users').doc(targetUserId).get();
                if (userDoc.exists) {
                    phoneNumber = String((userDoc.data() as any)?.phoneNumber ?? '');
                    // 숫자만 추출
                    phoneNumber = phoneNumber.replace(/[^\d]/g, '');
                }
            } catch (e) {
                console.warn('[deleteUserAccount] Failed to get phoneNumber:', e);
            }

            if (phoneNumber) {
                for (const placeId of placeIds) {
                    try {
                        const pendingId = `${placeId}_${phoneNumber}`;
                        const pendingRef = db.collection('pendingMembers').doc(pendingId);
                        const pendingDoc = await pendingRef.get();
                        if (pendingDoc.exists) {
                            await pendingRef.delete();
                            results.deletedPending++;
                        }
                    } catch (e) {
                        console.warn(`[deleteUserAccount] Failed to delete pendingMember for place ${placeId}:`, e);
                    }
                }
            }
        }

        // 5) users 문서 삭제
        try {
            await db.collection('users').doc(targetUserId).delete();
        } catch (e) {
            console.warn('[deleteUserAccount] Failed to delete users document:', e);
        }

        // 6) Firebase Auth 계정 삭제
        try {
            await admin.auth().deleteUser(targetUserId);
        } catch (e) {
            console.warn('[deleteUserAccount] Failed to delete Firebase Auth account:', e);
            // Auth 계정 삭제 실패해도 계속 진행 (이미 삭제되었을 수 있음)
        }

        logFunctionSuccess(functionName, {
            callerId,
            targetUserId,
            ...results,
        });

        return {
            success: true,
            ...results,
        };
    } catch (error) {
        logFunctionError(functionName, error as Error, { callerId, targetUserId });
        throw error;
    }
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
    console.log(`[${functionName}] 시작 - callerId: ${context.auth?.uid}, placeId: ${data?.placeId}, courseId: ${data?.courseId}, sessionsCount: ${Array.isArray(data?.sessions) ? data.sessions.length : 0}`);
    logFunctionStart(functionName, { userId: context.auth?.uid, ...data });

    try {
        if (!context.auth?.uid) {
            console.error(`[${functionName}] 인증 실패 - uid 없음`);
            throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
        }

        const callerId = context.auth.uid;
        const placeId = String(data?.placeId ?? '');
        const courseId = String(data?.courseId ?? '');
        const sessions = Array.isArray(data?.sessions) ? data.sessions : [];

        console.log(`[${functionName}] 파라미터 검증 - placeId: ${placeId}, courseId: ${courseId}, sessions: ${sessions.length}개`);

        if (!placeId || !courseId) {
            console.error(`[${functionName}] 파라미터 누락 - placeId: ${placeId}, courseId: ${courseId}`);
            throw new functions.https.HttpsError('invalid-argument', 'placeId와 courseId가 필요합니다.');
        }

        console.log(`[${functionName}] 관리자 권한 확인 시작 - callerId: ${callerId}, placeId: ${placeId}`);
        await assertAdminForPlaceUid(callerId, placeId);
        console.log(`[${functionName}] 관리자 권한 확인 완료`);

        const db = admin.firestore();
        const now = getSeoulDateTime();
        const todayString = `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`;
        console.log(`[${functionName}] 현재 날짜: ${todayString}`);

        // place + course 조회 (코스명 그대로 사용)
        console.log(`[${functionName}] place 조회 시작 - placeId: ${placeId}`);
        const place = await getPlaceOrThrow(placeId);
        const courseName = getCourseName(place, courseId);
        console.log(`[${functionName}] place 조회 완료 - courseName: ${courseName}`);

        // 기존 세션 맵(키: day_start)
        console.log(`[${functionName}] 기존 세션 조회 시작 - courseId: ${courseId}`);
        const course = findCourse(place, courseId);
        if (!course) {
            console.error(`[${functionName}] 코스를 찾을 수 없음 - placeId: ${placeId}, courseId: ${courseId}`);
            throw new functions.https.HttpsError('not-found', '코스를 찾을 수 없습니다.');
        }
        const oldSessions = Array.isArray(course.sessions) ? course.sessions : [];
        console.log(`[${functionName}] 기존 세션 개수: ${oldSessions.length}`);
        const oldMap = new Map<string, any>();
        for (const s of oldSessions) {
            const d = Number((s as any)?.dayOfWeek ?? 0);
            const st = String((s as any)?.startTime ?? '');
            if (!Number.isFinite(d) || !st) continue;
            oldMap.set(`${d}_${st}`, s);
        }
        console.log(`[${functionName}] 기존 세션 맵 크기: ${oldMap.size}`);

        // 신규 세션 맵
        console.log(`[${functionName}] 신규 세션 검증 시작 - sessions: ${sessions.length}개`);
        const newMap = new Map<string, any>();
        for (let i = 0; i < sessions.length; i++) {
            const s = sessions[i];
            const d = Number((s as any)?.dayOfWeek ?? 0);
            const st = String((s as any)?.startTime ?? '');
            const et = String((s as any)?.endTime ?? '');
            const cap = Number((s as any)?.capacity ?? 0);
            console.log(`[${functionName}] 세션 ${i + 1}/${sessions.length} 검증 - dayOfWeek: ${d}, startTime: ${st}, endTime: ${et}, capacity: ${cap}`);
            if (!Number.isFinite(d) || d < 1 || d > 7 || !st || !et || !Number.isFinite(cap) || cap <= 0) {
                console.error(`[${functionName}] 세션 데이터 유효하지 않음 - dayOfWeek: ${d}, startTime: ${st}, endTime: ${et}, capacity: ${cap}`);
                throw new functions.https.HttpsError('invalid-argument', 'sessions 데이터가 올바르지 않습니다.');
            }
            // 간단한 시간 형식 검증 (parseHHmm은 invalid-argument로 던짐)
            try {
                parseHHmm(st);
                parseHHmm(et);
            } catch (e) {
                console.error(`[${functionName}] 시간 형식 검증 실패 - startTime: ${st}, endTime: ${et}, error: ${e}`);
                throw e;
            }
            newMap.set(`${d}_${st}`, { dayOfWeek: d, startTime: st, endTime: et, capacity: cap });
        }
        console.log(`[${functionName}] 신규 세션 맵 크기: ${newMap.size}`);

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
        console.log(`[${functionName}] 삭제/변경 세션 확인 시작`);
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
        console.log(`[${functionName}] 삭제된 세션: ${removedKeys.length}개, 변경된 세션: ${modifiedKeys.length}개`);

        async function hasFutureReservationsForSessionKey(key: string): Promise<boolean> {
            const [dStr, st] = key.split('_');
            const d = Number(dStr);
            const sid = `${courseId}_${d}_${st}`;
            console.log(`[${functionName}] 미래 예약 확인 - sessionId: ${sid}, date: >= ${todayString}`);
            const q = db
                .collection('sessionReservations')
                .where('sessionId', '==', sid)
                .where('reservedCount', '>', 0)
                .where('date', '>=', todayString)
                .limit(1);
            const snap = await q.get();
            const hasReservations = !snap.empty;
            console.log(`[${functionName}] 미래 예약 확인 결과 - sessionId: ${sid}, hasReservations: ${hasReservations}`);
            return hasReservations;
        }

        console.log(`[${functionName}] 삭제된 세션 미래 예약 확인 시작`);
        for (const key of removedKeys) {
            if (await hasFutureReservationsForSessionKey(key)) {
                const [dStr, st] = key.split('_');
                console.error(`[${functionName}] 삭제 불가 - 미래 예약 존재 - key: ${key}, dayOfWeek: ${dStr}, startTime: ${st}`);
                throwRequiresBulkMove({
                    courseId,
                    courseName,
                    dayOfWeek: Number(dStr),
                    startTime: st,
                    operation: 'delete',
                });
            }
        }
        console.log(`[${functionName}] 변경된 세션 미래 예약 확인 시작`);
        for (const key of modifiedKeys) {
            if (await hasFutureReservationsForSessionKey(key)) {
                const [dStr, st] = key.split('_');
                console.error(`[${functionName}] 변경 불가 - 미래 예약 존재 - key: ${key}, dayOfWeek: ${dStr}, startTime: ${st}`);
                throwRequiresBulkMove({
                    courseId,
                    courseName,
                    dayOfWeek: Number(dStr),
                    startTime: st,
                    operation: 'modify',
                });
            }
        }
        console.log(`[${functionName}] 미래 예약 확인 완료 - 모든 세션 저장 가능`);

        // place courses 업데이트 (sessions만 교체)
        console.log(`[${functionName}] 트랜잭션 시작 - placeId: ${placeId}, courseId: ${courseId}`);
        const placeRef = db.collection('places').doc(placeId);
        await db.runTransaction(async (tx) => {
            console.log(`[${functionName}] 트랜잭션 내부 - place 문서 조회 시작`);
            const placeDoc = await tx.get(placeRef);
            if (!placeDoc.exists) {
                console.error(`[${functionName}] 트랜잭션 내부 - place 문서 없음 - placeId: ${placeId}`);
                throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
            }
            const placeData = placeDoc.data() as any;
            const courses = Array.isArray(placeData?.courses) ? placeData.courses : [];
            console.log(`[${functionName}] 트랜잭션 내부 - courses 개수: ${courses.length}`);
            let found = false;
            const updatedCourses = courses.map((c: any) => {
                if (String(c?.id ?? '') !== courseId) return c;
                found = true;
                console.log(`[${functionName}] 트랜잭션 내부 - 코스 찾음, 세션 업데이트 - courseId: ${courseId}, 새 세션 개수: ${newMap.size}`);
                return {
                    ...c,
                    sessions: Array.from(newMap.values()),
                };
            });
            if (!found) {
                console.error(`[${functionName}] 트랜잭션 내부 - 코스를 찾을 수 없음 - courseId: ${courseId}, courses 개수: ${courses.length}`);
                throw new functions.https.HttpsError('not-found', '코스를 찾을 수 없습니다.');
            }
            console.log(`[${functionName}] 트랜잭션 내부 - place 문서 업데이트 시작`);
            tx.update(placeRef, { courses: updatedCourses });
            console.log(`[${functionName}] 트랜잭션 내부 - place 문서 업데이트 완료`);
        });
        console.log(`[${functionName}] 트랜잭션 완료`);

        logFunctionSuccess(functionName, { callerId, placeId, courseId, removed: removedKeys.length, modified: modifiedKeys.length });
        console.log(`[${functionName}] 성공 - removed: ${removedKeys.length}, modified: ${modifiedKeys.length}`);
        return { success: true, courseName };
    } catch (error: any) {
        console.error(`[${functionName}] 에러 발생:`, error);
        console.error(`[${functionName}] 에러 스택:`, error.stack);
        console.error(`[${functionName}] 에러 메시지:`, error.message);
        console.error(`[${functionName}] 에러 코드:`, error.code);
        logFunctionError(functionName, error, { placeId: data?.placeId, courseId: data?.courseId });
        // 이미 HttpsError면 그대로 던지기
        if (error instanceof functions.https.HttpsError) {
            throw error;
        }
        // 그 외의 에러는 INTERNAL로 변환
        throw new functions.https.HttpsError('internal', `요일 편집 저장 중 오류가 발생했습니다: ${error.message || error.toString()}`, { originalError: error.toString(), stack: error.stack });
    }
});

/**
 * 플레이스 삭제 (관리자)
 *
 * 클라이언트에서 대량 삭제를 수행하면 rules/권한/속도 문제로 쉽게 깨지므로
 * 서버에서만 수행하도록 중앙화합니다.
 *
 * 정책:
 * - 미래 예약이 하나라도 있으면 삭제 불가(먼저 예약/세션 정리 필요)
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
    const now = getSeoulDateTime();
    const todayString = `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`;

    // 활성(미래) 예약이 있으면 삭제 불가
    const activeSnap = await db
        .collection('places')
        .doc(placeId)
        .collection('reservations')
        .where('reservedDateString', '>=', todayString)
        .limit(1)
        .get();
    if (!activeSnap.empty) {
        throw new functions.https.HttpsError(
            'failed-precondition',
            '활성 예약이 있는 플레이스는 삭제할 수 없습니다. 먼저 예약을 취소해주세요.',
            { hasActiveReservations: true },
        );
    }

    // place 존재 확인(없으면 not-found)
    await getPlaceOrThrow(placeId);

    // 하위/관련 데이터 정리
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
    });
    return { success: true };
});

export const moveReservationWithinCourse = functions.https.onCall(async (data, context) => {
    const functionName = 'moveReservationWithinCourse';
    logFunctionStart(functionName, { userId: context.auth?.uid, reservationId: data?.reservationId, ...data });

    if (!context.auth?.uid) {
        logFunctionError(functionName, new Error('Unauthenticated'), { data });
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    await assertAdminUid(context.auth.uid);

    const reservationId = String(data?.reservationId ?? '');
    const placeId = String(data?.placeId ?? '');
    const newDayOfWeek = Number(data?.newDayOfWeek ?? 0);
    const newStartTime = String(data?.newStartTime ?? '');
    const newReservedDateString = String(data?.newReservedDateString ?? '');

    if (!reservationId || !placeId || !newStartTime || !newReservedDateString || !Number.isFinite(newDayOfWeek)) {
        logFunctionError(functionName, new Error('Invalid arguments'), { reservationId, placeId, newDayOfWeek, newStartTime, newReservedDateString });
        throw new functions.https.HttpsError('invalid-argument', 'reservationId, placeId, newDayOfWeek, newStartTime, newReservedDateString이 필요합니다.');
    }
    parseYYYYMMDD(newReservedDateString); // validate

    const db = admin.firestore();
    const now = getSeoulDateTime();
    const todayString = `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`;
    if (seoulDateOnly(newReservedDateString).getTime() < seoulDateOnly(todayString).getTime()) {
        throw new functions.https.HttpsError('failed-precondition', '과거 날짜로는 이동할 수 없습니다.');
    }

    return await db.runTransaction(async (tx) => {
        // 플레이스 서브컬렉션에서 예약 조회
        const reservationRef = db
            .collection('places')
            .doc(placeId)
            .collection('reservations')
            .doc(reservationId);
        const reservationDoc = await tx.get(reservationRef);
        if (!reservationDoc.exists) {
            throw new functions.https.HttpsError('not-found', '예약을 찾을 수 없습니다.');
        }

        const reservation = reservationDoc.data() as any;
        const courseId = String(reservation?.courseId ?? '');
        const userId = String(reservation?.userId ?? '');
        const oldDayOfWeek = Number(reservation?.dayOfWeek ?? 0);
        const oldStartTime = String(reservation?.startTime ?? '');
        const oldReservedDateString = String(reservation?.reservedDateString ?? '');

        if (!courseId || !placeId || !userId || !oldStartTime || !oldReservedDateString) {
            throw new functions.https.HttpsError('failed-precondition', '예약 데이터가 올바르지 않습니다.');
        }

        // 정책 로드 (active/scheduled/effectiveFrom)
        const policyRef = db.collection('coursePolicies').doc(courseId);
        const policyDoc = await tx.get(policyRef);
        const policyData = policyDoc.exists ? (policyDoc.data() as CoursePolicyDoc) : null;
        const policy = selectEffectivePolicy(now, policyData, { courseId, placeId });

        const oldSessionId = `${courseId}_${oldDayOfWeek}_${oldStartTime}`;
        const newSessionId = `${courseId}_${newDayOfWeek}_${newStartTime}`;
        if (oldSessionId === newSessionId && oldReservedDateString === newReservedDateString) {
            return { success: true };
        }

        const oldSrRef = db.collection('sessionReservations').doc(`${oldSessionId}_${oldReservedDateString}`);
        const newSrRef = db.collection('sessionReservations').doc(`${newSessionId}_${newReservedDateString}`);

        // ✅ 트랜잭션 규칙(read-before-write) 준수: 필요한 문서들은 먼저 모두 읽는다.
        const oldSrDoc = await tx.get(oldSrRef);
        const newSrDoc = await tx.get(newSrRef);

        // capacity(override 우선) + full 체크
        // ✅ 최적화: newSrDoc에 capacity가 있으면 place/override 읽기 생략(대부분의 케이스)
        const currentNewCount = newSrDoc.exists ? Number(newSrDoc.data()?.reservedCount ?? 0) : 0;
        const capacityFromSr = newSrDoc.exists ? Number(newSrDoc.data()?.capacity ?? 0) : 0;
        let capacity = Number.isFinite(capacityFromSr) && capacityFromSr > 0 ? capacityFromSr : 0;

        if (!(Number.isFinite(capacity) && capacity > 0)) {
            // 1) place에서 session capacity 확인 (newSrDoc가 없거나 capacity가 없는 경우에만)
            const placeDoc = await tx.get(db.collection('places').doc(placeId));
            if (!placeDoc.exists) {
                throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
            }
            const place = placeDoc.data()!;
            const course = findCourse(place, courseId);
            if (!course) throw new functions.https.HttpsError('not-found', '코스를 찾을 수 없습니다.');
            const session = findSession(course, newDayOfWeek, newStartTime);
            if (!session) throw new functions.https.HttpsError('not-found', '세션을 찾을 수 없습니다.');

            // 고정ID 패턴: ${sessionId}_${date}
            const overrideId = `${newSessionId}_${newReservedDateString}`;
            const overrideRef = db.collection('dateCapacityOverrides').doc(overrideId);
            const overrideDoc = await tx.get(overrideRef);
            const overrideCap = overrideDoc.exists
                ? Number(((overrideDoc.data() as any)?.capacity ?? 0) as any)
                : undefined;
            capacity = Number.isFinite(overrideCap) ? (overrideCap as number) : Number(session.capacity ?? 0);
        }

        if (currentNewCount >= capacity) {
            throw new functions.https.HttpsError('resource-exhausted', '이동할 세션의 예약 가능한 인원이 없습니다.');
        }

        // 정책 적용: allowAdminForceMoveWithinCourse가 OFF면 오픈/마감 정책도 강제
        if (!policy.allowAdminForceMoveWithinCourse) {
            const eligibility = evaluateReservation({
                now,
                policy,
                sessionDateString: newReservedDateString,
                startTime: newStartTime,
                capacity,
                reservedCount: currentNewCount,
                enrollmentCanReserve: true, // 이동은 크레딧/유효기간에 영향 없음
            });
            if (!eligibility.canReserve) {
                switch (eligibility.reason) {
                    case ReservationLockReason.notOpenedYet: {
                        const openAt = eligibility.openAt;
                        const openAtText = openAt ? openAt.toISOString() : '';
                        throw new functions.https.HttpsError(
                            'failed-precondition',
                            `아직 예약 오픈 전입니다.${openAtText ? ` (openAt: ${openAtText})` : ''}`,
                        );
                    }
                    case ReservationLockReason.closedBeforeStart:
                        throw new functions.https.HttpsError('failed-precondition', '세션 시작 임박으로 이동할 수 없습니다.');
                    case ReservationLockReason.pastDate:
                        throw new functions.https.HttpsError('failed-precondition', '과거 날짜로는 이동할 수 없습니다.');
                    case ReservationLockReason.full:
                        throw new functions.https.HttpsError('resource-exhausted', '이동할 세션의 예약 가능한 인원이 없습니다.');
                    default:
                        throw new functions.https.HttpsError('failed-precondition', '정책상 이동할 수 없습니다.');
                }
            }
        }

        // reservation 업데이트
        tx.update(reservationRef, {
            dayOfWeek: newDayOfWeek,
            startTime: newStartTime,
            reservedDateString: newReservedDateString,
            reservedDate: admin.firestore.Timestamp.fromDate(seoulDateOnly(newReservedDateString)),
        });

        // old-- / new++
        if (oldSrDoc.exists) {
            const currentOld = Number(oldSrDoc.data()?.reservedCount ?? 0);
            tx.update(oldSrRef, {
                reservedCount: Math.max(0, currentOld - 1),
                lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
            });
        } else {
            // old sessionReservations가 존재하지 않는 경우
            // 예약은 존재하지만 sessionReservations가 없는 데이터 불일치 상황
            // 이 경우에도 예약 이동은 진행하되, old sessionReservations는 건드리지 않음
            // (예약 이동 자체는 성공하지만, old sessionReservations의 reservedCount는 감소하지 않음)
            // 향후 데이터 정합성 검사에서 발견 가능
            logWarn('Old sessionReservation not found during move', {
                oldSessionId,
                oldReservedDateString,
                reservationId,
                message: '예약 이동은 진행되지만 old sessionReservations는 업데이트되지 않습니다.'
            });
        }
        if (newSrDoc.exists) {
            tx.update(newSrRef, {
                reservedCount: currentNewCount + 1,
                lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
            });
        } else {
            tx.set(newSrRef, {
                sessionId: newSessionId,
                courseId,
                placeId,
                dayOfWeek: newDayOfWeek,
                startTime: newStartTime,
                date: newReservedDateString,
                capacity,
                reservedCount: 1,
                lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }

        logFunctionSuccess(functionName, { reservationId, oldSessionId, newSessionId, oldReservedDateString, newReservedDateString });
        return {
            success: true,
            userId,
            courseId,
            placeId,
            oldReservedDateString,
            oldStartTime,
            newReservedDateString,
            newStartTime,
        };
    }).catch((error) => {
        logFunctionError(functionName, error, { reservationId, newDayOfWeek, newStartTime, newReservedDateString });
        throw error;
    }).then(async (result) => {
        // 트랜잭션 완료 후 알림 생성 (트랜잭션 밖에서 실행)
        if (result?.success && result?.userId) {
            try {
                // courseName은 트랜잭션 밖에서 조회(트랜잭션 read 최소화 + place 문서가 클 수 있음)
                let courseName = '코스';
                try {
                    const place = await getPlaceOrThrow(result.placeId);
                    courseName = getCourseName(place, result.courseId) || courseName;
                } catch (_) { }
                const oldDate = result.oldReservedDateString;
                const oldTime = result.oldStartTime;
                const newDate = result.newReservedDateString;
                const newTime = result.newStartTime;

                // 날짜 포맷팅 (YYYY-MM-DD -> YYYY년 MM월 DD일)
                const formatDate = (dateStr: string): string => {
                    const { y, mo, d } = parseYYYYMMDD(dateStr);
                    return `${y}년 ${mo}월 ${d}일`;
                };

                const oldDateFormatted = formatDate(oldDate);
                const newDateFormatted = formatDate(newDate);

                // 알림 생성 (createNotification 헬퍼 함수 사용)
                await createNotification({
                    userId: result.userId,
                    type: 'reservation',
                    title: `${courseName} 예약이 변경되었습니다`,
                    body: `${courseName} - ${oldDateFormatted} ${oldTime} → ${newDateFormatted} ${newTime}`,
                    placeId: result.placeId,
                    data: {
                        reservationId,
                        courseId: result.courseId,
                        placeId: result.placeId,
                    },
                    isAdmin: false,
                });
            } catch (error) {
                // 알림 생성 실패해도 예약 이동은 성공한 것으로 처리
                console.error(`[moveReservationWithinCourse] Error creating notification:`, error);
            }
        }
        return result;
    });
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
    isAdmin = false,
}: {
    userId: string;
    title: string;
    body: string;
    data?: Record<string, any>;
    isAdmin?: boolean;
}): Promise<void> {
    try {
        // 관리자 알림인 경우 adminUsers 컬렉션에서 조회
        const collectionName = isAdmin ? 'adminUsers' : 'users';
        const userDoc = await admin.firestore().collection(collectionName).doc(userId).get();
        if (!userDoc.exists) {
            console.warn(`[sendPushNotification] ${isAdmin ? 'Admin' : 'User'} not found: ${userId}`);
            return;
        }

        const userData = userDoc.data();
        const fcmToken = userData?.fcmToken;

        // 알림 설정 확인
        const notificationsEnabled = userData?.notificationsEnabled !== false; // 기본값 true

        if (!fcmToken) {
            console.warn(`[sendPushNotification] No FCM token for ${isAdmin ? 'admin' : 'user'}: ${userId}`);
            return;
        }

        if (!notificationsEnabled) {
            console.log(`[sendPushNotification] Notifications disabled for ${isAdmin ? 'admin' : 'user'}: ${userId}`);
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
        const isAdmin = notification.isAdminNotification === true;

        try {
            await sendPushNotification({
                userId: notification.userId,
                title: notification.title || '알림',
                body: notification.body || '',
                isAdmin: isAdmin,
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
        // status 제거로 항상 멤버이므로 알림 전송 로직 제거
        // 필요시 다른 필드 변경에 대한 알림 로직 추가 가능
    });

/**
 * 등록 연장 요청 생성 시 관리자에게 알림 전송
 */
export const onExtensionRequestCreated = functions.firestore
    .document('enrollments/{enrollmentId}/extensionRequests/{requestId}')
    .onCreate(async (snap: QueryDocumentSnapshot, context: EventContext) => {
        const request = snap.data();
        const enrollmentId = context.params.enrollmentId;
        const requestId = context.params.requestId;

        // pending 상태인 경우에만 알림 전송
        if (request.status !== 'pending') {
            return;
        }

        try {
            // enrollment 정보 조회
            const enrollmentDoc = await admin.firestore().collection('enrollments').doc(enrollmentId).get();
            if (!enrollmentDoc.exists) {
                console.warn(`[onExtensionRequestCreated] Enrollment not found: ${enrollmentId}`);
                return;
            }

            const enrollmentData = enrollmentDoc.data();
            const userId = enrollmentData?.userId as string;
            const courseId = enrollmentData?.courseId as string;
            const placeId = enrollmentData?.placeId as string;

            // 사용자 정보 조회
            const userDoc = await admin.firestore().collection('users').doc(userId).get();
            if (!userDoc.exists) {
                console.warn(`[onExtensionRequestCreated] User not found: ${userId}`);
                return;
            }
            const userData = userDoc.data();
            const userName = userData?.name || '사용자';

            // 코스 정보 조회
            const placeDoc = await admin.firestore().collection('places').doc(placeId).get();
            if (!placeDoc.exists) {
                console.warn(`[onExtensionRequestCreated] Place not found: ${placeId}`);
                return;
            }
            const placeData = placeDoc.data();
            const courses = (placeData?.courses as any[]) || [];
            const course = courses.find((c: any) => c.id === courseId);
            const courseName = course?.name || courseId;

            // 해당 플레이스의 모든 관리자 조회
            const adminUsersSnapshot = await admin.firestore()
                .collection('adminUsers')
                .where('placeIds', 'array-contains', placeId)
                .get();

            if (adminUsersSnapshot.empty) {
                console.warn(`[onExtensionRequestCreated] No admins found for place: ${placeId}`);
                return;
            }

            // 각 관리자에게 알림 생성
            const notificationPromises = adminUsersSnapshot.docs.map((adminDoc) => {
                const adminData = adminDoc.data();
                const adminUserId = adminData.userId;

                return createNotification({
                    userId: adminUserId,
                    type: 'system',
                    title: `${courseName} 등록 연장 요청`,
                    body: `${userName}님이 ${courseName} 등록 연장을 요청했습니다`,
                    placeId,
                    data: {
                        enrollmentId,
                        requestId,
                        userId,
                        courseId,
                        placeId,
                    },
                    isAdmin: true,
                });
            });

            await Promise.all(notificationPromises);
            console.log(`[onExtensionRequestCreated] Created notifications for ${adminUsersSnapshot.docs.length} admins`);
        } catch (error) {
            console.error(`[onExtensionRequestCreated] Error creating notifications:`, error);
        }
    });

/**
 * 방문일 알림 (세션 시작 2시간 전)
 * 매 5분마다 실행하여 2시간 후 시작하는 세션의 예약자에게 알림 전송
 */
export const sendUpcomingSessionNotifications = functions.pubsub
    .schedule('every 5 minutes')
    .timeZone('Asia/Seoul')
    .onRun(async (context: EventContext) => {
        try {
            const now = getSeoulDateTime();
            const inTwoHours = new Date(now.getTime() + 2 * 60 * 60 * 1000);

            // 2시간 후의 날짜와 시간 계산
            const targetDateString = formatDate(inTwoHours); // "YYYY-MM-DD"
            const targetHour = inTwoHours.getHours();
            const targetMinute = inTwoHours.getMinutes();
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

                    // 알림 생성
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: `${courseName} 곧 세션이 시작됩니다`,
                        body: `${courseName} - ${targetDateString} ${targetHHmm} (2시간 전)`,
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
 * 관리자에서 사용자에게 초대 요청 전송 (pushMessage만 전송)
 */
export const sendInvitation = functions.https.onCall(async (data, context) => {
    const functionName = 'sendInvitation';
    logFunctionStart(functionName, { userId: context.auth?.uid, ...data });

    if (!context.auth?.uid) {
        logFunctionError(functionName, new Error('Unauthenticated'), { data });
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    await assertAdminUid(context.auth.uid);

    const userId = String(data?.userId ?? '');
    const placeId = String(data?.placeId ?? '');
    const phoneNumber = String(data?.phoneNumber ?? '');
    const name = String(data?.name ?? '');

    if (!userId || !placeId || !phoneNumber || !name) {
        logFunctionError(functionName, new Error('Invalid arguments'), { userId, placeId, phoneNumber, name });
        throw new functions.https.HttpsError('invalid-argument', 'userId, placeId, phoneNumber, name이 필요합니다.');
    }

    try {
        // 플레이스 정보 조회
        const placeDoc = await admin.firestore().collection('places').doc(placeId).get();
        if (!placeDoc.exists) {
            logFunctionError(functionName, new Error('Place not found'), { placeId });
            throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
        }

        const placeData = placeDoc.data();
        const placeName = placeData?.name || '플레이스';

        // 사용자에게 알림 생성 및 pushMessage 전송
        await createNotification({
            userId: userId,
            type: 'system',
            title: '초대 요청',
            body: `${placeName}에서 초대 요청이 있습니다`,
            placeId: placeId,
            data: {
                type: 'invitation',
                placeId: placeId,
                placeName: placeName,
            },
            isAdmin: false,
        });

        logFunctionSuccess(functionName, { userId, placeId, name });
        return { success: true };
    } catch (error) {
        logFunctionError(functionName, error, { userId, placeId });
        throw error;
    }
});

