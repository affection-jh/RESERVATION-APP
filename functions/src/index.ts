import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import type { EventContext } from 'firebase-functions';
import type { QueryDocumentSnapshot } from 'firebase-functions/v1/firestore';
import type { Change } from 'firebase-functions';
import { logFunctionStart, logFunctionSuccess, logFunctionError } from './logger';
import { assertAdminForPlaceUid, isAdminForPlaceUid, getPlaceIdsWhereUserMustDeletePlaceFirst, demoteSubManagerToMemberIfNoCoursesInternal, getManagerUidsForPlaceAndCourse } from './admin_auth';
import { getCourseName, getCourseNameFromCourse, getCourseOrThrow } from './course_catalog';
import { throwRequiresForce, throwRequiresCascade, throwRequiresCascadeDeleteCourse, throwRequiresBulkMove } from './action_protocol';

import { incrementReservedCount, incrementReservedCountBy, decrementReservedCount, decrementReservedCountBy, deleteSummariesForCourse } from './reservation_ops';
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

/** enrollments 쿼리로 삭제 시 서브컬렉션(actionHistory, extensionRequests) 먼저 삭제 후 문서 삭제 (고아 방지) */
async function deleteEnrollmentsWithSubcollections(
    db: FirebaseFirestore.Firestore,
    query: FirebaseFirestore.Query,
    batchSize = 200,
): Promise<number> {
    let deleted = 0;
    while (true) {
        const snap = await query.limit(batchSize).get();
        if (snap.empty) break;
        for (const doc of snap.docs) {
            await deleteByQuery(db, doc.ref.collection('actionHistory'), 400);
            await deleteByQuery(db, doc.ref.collection('extensionRequests'), 400);
            await doc.ref.delete();
            deleted++;
        }
        if (snap.docs.length < batchSize) break;
    }
    return deleted;
}

admin.initializeApp();

/**
 * ==================== Reservation Policy (Server) ====================
 *
 * 앱이 "단일 진실"로 트랜잭션을 갖는 구조를 유지하려면:
 * - reservations / enrollments(remainingReservations) 변경은
 *   반드시 "한 곳"에서만 수행되어야 합니다.
 * (sessionReservations 컬렉션 없음 — N/M은 클라이언트에서 reservations 구독 + 코스/오버라이드로 계산)
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
    updatedAt?: Date;
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

/** 알림 본문용 날짜+시간 포맷: "2026년 2월 17일 16:00시" */
function formatDateTimeKr(dateStr: string, timeStr: string): string {
    const { y, mo, d } = parseYYYYMMDD(dateStr);
    return `${y}년 ${mo}월 ${d}일 ${timeStr}시`;
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

/** 서울 기준 해당 날짜의 23:59:59.999 (수강 마감일 당일 전체까지 예약 가능) */
function makeSeoulEndOfDay(y: number, mo: number, d: number): Date {
    const startOfNext = new Date(makeSeoulDateTime(y, mo, d, 0, 0).getTime() + 24 * 60 * 60 * 1000);
    return new Date(startOfNext.getTime() - 1);
}

/** Date를 서울 날짜 (y, mo, d)로 변환 */
function getSeoulDateParts(date: Date): { y: number; mo: number; d: number } {
    const t = date.getTime() + 9 * 60 * 60 * 1000;
    const d2 = new Date(t);
    return { y: d2.getUTCFullYear(), mo: d2.getUTCMonth() + 1, d: d2.getUTCDate() };
}

/** epoch Date를 서울 기준 "YYYY-MM-DD"로 변환 (비교/쿼리용) */
function formatDateToSeoul(date: Date): string {
    const { y, mo, d } = getSeoulDateParts(date);
    return `${y}-${pad2(mo)}-${pad2(d)}`;
}

/** Date를 서울 시각 (시, 분)으로 변환 */
function getSeoulTimeParts(date: Date): { h: number; m: number } {
    const t = date.getTime() + 9 * 60 * 60 * 1000;
    const d2 = new Date(t);
    return { h: d2.getUTCHours(), m: d2.getUTCMinutes() };
}

function addDaysUtc(date: Date, days: number): Date {
    return new Date(date.getTime() + days * 24 * 60 * 60 * 1000);
}

function seoulWeekday1to7(dateString: string): number {
    // 캘린더 날짜(y,mo,d)의 요일은 전역 동일. seoulDateOnly+getUTCDay는 UTC 전날을 가리켜 요일이 틀림.
    const { y, mo, d } = parseYYYYMMDD(dateString);
    const d2 = new Date(Date.UTC(y, mo - 1, d, 12, 0)); // noon UTC로 날짜 경계 이슈 회피
    const day0 = d2.getUTCDay(); // 0=일..6=토
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
    // openWeekStart는 월요일 00:00(서울). 서울 날짜로 releaseDay/releaseTime 적용 (UTC getUTC* 사용 시 전날로 어긋남)
    const openParts = getSeoulDateParts(openWeekStart);
    return addDaysUtc(makeSeoulDateTime(openParts.y, openParts.mo, openParts.d, h, m), (w.releaseDayOfWeek ?? 1) - 1);
}

function parsePolicy(raw: any, fallback: { courseId: string; placeId: string }): CoursePolicy {
    const openStrategyRaw = (raw?.openStrategy ?? {}) as any;
    const type = (openStrategyRaw?.type as BookingOpenStrategyType) ?? 'rollingWindow';
    const closeBeforeMinutes = Number(raw?.closeBeforeMinutes ?? 60);

    let updatedAt: Date | undefined;
    const updatedAtRaw = raw?.updatedAt;
    if (updatedAtRaw instanceof admin.firestore.Timestamp) {
        updatedAt = updatedAtRaw.toDate();
    } else if (typeof updatedAtRaw === 'string') {
        updatedAt = new Date(updatedAtRaw);
    }

    return {
        courseId: String(raw?.courseId ?? fallback.courseId),
        placeId: String(raw?.placeId ?? fallback.placeId),
        closeBeforeMinutes: Number.isFinite(closeBeforeMinutes) ? closeBeforeMinutes : 60,
        openStrategy: {
            type,
            rollingWindow: openStrategyRaw?.rollingWindow,
            weeklyRelease: openStrategyRaw?.weeklyRelease,
        },
        updatedAt,
    };
}

/** 코스 문서(course doc from places/{placeId}/courses/{courseId})에서 policy 필드로 CoursePolicy 생성 */
function getPolicyFromCourseDoc(courseData: any, courseId: string, placeId: string): CoursePolicy {
    const fallback = { courseId, placeId };
    const raw = courseData?.policy;
    return parsePolicy(raw && typeof raw === 'object' ? raw : {}, fallback);
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
    // 1) 과거 날짜 (가장 우선 체크) — now는 epoch 기준 현재 시각, 서울 날짜는 getSeoulDateParts로
    const todayString = formatDateToSeoul(now);
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
 * 예약 생성 시 트리거 (비활성화)
 * - reservationSummary 갱신은 createReservation 트랜잭션 내에서 처리.
 */
export const onReservationCreated = functions.firestore
    .document('reservations/{reservationId}')
    .onCreate(async (_snap: QueryDocumentSnapshot, _context: EventContext) => {
        // no-op: createReservation 트랜잭션 내에서 reservationSummary increment 처리
    });

/**
 * 예약 삭제 시: reservationSummary decrement (일괄 취소/멤버 제거/코스 삭제 등 모든 삭제 경로 자동 정리)
 */
export const onReservationDeleted = functions.firestore
    .document('reservations/{reservationId}')
    .onDelete(async (snap: QueryDocumentSnapshot, _context: EventContext) => {
        const data = snap.data() as any;
        const placeId = String(data?.placeId ?? '');
        const courseId = String(data?.courseId ?? '');
        const dayOfWeek = Number(data?.dayOfWeek ?? 0);
        const startTime = String(data?.startTime ?? '');
        const reservedDateString = String(data?.reservedDateString ?? '');
        if (!placeId || !courseId || !startTime || !reservedDateString || !Number.isFinite(dayOfWeek)) return;
        const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
        const db = admin.firestore();
        try {
            await db.runTransaction(async (tx) => {
                await decrementReservedCount(tx, db, { sessionId, reservedDateString });
            });
        } catch (e: any) {
            console.error('[onReservationDeleted] Error:', e?.message ?? e);
        }
    });

/**
 * 등록 정보 생성 시 (courseMembers 미사용 — 앱은 enrollments 단일 소스로 조회)
 */
export const onEnrollmentCreated = functions.firestore
    .document('enrollments/{enrollmentId}')
    .onCreate(async (snap: QueryDocumentSnapshot, context: EventContext) => {
        // no-op: 멤버 목록은 enrollments 컬렉션만으로 조회
    });

/**
 * 등록 정보 업데이트 시 (courseMembers 미사용)
 */
export const onEnrollmentUpdated = functions.firestore
    .document('enrollments/{enrollmentId}')
    .onUpdate(async (_change: Change<QueryDocumentSnapshot>, _context: EventContext) => {
        // no-op
    });

/**
 * 등록 정보 삭제 시 (courseMembers 미사용)
 */
export const onEnrollmentDeleted = functions.firestore
    .document('enrollments/{enrollmentId}')
    .onDelete(async (_snap: QueryDocumentSnapshot, _context: EventContext) => {
        // no-op
    });

/**
 * 로그인 후 pendingMembers 기반 enrollments 생성 (places/{placeId}/members 기준, placeMemberships 미사용)
 * 클라이언트에서 전화번호로 호출 → 해당 전화번호의 pendingMembers를 찾아
 * context.auth.uid로 enrollments 생성 후 pendingMembers 삭제
 */
export const createEnrollmentsFromPendingMembers = functions.https.onCall(async (data, context) => {
    try {
        if (!context.auth?.uid) {
            throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
        }
        const userId = context.auth.uid;
        const rawPhone = String(data?.phoneNumber ?? '').trim();
        if (!rawPhone) {
            throw new functions.https.HttpsError('invalid-argument', 'phoneNumber가 필요합니다.');
        }

        // pendingMembers 저장 형식과 동일하게 정규화 (registerMemberByAdmin과 동일)
        const normalized = rawPhone.replace(/\D/g, '');
        const phoneNumber = normalized.startsWith('82')
            ? '0' + normalized.slice(2)
            : normalized.startsWith('0')
                ? normalized
                : '0' + normalized;

        const db = admin.firestore();
        const pendingSnap = await db.collectionGroup('pendingMembers')
            .where('phoneNumber', '==', phoneNumber)
            .get();
        if (pendingSnap.empty) {
            return { created: 0, places: [] };
        }

        const enrollmentTime = admin.firestore.Timestamp.now();
        let createdCount = 0;
        const placeIds: string[] = [];

        const toDate = (v: unknown): Date => {
            if (!v) return enrollmentTime.toDate();
            if (typeof (v as any).toDate === 'function') return (v as admin.firestore.Timestamp).toDate();
            const d = new Date(v as any);
            return isNaN(d.getTime()) ? enrollmentTime.toDate() : d;
        };

        for (const pendingDoc of pendingSnap.docs) {
            const pendingData = pendingDoc.data();
            const pathParts = pendingDoc.ref.path.split('/');
            const placeId = (pendingData.placeId as string) || (pathParts[1] ?? '');
            if (!placeId) continue;

            const courseEnrollments = pendingData.courseEnrollments as any[] | undefined;
            const allowedIdsRaw = Array.isArray(pendingData.allowedCourseIds)
                ? (pendingData.allowedCourseIds as string[])
                : Array.isArray(pendingData.courseIds) ? (pendingData.courseIds as string[]) : [];
            const allowedIds = allowedIdsRaw.map((id) => (id != null ? String(id) : '')).filter(Boolean);
            const fromEnrollments =
                courseEnrollments != null
                    ? courseEnrollments
                        .map((e: any) => (e?.courseId != null ? String(e.courseId) : null))
                        .filter((id): id is string => Boolean(id))
                    : [];
            // 병합: courseEnrollments + allowedCourseIds 중복 제거 (여러 코스가 1개만 등록되는 버그 방지)
            const courseIdsSet = new Set<string>([...fromEnrollments, ...allowedIds]);
            const courseIds = Array.from(courseIdsSet);
            if (courseIds.length === 0) {
                await pendingDoc.ref.delete();
                continue;
            }
            console.log(`[createEnrollmentsFromPendingMembers] placeId=${placeId} courseIds=${courseIds.length} ids=${courseIds.join(',')}`);

            const adminDisplayName = (pendingData.adminDisplayName as string)?.trim()
                || (pendingData.name as string)?.trim()
                || null;
            placeIds.push(placeId);

            const pendingRole = (pendingData.role as string) || 'member';
            const isSubManager = pendingRole === 'subManager' || pendingRole === 'submanager';
            const memberRole = isSubManager ? 'submanager' : 'member';
            const manageableCourseIds = isSubManager && Array.isArray(pendingData.allowedCourseIds)
                ? (pendingData.allowedCourseIds as string[]).map((id: string) => String(id)).filter(Boolean)
                : [];

            const memberRef = db.collection('places').doc(placeId).collection('members').doc(userId);
            const userDoc = await db.collection('users').doc(userId).get();
            const userPhone = userDoc.exists ? (userDoc.data()?.phoneNumber as string) ?? phoneNumber : phoneNumber;

            await memberRef.set({
                userId,
                role: memberRole,
                adminDisplayName: adminDisplayName || null,
                phoneNumber: userPhone,
                manageableCourseIds,
                createdAt: enrollmentTime,
                updatedAt: enrollmentTime,
            }, { merge: true });

            const existingSnap = await db.collection('enrollments')
                .where('userId', '==', userId)
                .where('placeId', '==', placeId)
                .get();
            const existingCourseIds = new Set(existingSnap.docs.map(d => d.data().courseId as string));

            const batch = db.batch();
            let batchWrites = 0;
            for (const courseId of courseIds) {
                if (existingCourseIds.has(courseId)) continue;

                let totalReservations = 10;
                // validFrom = 등록 시점(enrolledAt)과 동일
                const validFrom = enrollmentTime.toDate();
                let validUntil = new Date(validFrom);
                validUntil.setFullYear(validUntil.getFullYear() + 1);
                let initialRemaining = totalReservations;
                if (courseEnrollments) {
                    const cfg = courseEnrollments.find((e: any) => e.courseId === courseId);
                    if (cfg?.totalReservations != null) totalReservations = Number(cfg.totalReservations);
                    if (cfg?.validUntil) validUntil = toDate(cfg.validUntil);
                    if (cfg?.remainingReservations != null) initialRemaining = Math.min(Number(cfg.remainingReservations), totalReservations);
                } else {
                    const courseDoc = await db.collection('places').doc(placeId).collection('courses').doc(courseId).get();
                    const course = courseDoc.exists ? courseDoc.data() : null;
                    totalReservations = course?.defaultTotalReservations ?? 10;
                }
                // 수강 유효기간: validFrom = 등록 시점(enrollmentTime), validUntil = 마감일 23:59:59 (그날 전체)
                const untilParts = getSeoulDateParts(validUntil);
                const validUntilNorm = makeSeoulEndOfDay(untilParts.y, untilParts.mo, untilParts.d);

                const enrollmentId = `${userId}_${placeId}_${courseId}`;
                const ref = db.collection('enrollments').doc(enrollmentId);
                batch.set(ref, {
                    userId,
                    courseId,
                    placeId,
                    enrolledAt: enrollmentTime,
                    validFrom: enrollmentTime,
                    validUntil: admin.firestore.Timestamp.fromDate(validUntilNorm),
                    totalReservations,
                    remainingReservations: initialRemaining,
                    totalEnrollmentCount: 1,
                    adminDisplayName: adminDisplayName || '',
                });
                batchWrites++;
                createdCount++;
            }
            if (batchWrites > 0) await batch.commit();
            await pendingDoc.ref.delete();
        }

        return { created: createdCount, places: [...new Set(placeIds)] };
    } catch (err: any) {
        if (err instanceof functions.https.HttpsError) throw err;
        const msg = err?.message ?? String(err);
        console.error('[createEnrollmentsFromPendingMembers]', err);
        throw new functions.https.HttpsError('internal', `enrollment 생성 실패: ${msg}`);
    }
});

/**
 * 주기적 데이터 검증 (매일 24시간마다) — 현재 no-op
 * - sessionReservations 컬렉션 미사용. N/M은 클라이언트에서 reservations 구독으로 계산하므로 별도 검증 불필요.
 */
export const validateDataConsistency = functions.pubsub
    .schedule('every 24 hours')
    .timeZone('Asia/Seoul')
    .onRun(async (_context: EventContext) => {
        console.log('[validateDataConsistency] No-op (sessionReservations not used; reservations are source of truth).');
    });

// ==================== Helper Functions ====================




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

/** 두 시간 구간이 겹치는지 확인 (조금이라도 겹치면 true) */
function doTimesOverlap(
    aStart: string,
    aEnd: string,
    bStart: string,
    bEnd: string,
): boolean {
    const toMin = (hhmm: string) => {
        const { h, m } = parseHHmm(hhmm);
        return h * 60 + m;
    };
    const aS = toMin(aStart);
    const aE = toMin(aEnd);
    const bS = toMin(bStart);
    const bE = toMin(bEnd);
    return aS < bE && aE > bS;
}


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
    const createOneTimeEnrollment = data?.createOneTimeEnrollment === true; // 수강 미등록 시 1회석 enrollment 생성 후 예약(관리자만)
    // data.adminDisplayNameForUser는 클라이언트 표시용, 서버에서는 미사용

    // 관리자가 다른 사용자를 위해 예약 생성 시 userId 파라미터 사용
    // 없으면 호출자 본인의 예약 생성
    const requestedUserId = String(data?.userId ?? '').trim();
    let userId: string;
    let isAdminCreatingForUser = false;

    if (requestedUserId && requestedUserId !== callerId) {
        // 다른 사용자를 위해 예약 생성 시도 - 해당 플레이스 관리자 권한 확인
        if (!requestedUserId || requestedUserId.length === 0) {
            throw new functions.https.HttpsError('invalid-argument', '유효하지 않은 userId입니다.');
        }
        if (!placeId || !courseId) {
            throw new functions.https.HttpsError('invalid-argument', 'placeId, courseId가 필요합니다.');
        }
        try {
            await assertAdminForPlaceUid(callerId, placeId);
            const dbAuth = admin.firestore();
            const callerMemberSnap = await dbAuth.collection('places').doc(placeId).collection('members').doc(callerId).get();
            const callerData = callerMemberSnap.data();
            const callerRole = String(callerData?.role ?? '').toLowerCase();
            if (callerRole === 'submanager') {
                const rawManageable = callerData?.manageableCourseIds;
                const manageableCourseIds: string[] = Array.isArray(rawManageable)
                    ? (rawManageable as string[]).map((id: string) => String(id)).filter(Boolean)
                    : [];
                if (manageableCourseIds.length === 0) {
                    await demoteSubManagerToMemberIfNoCoursesInternal(dbAuth, placeId, callerId);
                    throw new functions.https.HttpsError('permission-denied', '관리할 코스가 없습니다.');
                }
                if (!manageableCourseIds.includes(courseId)) {
                    throw new functions.https.HttpsError(
                        'permission-denied',
                        '부매니저는 지정된 관리 코스에만 예약을 생성할 수 있습니다.',
                    );
                }
            }
            userId = requestedUserId;
            isAdminCreatingForUser = true;
            console.log(`[createReservation] Admin ${callerId} creating reservation for user ${userId}`);
        } catch (error) {
            if (error instanceof functions.https.HttpsError) throw error;
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
    if (dayOfWeek < 1 || dayOfWeek > 7) {
        throw new functions.https.HttpsError('invalid-argument', 'dayOfWeek는 1-7(월-일) 사이여야 합니다.');
    }

    const db = admin.firestore();
    const now = new Date(); // epoch 기준 현재 시각 (비교·날짜 추출 공통, 9h 시프트 오류 방지)
    const todayString = formatDateToSeoul(now); // 서울 기준 오늘 날짜

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
            let isOneTimeDummy = false; // true: 미등록/펜딩 일회성 → enrollment·pendingMembers 건드리지 않고 예약만 생성
            // pending 멤버의 경우 이미 읽은 문서를 나중에 재사용하기 위해 저장
            let pendingDocForUpdate: admin.firestore.DocumentSnapshot | null = null;
            let pendingDataForUpdate: any = null;

            if (isPendingMember) {
                // pending 멤버: places/{placeId}/pendingMembers에서 조회
                const pendingId = userId.replace('pending_', '');
                const pendingRef = db.collection('places').doc(placeId).collection('pendingMembers').doc(pendingId);
                const pendingDoc = await tx.get(pendingRef);

                if (!pendingDoc.exists) {
                    throw new functions.https.HttpsError('failed-precondition', '등록된 코스가 아닙니다.');
                }

                const pendingData = pendingDoc.data() as any;
                // 나중에 업데이트할 때 재사용하기 위해 저장
                pendingDocForUpdate = pendingDoc;
                pendingDataForUpdate = pendingData;
                const courseEnrollments = pendingData?.courseEnrollments as any[] | undefined;
                const allowedIds = Array.isArray(pendingData?.allowedCourseIds) ? (pendingData.allowedCourseIds as string[]) : null;
                const courseIdsForCheck = courseEnrollments?.map((e: any) => e?.courseId) ?? allowedIds ?? [];

                if (courseIdsForCheck.length === 0) {
                    throw new functions.https.HttpsError('failed-precondition', '등록된 코스가 아닙니다.');
                }

                // 해당 코스의 enrollment 찾기 (courseEnrollments 또는 allowedCourseIds)
                const courseEnrollment = courseEnrollments?.find((ce: any) => ce?.courseId === courseId);
                if (!courseEnrollment && !allowedIds?.includes(courseId)) {
                    throw new functions.https.HttpsError('failed-precondition', '등록된 코스가 아닙니다.');
                }

                // remainingReservations (courseEnrollments 있으면 사용, 없으면 allowedCourseIds만 있을 때 기본값 10)
                const totalReservations = Number(courseEnrollment?.totalReservations ?? 10);
                remainingReservations = Number(courseEnrollment?.remainingReservations ?? totalReservations);
                const validFromRaw = courseEnrollment?.validFrom ?? null;
                const validUntilRaw = courseEnrollment?.validUntil ?? null;
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
                if (createOneTimeEnrollment && isAdminCreatingForUser) {
                    isOneTimeDummy = true; // 펜딩 일회성: pendingMembers 업데이트 없이 예약만 생성
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
                    if (createOneTimeEnrollment && isAdminCreatingForUser) {
                        // 미등록 회원 일회성 추가: enrollment 생성 없이 예약만 생성(더미)
                        isOneTimeDummy = true;
                        const nowDate = new Date();
                        const validUntilDate = new Date(nowDate);
                        validUntilDate.setFullYear(validUntilDate.getFullYear() + 1);
                        remainingReservations = 0;
                        validFrom = nowDate;
                        validUntil = validUntilDate;
                        console.log(`[createReservation] One-time dummy reservation (no enrollment): userId=${userId}, courseId=${courseId}`);
                    } else {
                        throw new functions.https.HttpsError('failed-precondition', '등록된 코스가 아닙니다.');
                    }
                } else {
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
            }

            // 날짜만 비교 (시간 무시) - validUntil 당일까지 예약 가능. 모두 서울 기준으로 통일(9h 시프트 방지)
            const today = seoulDateOnly(todayString);
            const validFromString = formatDateToSeoul(validFrom);
            const validUntilString = formatDateToSeoul(validUntil);
            const validFromDate = seoulDateOnly(validFromString);
            const validUntilDate = seoulDateOnly(validUntilString);

            let enrollmentCanReserve =
                today >= validFromDate && today <= validUntilDate && remainingReservations > 0;
            if (isOneTimeDummy) enrollmentCanReserve = true; // 미등록/펜딩 일회성은 정책만 통과

            console.log(`[createReservation] enrollment check: userId=${userId}, isPending=${isPendingMember}, isOneTimeDummy=${isOneTimeDummy}, remainingReservations=${remainingReservations}, today=${todayString}, validFrom=${validFromString}, validUntil=${validUntilString}, canReserve=${enrollmentCanReserve}`);

            // 2) place + course + session (코스는 서브컬렉션 places/{placeId}/courses/{courseId})
            const placeDoc = await tx.get(placeRef);
            if (!placeDoc.exists) {
                throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
            }
            const courseRef = placeRef.collection('courses').doc(courseId);
            const courseDoc = await tx.get(courseRef);
            if (!courseDoc.exists) {
                throw new functions.https.HttpsError('not-found', '코스를 찾을 수 없습니다.');
            }
            const course = courseDoc.data()!;
            // 3) 정책: 코스 문서 내 policy 필드에서 로드
            const policy = getPolicyFromCourseDoc(course, courseId, placeId);

            // 4) 세션 찾기 (정기 일정 또는 비정기 일정)
            const session = findSession(course, dayOfWeek, startTime);
            const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
            let capacity: number;
            let isOverrideSession = false; // override 세션인지 여부
            let newEndTime: string;

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
                newEndTime = String(overrideData?.endTime ?? startTime);
            } else {
                newEndTime = String(session.endTime ?? startTime);
                // 정원 오버라이드: 단일 소스 sessionId_date만 사용 (레거시 _cap 제거)
                const capDocId = `${sessionId}_${reservedDateString}`;
                const capDoc = await tx.get(db.collection('courseOverrides').doc(capDocId));
                const overrideCap = capDoc.exists ? Number((capDoc.data() as any)?.capacity) : undefined;
                capacity = Number.isFinite(overrideCap) ? (overrideCap as number) : Number(session.capacity ?? 0);
            }

            // 5) reservedCount = reservationSummary에서 가져오기 (단일 소스, 클라이언트와 동일)
            // 트랜잭션 규칙: 모든 읽기는 쓰기 전에 완료 → summary는 아래 7.5에서 읽음
            const summaryRef = db.collection('reservationSummary').doc(`${sessionId}_${reservedDateString}`);
            const summarySnap = await tx.get(summaryRef);
            const currentReservedCount = summarySnap.exists ? Number((summarySnap.data() as any)?.reservedCount ?? 0) : 0;

            const cancelOverrideQuery = db
                .collection('courseOverrides')
                .where('placeId', '==', placeId)
                .where('courseId', '==', courseId)
                .where('date', '==', reservedDateString)
                .where('dayOfWeek', '==', dayOfWeek)
                .where('startTime', '==', startTime)
                .where('isCancelled', '==', true)
                .limit(1);
            const cancelSnap = await tx.get(cancelOverrideQuery as any);
            if (!cancelSnap.empty) {
                // 같은 슬롯에 비정기 추가(add) 오버라이드가 있으면 예약 가능
                const addOverrideQuery = db
                    .collection('courseOverrides')
                    .where('placeId', '==', placeId)
                    .where('courseId', '==', courseId)
                    .where('date', '==', reservedDateString)
                    .where('dayOfWeek', '==', dayOfWeek)
                    .where('startTime', '==', startTime)
                    .where('isCancelled', '==', false)
                    .limit(1);
                const addSnap = await tx.get(addOverrideQuery as any);
                if (addSnap.empty) {
                    throw new functions.https.HttpsError('failed-precondition', '취소된 세션입니다.');
                }
            }

            // 5.5) 시간 겹침 검사: 같은 날 다른 과목과 조금이라도 겹치면 차단
            const overlapQuery = db
                .collection('reservations')
                .where('placeId', '==', placeId)
                .where('userId', '==', userId)
                .where('reservedDateString', '==', reservedDateString);
            const overlapSnap = await tx.get(overlapQuery as any);
            const courseCache = new Map<string, any>();
            courseCache.set(courseId, course);

            for (const doc of overlapSnap.docs) {
                const r = doc.data() as any;
                const rCourseId = String(r?.courseId ?? '');
                let rDay = Number(r?.dayOfWeek ?? 0);
                if (rDay < 1 || rDay > 7) rDay = seoulWeekday1to7(reservedDateString);
                const rStart = String(r?.startTime ?? '');

                let rEnd: string;
                let rCourse = courseCache.get(rCourseId);
                if (!rCourse) {
                    const rCourseDoc = await tx.get(placeRef.collection('courses').doc(rCourseId));
                    rCourse = rCourseDoc.exists ? rCourseDoc.data() : null;
                    courseCache.set(rCourseId, rCourse);
                }
                const rSession = rCourse ? findSession(rCourse, rDay, rStart) : null;
                if (rSession) {
                    rEnd = String(rSession.endTime ?? rStart);
                } else {
                    const ovQuery = db
                        .collection('courseOverrides')
                        .where('courseId', '==', rCourseId)
                        .where('placeId', '==', placeId)
                        .where('date', '==', reservedDateString)
                        .where('dayOfWeek', '==', rDay)
                        .where('startTime', '==', rStart)
                        .where('isCancelled', '==', false)
                        .limit(1);
                    const ovSnap = await tx.get(ovQuery as any);
                    const ovData = !ovSnap.empty ? (ovSnap.docs[0].data() as any) : null;
                    rEnd = ovData ? String(ovData.endTime ?? rStart) : rStart;
                }

                if (doTimesOverlap(startTime, newEndTime, rStart, rEnd)) {
                    const errMsg = isAdminCreatingForUser
                        ? '해당 시간대에 이미 다른 과목 예약이 있어 추가할 수 없습니다.'
                        : '해당 시간대에 이미 다른 과목 예약이 있습니다. 겹치지 않는 시간을 선택해 주세요.';
                    throw new functions.https.HttpsError('failed-precondition', errMsg);
                }
            }

            // 6) 중복 예약(유저가 이미 같은 세션/날짜 예약) - 글로벌 reservations
            const dupQuery = db
                .collection('reservations')
                .where('placeId', '==', placeId)
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

            // 7) 미리 열린 주차 확인 (관리자가 미리 예약 열기한 주차인지). 주차 키는 서울 기준 월요일 날짜로 통일
            const reservedDate = seoulDateOnly(reservedDateString);
            const weekStart = startOfWeekMondaySeoul(reservedDateString);
            const weekStartDateString = formatDateToSeoul(weekStart);
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

                    // ⚠️ 관리자 “강제 추가”가 가능한 케이스: force=true 또는 일회성 추가(createOneTimeEnrollment)면 확인 없이 통과
                    const forceableReasons = new Set([
                        ReservationLockReason.full,
                        ReservationLockReason.closedBeforeStart,
                        ReservationLockReason.notOpenedYet,
                    ]);
                    const mayForceWithoutDialog = force || createOneTimeEnrollment;
                    if (forceableReasons.has(eligibility.reason as any)) {
                        if (!mayForceWithoutDialog) {
                            // UI에서 "강제 추가" 확인 다이얼로그를 띄울 수 있도록 상세 정보 반환
                            throwRequiresForce({
                                reason: eligibility.reason,
                                openAt: eligibility.openAt ? eligibility.openAt.toISOString() : null,
                                capacity,
                                reservedCount: currentReservedCount,
                                closeBeforeMinutes: policy.closeBeforeMinutes ?? 60,
                            });
                        }
                        console.log(`[createReservation] Admin force create: ${eligibility.reason}${createOneTimeEnrollment ? ' (one-time)' : ''}`);
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
                        default:
                            throw new functions.https.HttpsError(
                                'failed-precondition',
                                '예약할 수 없는 상태입니다.',
                                { reason: String(eligibility.reason) },
                            );
                    }
                }
            }

            // 7.5) reservationSummary는 이미 위 5)에서 읽음 (중복 읽기 제거)

            // 8) reservation 생성 (글로벌 reservations 컬렉션)
            // 일회성 더미는 enrollment 미생성 → enrollmentId ''
            const enrollmentId = enrollmentDoc?.ref?.id ?? '';
            const sessionKey = `${courseId}_${reservedDateString}_${startTime}`;
            const reservationRef = db.collection('reservations').doc();
            tx.set(reservationRef, {
                id: reservationRef.id,
                userId,
                courseId,
                placeId,
                enrollmentId,
                dayOfWeek,
                startTime,
                reservedAt: admin.firestore.FieldValue.serverTimestamp(),
                reservedDate: admin.firestore.Timestamp.fromDate(reservedDate),
                reservedDateString: reservedDateString,
                sessionKey,
            });

            // 9.5) reservationSummary increment (읽기 이미 완료된 스냅샷 전달 → 쓰기만 수행)
            await incrementReservedCount(tx, db, {
                sessionId,
                courseId,
                placeId,
                dayOfWeek,
                startTime,
                reservedDateString,
                capacity,
            }, summarySnap);

            // 10) enrollment remainingReservations-- (pending 멤버는 pendingMembers 업데이트)
            // 일회성 더미(isOneTimeDummy)면 enrollment·pendingMembers 건드리지 않음
            if (!isOneTimeDummy) {
                if (remainingReservations <= 0) {
                    throw new functions.https.HttpsError(
                        'failed-precondition',
                        '남은 예약 횟수가 없습니다.',
                        { reason: ReservationLockReason.noCreditsOrExpired },
                    );
                }
                if (isPendingMember) {
                    if (pendingDocForUpdate && pendingDocForUpdate.exists) {
                        const courseEnrollments = (pendingDataForUpdate?.courseEnrollments as any[] | undefined) ?? [];
                        const updatedEnrollments = courseEnrollments.map((ce: any) => {
                            if (ce?.courseId === courseId) {
                                const total = Number(ce?.totalReservations ?? 0);
                                const remainingBase = Number(ce?.remainingReservations ?? total);
                                return {
                                    ...ce,
                                    remainingReservations: Math.max(0, remainingBase - 1),
                                };
                            }
                            return ce;
                        });
                        tx.update(pendingDocForUpdate.ref, { courseEnrollments: updatedEnrollments });
                    }
                } else {
                    if (enrollmentDoc) {
                        tx.update(enrollmentDoc.ref, { remainingReservations: remainingReservations - 1 });
                    }
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

            // 11) 예약 생성 성공 알림: 관리자가 일회성 예약 지정한 경우에만 전송 (일반 유저 직접 예약 시 알림 X)
            // pending 멤버(userId가 pending_xxx)는 실제 유저 문서가 없어 알림 수신 불가 → 스킵
            if (isAdminCreatingForUser && !userId.startsWith('pending_')) {
                try {
                    const courseName = await getCourseName(placeId, courseId);
                    const notificationBody = formatDateTimeKr(reservedDateString, startTime);
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: `${courseName} 예약이 완료되었습니다`,
                        body: notificationBody,
                        placeId,
                        data: {
                            reservationId: reservationRef.id,
                            courseId,
                            placeId,
                            reservedDateString,
                            dayOfWeek: String(dayOfWeek),
                            startTime,
                        },
                        isAdmin: false,
                    });
                } catch (notifErr: any) {
                    console.error(`[createReservation] 알림 전송 실패 (예약은 완료됨):`, notifErr?.message ?? notifErr);
                }
            }

            return result;
        });
    } catch (error: any) {
        logFunctionError(functionName, error as Error, { userId, courseId, reservedDateString });
        if (error instanceof functions.https.HttpsError) {
            throw error;
        }
        const msg = error?.message ?? String(error);
        console.error(`[${functionName}] Non-HttpsError (INTERNAL로 전달됨 방지):`, msg, error?.stack);
        throw new functions.https.HttpsError(
            'internal',
            `예약 생성 중 오류가 발생했습니다. ${msg || '잠시 후 다시 시도해 주세요.'}`,
        );
    }
});

/** 배치 예약 생성: 동일 세션에 여러 사용자 한 번에 추가. 관리자 전용, 폴백 없이 서버 배치만 사용. */
export const batchCreateReservations = functions.https.onCall(async (data, context) => {
    const functionName = 'batchCreateReservations';
    logFunctionStart(functionName, { userId: context.auth?.uid });

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const callerId = context.auth.uid;
    const placeId = String(data?.placeId ?? '');
    const courseId = String(data?.courseId ?? '');
    const dayOfWeek = Number(data?.dayOfWeek ?? 0);
    const startTime = String(data?.startTime ?? '');
    const reservedDateString = String(data?.reservedDateString ?? '');
    const globalForce = data?.force === true;
    const rawEntries = Array.isArray(data?.entries) ? data.entries : [];
    const entries = rawEntries
        .slice(0, 50)
        .map((e: any) => ({
            userId: String(e?.userId ?? '').trim(),
            force: e?.force === true || globalForce,
        }))
        .filter((e: { userId: string }) => e.userId.length > 0);

    if (!placeId || !courseId || !startTime || !reservedDateString || !Number.isFinite(dayOfWeek)) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId, courseId, dayOfWeek, startTime, reservedDateString이 필요합니다.');
    }

    const db = admin.firestore();
    await assertAdminForPlaceUid(callerId, placeId);
    const callerMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(callerId).get();
    const callerData = callerMemberSnap.data();
    const callerRole = String(callerData?.role ?? '').toLowerCase();
    if (callerRole === 'submanager') {
        const rawManageable = callerData?.manageableCourseIds;
        const manageableCourseIds: string[] = Array.isArray(rawManageable)
            ? (rawManageable as string[]).map((id: string) => String(id)).filter(Boolean)
            : [];
        if (manageableCourseIds.length === 0) {
            await demoteSubManagerToMemberIfNoCoursesInternal(db, placeId, callerId);
            throw new functions.https.HttpsError('permission-denied', '관리할 코스가 없습니다.');
        }
        if (!manageableCourseIds.includes(courseId)) {
            throw new functions.https.HttpsError(
                'permission-denied',
                '부매니저는 지정된 관리 코스에만 배치 예약을 생성할 수 있습니다.',
            );
        }
    }
    if (dayOfWeek < 1 || dayOfWeek > 7) {
        throw new functions.https.HttpsError('invalid-argument', 'dayOfWeek는 1-7(월-일) 사이여야 합니다.');
    }
    if (entries.length === 0) {
        return { created: [], results: [] };
    }

    const now = new Date();
    const todayString = formatDateToSeoul(now);
    const placeRef = db.collection('places').doc(placeId);

    try {
        const txResult = await db.runTransaction(async (tx) => {
            // 1) 공통: place, course, session, capacity, count, cancel, bookingWeekOpen, summary
            const placeDoc = await tx.get(placeRef);
            if (!placeDoc.exists) {
                throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
            }
            const courseRef = placeRef.collection('courses').doc(courseId);
            const courseDoc = await tx.get(courseRef);
            if (!courseDoc.exists) {
                throw new functions.https.HttpsError('not-found', '코스를 찾을 수 없습니다.');
            }
            const course = courseDoc.data()!;
            const policy = getPolicyFromCourseDoc(course, courseId, placeId);
            const session = findSession(course, dayOfWeek, startTime);
            const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
            let capacity: number;
            let isOverrideSession = false;
            let newEndTime: string;

            if (!session) {
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
                isOverrideSession = true;
                newEndTime = String(overrideData?.endTime ?? startTime);
            } else {
                newEndTime = String(session.endTime ?? startTime);
                // 정원 오버라이드: 단일 소스 sessionId_date만 사용 (레거시 _cap 제거)
                const capDocId = `${sessionId}_${reservedDateString}`;
                const capDoc = await tx.get(db.collection('courseOverrides').doc(capDocId));
                const overrideCap = capDoc.exists ? Number((capDoc.data() as any)?.capacity) : undefined;
                capacity = Number.isFinite(overrideCap) ? (overrideCap as number) : Number(session.capacity ?? 0);
            }

            // reservedCount = reservationSummary에서 가져오기 (단일 소스, 클라이언트와 동일)
            const summaryRef = db.collection('reservationSummary').doc(`${sessionId}_${reservedDateString}`);
            const summarySnap = await tx.get(summaryRef);
            let currentReservedCount = summarySnap.exists ? Number((summarySnap.data() as any)?.reservedCount ?? 0) : 0;

            const cancelOverrideQuery = db
                .collection('courseOverrides')
                .where('placeId', '==', placeId)
                .where('courseId', '==', courseId)
                .where('date', '==', reservedDateString)
                .where('dayOfWeek', '==', dayOfWeek)
                .where('startTime', '==', startTime)
                .where('isCancelled', '==', true)
                .limit(1);
            const cancelSnap = await tx.get(cancelOverrideQuery as any);
            if (!cancelSnap.empty) {
                const addOverrideQuery = db
                    .collection('courseOverrides')
                    .where('placeId', '==', placeId)
                    .where('courseId', '==', courseId)
                    .where('date', '==', reservedDateString)
                    .where('dayOfWeek', '==', dayOfWeek)
                    .where('startTime', '==', startTime)
                    .where('isCancelled', '==', false)
                    .limit(1);
                const addSnap = await tx.get(addOverrideQuery as any);
                if (addSnap.empty) {
                    throw new functions.https.HttpsError('failed-precondition', '취소된 세션입니다.');
                }
            }

            const reservedDate = seoulDateOnly(reservedDateString);
            const weekStart = startOfWeekMondaySeoul(reservedDateString);
            const weekStartDateString = formatDateToSeoul(weekStart);
            const bookingWeekOpenDocId = `${placeId}_${courseId}_${weekStartDateString}`;
            const bookingWeekOpenDoc = await tx.get(db.collection('bookingWeekOpens').doc(bookingWeekOpenDocId));
            const isBookingWeekOpened = bookingWeekOpenDoc.exists;

            // reservationSummary는 이미 위에서 읽음 (중복 읽기 제거)

            const courseCache = new Map<string, any>();
            courseCache.set(courseId, course);

            type ToAddEntry = {
                userId: string;
                enrollmentId: string;
                enrollmentDoc: admin.firestore.QueryDocumentSnapshot | null;
                pendingDocForUpdate: admin.firestore.DocumentSnapshot | null;
                pendingDataForUpdate: any;
                remainingReservations: number;
                isOneTimeDummy: boolean;
            };
            const toAdd: ToAddEntry[] = [];

            for (const entry of entries) {
                const userId = entry.userId;
                const isPendingMember = userId.startsWith('pending_');
                let remainingReservations: number;
                let validFrom: Date;
                let validUntil: Date;
                let enrollmentDoc: admin.firestore.QueryDocumentSnapshot | null = null;
                let isOneTimeDummy = false;
                let pendingDocForUpdate: admin.firestore.DocumentSnapshot | null = null;
                let pendingDataForUpdate: any = null;

                if (isPendingMember) {
                    const pendingId = userId.replace('pending_', '');
                    const pendingRef = db.collection('places').doc(placeId).collection('pendingMembers').doc(pendingId);
                    const pendingDoc = await tx.get(pendingRef);
                    if (!pendingDoc.exists) continue;
                    const pendingData = pendingDoc.data() as any;
                    pendingDocForUpdate = pendingDoc;
                    pendingDataForUpdate = pendingData;
                    const courseEnrollments = pendingData?.courseEnrollments as any[] | undefined;
                    const allowedIds = Array.isArray(pendingData?.allowedCourseIds) ? (pendingData.allowedCourseIds as string[]) : null;
                    const courseEnrollment = courseEnrollments?.find((ce: any) => ce?.courseId === courseId);
                    if (!courseEnrollment && !allowedIds?.includes(courseId)) continue;
                    const totalReservations = Number(courseEnrollment?.totalReservations ?? 10);
                    remainingReservations = Number(courseEnrollment?.remainingReservations ?? totalReservations);
                    const validFromRaw = courseEnrollment?.validFrom ?? null;
                    const validUntilRaw = courseEnrollment?.validUntil ?? null;
                    const createdAtRaw = pendingData?.createdAt;
                    const createdAtDate = (createdAtRaw instanceof admin.firestore.Timestamp) ? createdAtRaw.toDate() : (typeof createdAtRaw === 'string') ? new Date(createdAtRaw) : (createdAtRaw instanceof Date) ? createdAtRaw : new Date(0);
                    validFrom = validFromRaw instanceof admin.firestore.Timestamp ? validFromRaw.toDate() : (typeof validFromRaw === 'string') ? new Date(validFromRaw) : createdAtDate;
                    validUntil = validUntilRaw instanceof admin.firestore.Timestamp ? validUntilRaw.toDate() : (typeof validUntilRaw === 'string') ? new Date(validUntilRaw) : (() => { const d = new Date(createdAtDate); d.setFullYear(d.getFullYear() + 1); return d; })();
                } else {
                    const enrollmentQuery = db.collection('enrollments').where('userId', '==', userId).where('courseId', '==', courseId).limit(1);
                    const enrollmentSnap = await tx.get(enrollmentQuery as any);
                    if (enrollmentSnap.empty) continue;
                    enrollmentDoc = enrollmentSnap.docs[0] as admin.firestore.QueryDocumentSnapshot;
                    const enrollmentData = enrollmentDoc.data() as any;
                    remainingReservations = Number(enrollmentData?.remainingReservations ?? 0);
                    validFrom = (enrollmentData?.validFrom instanceof admin.firestore.Timestamp) ? enrollmentData.validFrom.toDate() : (enrollmentData?.validFrom ? new Date(enrollmentData.validFrom) : new Date(0));
                    validUntil = (enrollmentData?.validUntil instanceof admin.firestore.Timestamp) ? enrollmentData.validUntil.toDate() : (enrollmentData?.validUntil ? new Date(enrollmentData.validUntil) : new Date(0));
                }

                const today = seoulDateOnly(todayString);
                const validFromString = formatDateToSeoul(validFrom);
                const validUntilString = formatDateToSeoul(validUntil);
                const validFromDate = seoulDateOnly(validFromString);
                const validUntilDate = seoulDateOnly(validUntilString);
                let enrollmentCanReserve = today >= validFromDate && today <= validUntilDate && remainingReservations > 0;
                if (isOneTimeDummy) enrollmentCanReserve = true;

                const dupQuery = db.collection('reservations')
                    .where('placeId', '==', placeId).where('userId', '==', userId)
                    .where('courseId', '==', courseId).where('dayOfWeek', '==', dayOfWeek)
                    .where('startTime', '==', startTime).where('reservedDateString', '==', reservedDateString).limit(1);
                const dupSnap = await tx.get(dupQuery as any);
                if (!dupSnap.empty) continue;

                const overlapQuery = db.collection('reservations')
                    .where('placeId', '==', placeId).where('userId', '==', userId).where('reservedDateString', '==', reservedDateString);
                const overlapSnap = await tx.get(overlapQuery as any);
                let hasOverlap = false;
                for (const doc of overlapSnap.docs) {
                    const r = doc.data() as any;
                    const rCourseId = String(r?.courseId ?? '');
                    if (rCourseId === courseId) continue;
                    let rDay = Number(r?.dayOfWeek ?? 0);
                    if (rDay < 1 || rDay > 7) rDay = seoulWeekday1to7(reservedDateString);
                    const rStart = String(r?.startTime ?? '');
                    let rEnd: string;
                    let rCourse = courseCache.get(rCourseId);
                    if (!rCourse) {
                        const rCourseDoc = await tx.get(placeRef.collection('courses').doc(rCourseId));
                        rCourse = rCourseDoc.exists ? rCourseDoc.data() : null;
                        courseCache.set(rCourseId, rCourse);
                    }
                    const rSession = rCourse ? findSession(rCourse, rDay, rStart) : null;
                    if (rSession) rEnd = String(rSession.endTime ?? rStart);
                    else {
                        const ovQuery = db.collection('courseOverrides').where('courseId', '==', rCourseId).where('placeId', '==', placeId).where('date', '==', reservedDateString).where('dayOfWeek', '==', rDay).where('startTime', '==', rStart).where('isCancelled', '==', false).limit(1);
                        const ovSnap = await tx.get(ovQuery as any);
                        const ovData = !ovSnap.empty ? (ovSnap.docs[0].data() as any) : null;
                        rEnd = ovData ? String(ovData.endTime ?? rStart) : rStart;
                    }
                    if (doTimesOverlap(startTime, newEndTime, rStart, rEnd)) { hasOverlap = true; break; }
                }
                if (hasOverlap) continue;

                // 관리자 추가 시 force이면 제한사유 조사 없이 강제 추가
                if (!entry.force) {
                    const reservedCountForEligibility = currentReservedCount + toAdd.length;
                    const eligibility = evaluateReservation({
                        now,
                        policy,
                        sessionDateString: reservedDateString,
                        startTime,
                        capacity,
                        reservedCount: reservedCountForEligibility,
                        enrollmentCanReserve,
                        skipOpenPolicy: isOverrideSession || isBookingWeekOpened,
                        isBookingWeekOpened,
                    });

                    if (!eligibility.canReserve) {
                        if (eligibility.reason === ReservationLockReason.pastDate) continue;
                        if (eligibility.reason === ReservationLockReason.noCreditsOrExpired) continue;
                        const forceableReasons = new Set([ReservationLockReason.full, ReservationLockReason.closedBeforeStart, ReservationLockReason.notOpenedYet]);
                        if (forceableReasons.has(eligibility.reason as any)) {
                            throwRequiresForce({
                                reason: eligibility.reason,
                                openAt: eligibility.openAt ? eligibility.openAt.toISOString() : null,
                                capacity,
                                reservedCount: currentReservedCount + toAdd.length,
                                closeBeforeMinutes: policy.closeBeforeMinutes ?? 60,
                            });
                        } else continue;
                    }

                    if (!isOneTimeDummy && remainingReservations <= 0) continue;
                }

                toAdd.push({
                    userId,
                    enrollmentId: enrollmentDoc?.ref?.id ?? '',
                    enrollmentDoc,
                    pendingDocForUpdate,
                    pendingDataForUpdate,
                    remainingReservations,
                    isOneTimeDummy,
                });
            }

            const created: Array<{ id: string; userId: string }> = [];
            const sessionKey = `${courseId}_${reservedDateString}_${startTime}`;

            for (const item of toAdd) {
                const reservationRef = db.collection('reservations').doc();
                tx.set(reservationRef, {
                    id: reservationRef.id,
                    userId: item.userId,
                    courseId,
                    placeId,
                    enrollmentId: item.enrollmentId,
                    dayOfWeek,
                    startTime,
                    reservedAt: admin.firestore.FieldValue.serverTimestamp(),
                    reservedDate: admin.firestore.Timestamp.fromDate(reservedDate),
                    reservedDateString,
                    sessionKey,
                });
                created.push({ id: reservationRef.id, userId: item.userId });

                if (!item.isOneTimeDummy) {
                    if (item.pendingDocForUpdate?.exists) {
                        const courseEnrollments = ((item.pendingDataForUpdate?.courseEnrollments) as any[] | undefined) ?? [];
                        const updated = courseEnrollments.map((ce: any) => {
                            if (ce?.courseId === courseId) {
                                const total = Number(ce?.totalReservations ?? 0);
                                const remainingBase = Number(ce?.remainingReservations ?? total);
                                return { ...ce, remainingReservations: Math.max(0, remainingBase - 1) };
                            }
                            return ce;
                        });
                        tx.update(item.pendingDocForUpdate.ref, { courseEnrollments: updated });
                    } else if (item.enrollmentDoc) {
                        tx.update(item.enrollmentDoc.ref, { remainingReservations: item.remainingReservations - 1 });
                    }
                }
            }

            if (toAdd.length > 0) {
                await incrementReservedCountBy(tx, db, {
                    sessionId,
                    courseId,
                    placeId,
                    dayOfWeek,
                    startTime,
                    reservedDateString,
                    capacity,
                }, toAdd.length, summarySnap);
            }

            return { created };
        });

        const created = (txResult as { created: Array<{ id: string; userId: string }> }).created;
        for (const c of created) {
            if (c.userId.startsWith('pending_')) continue;
            try {
                const courseName = await getCourseName(placeId, courseId);
                const notificationBody = formatDateTimeKr(reservedDateString, startTime);
                await createNotification({
                    userId: c.userId,
                    type: 'reservation',
                    title: `${courseName} 예약이 완료되었습니다`,
                    body: notificationBody,
                    placeId,
                    data: { reservationId: c.id, courseId, placeId, reservedDateString, dayOfWeek: String(dayOfWeek), startTime },
                    isAdmin: false,
                });
            } catch (err: any) {
                console.error(`[batchCreateReservations] 알림 실패:`, err?.message ?? err);
            }
        }

        logFunctionSuccess(functionName, { createdCount: created.length, placeId, courseId, reservedDateString });
        const results = created.map((c) => ({ id: c.id, userId: c.userId, success: true }));
        return { created, results };
    } catch (error: any) {
        logFunctionError(functionName, error as Error, { placeId, courseId, reservedDateString });
        if (error instanceof functions.https.HttpsError) throw error;
        throw new functions.https.HttpsError('internal', `배치 예약 생성 중 오류가 발생했습니다. ${error?.message ?? '잠시 후 다시 시도해 주세요.'}`);
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
    const callerMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(callerId).get();
    const callerData = callerMemberSnap.data();
    const callerRole = String(callerData?.role ?? '').toLowerCase();
    if (callerRole === 'submanager') {
        const rawManageable = callerData?.manageableCourseIds;
        const manageableCourseIds: string[] = Array.isArray(rawManageable)
            ? (rawManageable as string[]).map((id: string) => String(id)).filter(Boolean)
            : [];
        if (manageableCourseIds.length === 0) {
            await demoteSubManagerToMemberIfNoCoursesInternal(db, placeId, callerId);
            throw new functions.https.HttpsError('permission-denied', '관리할 코스가 없습니다.');
        }
        if (!manageableCourseIds.includes(courseId)) {
            throw new functions.https.HttpsError(
                'permission-denied',
                '부매니저는 지정된 관리 코스의 수강만 취소할 수 있습니다.',
            );
        }
    }

    const realNow = new Date();
    const todayString = formatDateToSeoul(realNow);

    // 코스명 조회 (UI 경고/알림에 "코스명 그대로" 쓰기 위해)
    const courseName = await getCourseName(placeId, courseId);

    // 미래 예약 조회 (글로벌 reservations, 오늘 포함)
    const reservationsSnap = await db
        .collection('reservations')
        .where('placeId', '==', placeId)
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
        return realNow.getTime() < sessionStart.getTime();
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

    // enrollment 삭제 전에 서브컬렉션 삭제 (고아 문서 방지)
    const actionHistoryRef = enrollmentDoc.ref.collection('actionHistory');
    const deletedHistory = await deleteByQuery(db, actionHistoryRef);
    if (deletedHistory > 0) {
        console.log(`[${functionName}] Deleted actionHistory subcollection: ${deletedHistory} docs`);
    }
    const extensionRequestsRef = enrollmentDoc.ref.collection('extensionRequests');
    const deletedExtensions = await deleteByQuery(db, extensionRequestsRef);
    if (deletedExtensions > 0) {
        console.log(`[${functionName}] Deleted extensionRequests subcollection: ${deletedExtensions} docs`);
    }

    // 트랜잭션: 예약 삭제 + enrollment 삭제 (reservations 컬렉션만 사용)
    await db.runTransaction(async (tx) => {
        for (const doc of toCancel) {
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
 * - enrollments 삭제 (userId + placeId)
 * - reservations 글로벌 컬렉션 중 해당 placeId+userId 예약 삭제
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

    // place 단위 관리자만 가능 (멤버 제거는 매니저/소유자만 — 부매니저 불가)
    await assertAdminForPlaceUid(callerId, placeId);

    const db = admin.firestore();
    const callerMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(callerId).get();
    const callerData = callerMemberSnap.data();
    const callerRole = String(callerData?.role ?? '').toLowerCase();
    if (callerRole === 'submanager') {
        throw new functions.https.HttpsError(
            'permission-denied',
            '플레이스에서 멤버를 제거할 수 있는 권한은 매니저에게만 있습니다.',
        );
    }

    // 매니저/부매니저/플레이스 소유자는 제거 불가 (일반 멤버만 제거 가능)
    const placeDoc = await db.collection('places').doc(placeId).get();
    if (!placeDoc.exists) {
        throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
    }
    const placeData = placeDoc.data() as any;
    const placeAdminId = placeData?.adminId ? String(placeData.adminId) : '';
    if (placeAdminId && targetUserId === placeAdminId) {
        logFunctionError(functionName, new Error('Cannot remove place owner'), { placeId, targetUserId });
        throw new functions.https.HttpsError(
            'failed-precondition',
            '플레이스 소유자는 제거할 수 없습니다.',
        );
    }
    const memberRef = db.collection('places').doc(placeId).collection('members').doc(targetUserId);
    const memberDoc = await memberRef.get();
    if (memberDoc.exists) {
        const memberData = memberDoc.data() as any;
        const role = String(memberData?.role ?? 'member');
        if (role === 'manager' || role === 'submanager') {
            logFunctionError(functionName, new Error('Cannot remove manager/submanager'), { placeId, targetUserId, role });
            throw new functions.https.HttpsError(
                'failed-precondition',
                '매니저·부매니저는 제거할 수 없습니다. 일반 멤버만 제거 가능합니다.',
            );
        }
    }

    try {
        // 1) enrollments 삭제 (userId + placeId). 서브컬렉션 actionHistory 먼저 삭제 후 enrollment 삭제.
        // firestore.indexes.json: enrollments (userId, placeId) 복합 인덱스 필요
        let deletedEnrollments = 0;
        let enrollmentSnap: FirebaseFirestore.QuerySnapshot;
        try {
            enrollmentSnap = await db
                .collection('enrollments')
                .where('userId', '==', targetUserId)
                .where('placeId', '==', placeId)
                .get();
        } catch (e: any) {
            console.error(`[${functionName}] enrollments 쿼리 실패:`, e?.message ?? e);
            throw e;
        }
        const enrollmentDocs = enrollmentSnap.docs;
        const batchSize = 400;
        for (let i = 0; i < enrollmentDocs.length; i += batchSize) {
            const chunk = enrollmentDocs.slice(i, i + batchSize);
            for (const doc of chunk) {
                const nAction = await deleteByQuery(db, doc.ref.collection('actionHistory'));
                if (nAction > 0) {
                    console.log(`[${functionName}] Deleted actionHistory for enrollment ${doc.id}: ${nAction} docs`);
                }
                const nExt = await deleteByQuery(db, doc.ref.collection('extensionRequests'));
                if (nExt > 0) {
                    console.log(`[${functionName}] Deleted extensionRequests for enrollment ${doc.id}: ${nExt} docs`);
                }
            }
            const batch = db.batch();
            chunk.forEach((d) => batch.delete(d.ref));
            await batch.commit();
            deletedEnrollments += chunk.length;
        }
        const deletedCourseMembers = 0; // courseMembers 미사용

        // 2) reservations 삭제 (글로벌 reservations 컬렉션만 사용). firestore.indexes.json: reservations (placeId, userId) 복합 인덱스 필요
        let reservationsSnap: FirebaseFirestore.QuerySnapshot;
        try {
            reservationsSnap = await db
                .collection('reservations')
                .where('placeId', '==', placeId)
                .where('userId', '==', targetUserId)
                .get();
        } catch (e: any) {
            console.error(`[${functionName}] reservations 쿼리 실패:`, e?.message ?? e);
            throw e;
        }

        let deletedReservations = 0;
        if (!reservationsSnap.empty) {
            const docs = reservationsSnap.docs;
            const chunkSize = 400;
            for (let i = 0; i < docs.length; i += chunkSize) {
                const chunk = docs.slice(i, i + chunkSize);
                const batch = db.batch();
                chunk.forEach((d) => batch.delete(d.ref));
                await batch.commit();
                deletedReservations += chunk.length;
            }
        }

        // 3) pendingMembers 삭제 (있으면)
        const phoneDigits = phoneNumberRaw.replace(/[^\d]/g, '');
        let deletedPending = 0;
        if (phoneDigits) {
            const pendingId = `${placeId}_${phoneDigits}`;
            const pendingRef = db.collection('places').doc(placeId).collection('pendingMembers').doc(pendingId);
            const pendingDoc = await pendingRef.get();
            if (pendingDoc.exists) {
                await pendingRef.delete();
                deletedPending = 1;
            }
        }

        // 4) places/{placeId}/members/{userId} 삭제 → 멤버 목록에서 제거 (memberRef/memberDoc은 위에서 이미 조회됨)
        let deletedMember = 0;
        if (memberDoc.exists) {
            await memberRef.delete();
            deletedMember = 1;
        }

        // 5) users/{userId}/notifications 중 해당 placeId 알림만 삭제 (추방된 플레이스 알림 정리)
        let deletedNotifications = 0;
        try {
            const notificationsRef = db.collection('users').doc(targetUserId).collection('notifications');
            deletedNotifications = await deleteByQuery(
                db,
                notificationsRef.where('placeId', '==', placeId),
            );
        } catch (notifErr: any) {
            const msg = notifErr?.message ?? String(notifErr);
            if (msg.includes('FAILED_PRECONDITION') || notifErr?.code === 9) {
                console.warn(`[${functionName}] notifications 삭제 스킵 (인덱스 없음): placeId=${placeId}, userId=${targetUserId}`);
            } else {
                throw notifErr;
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
            deletedMember,
            deletedNotifications,
        });

        return {
            success: true,
            deletedEnrollments,
            deletedCourseMembers,
            deletedReservations,
            deletedPending,
            deletedMember,
            deletedNotifications,
        };
    } catch (err: any) {
        const code = err?.code ?? err?.status ?? 0;
        const message = err?.message ?? String(err);
        // Firestore 인덱스 오류 시 상세 메시지(인덱스 링크 등)를 로그에 남김
        if (code === 9 || message.includes('FAILED_PRECONDITION')) {
            console.error(`[${functionName}] FAILED_PRECONDITION 상세:`, message);
            logFunctionError(functionName, err as Error, { placeId, targetUserId });
            throw new functions.https.HttpsError(
                'failed-precondition',
                '쿼리 실행에 필요한 인덱스가 없거나 조건이 맞지 않습니다. Firebase Console에서 인덱스를 확인해 주세요.',
            );
        }
        logFunctionError(functionName, err as Error, { placeId, targetUserId });
        throw err;
    }
});

/**
 * 코스 일정(세션 템플릿) 업데이트 (관리자)
 *
 * 목표: "예약이 있는 세션은 삭제/시간변경 불가"를 서버에서 강제
 * - 삭제/변경 대상 세션에 미래 예약(reservations 컬렉션에 해당 세션·날짜 문서 존재)이 있으면 실패
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
    const callerMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(callerId).get();
    const callerData = callerMemberSnap.data();
    const callerRole = String(callerData?.role ?? '').toLowerCase();
    if (callerRole === 'submanager') {
        const rawManageable = callerData?.manageableCourseIds;
        const manageableCourseIds: string[] = Array.isArray(rawManageable)
            ? (rawManageable as string[]).map((id: string) => String(id)).filter(Boolean)
            : [];
        if (manageableCourseIds.length === 0) {
            await demoteSubManagerToMemberIfNoCoursesInternal(db, placeId, callerId);
            throw new functions.https.HttpsError('permission-denied', '관리할 코스가 없습니다.');
        }
        if (!manageableCourseIds.includes(courseId)) {
            throw new functions.https.HttpsError(
                'permission-denied',
                '부매니저는 지정된 관리 코스의 일정만 편집할 수 있습니다.',
            );
        }
    }

    const realNow = new Date();
    const todayString = formatDateToSeoul(realNow);

    // 코스 조회 (서브컬렉션)
    const course = await getCourseOrThrow(placeId, courseId);
    const courseName = getCourseNameFromCourse(course);

    // 기존 세션 맵(키: day_start)
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

    // 비정기 세션(courseOverrides)과 정기 세션 겹침 검사
    // 이미 등록된 비정기(날짜별) 세션이 있는 요일/시간대에 정기 세션이 겹치면 저장 차단
    const overridesSnap = await db
        .collection('courseOverrides')
        .where('placeId', '==', placeId)
        .where('courseId', '==', courseId)
        .where('isCancelled', '==', false)
        .get();
    for (const doc of overridesSnap.docs) {
        const o = doc.data() as any;
        const oDate = String(o?.date ?? '');
        const oDay = Number(o?.dayOfWeek ?? 0);
        const oStart = String(o?.startTime ?? '').trim();
        const oEnd = String(o?.endTime ?? '').trim();
        if (!oDate || oDay < 1 || oDay > 7 || !oStart || !oEnd) continue;
        let oStartMin: number, oEndMin: number;
        try {
            const pStart = parseHHmm(oStart);
            const pEnd = parseHHmm(oEnd);
            oStartMin = pStart.h * 60 + pStart.m;
            oEndMin = pEnd.h * 60 + pEnd.m;
        } catch {
            continue;
        }
        const regularList = byDay.get(oDay) ?? [];
        for (const r of regularList) {
            const rStart = parseHHmm(String(r.startTime));
            const rEnd = parseHHmm(String(r.endTime));
            const rStartMin = rStart.h * 60 + rStart.m;
            const rEndMin = rEnd.h * 60 + rEnd.m;
            if (rStartMin < oEndMin && rEndMin > oStartMin) {
                throw new functions.https.HttpsError(
                    'failed-precondition',
                    `정기 일정이 비정기 일정과 겹칩니다. 비정기 일정 날짜: ${oDate}, 시간: ${oStart}~${oEnd}. 해당 날짜의 비정기 일정을 먼저 수정·삭제한 뒤 저장해 주세요.`,
                );
            }
        }
    }

    // 삭제/변경된 세션에 미래 예약이 있으면 차단
    const removedKeys: string[] = [];
    const modifiedKeys: string[] = [];

    for (const key of oldMap.keys()) {
        if (!newMap.has(key)) removedKeys.push(key);
    }
    // 변경 구분: (1) 삭제 (2) 시간 변경 (3) 정원 변경 - 정원 변경은 예약 있어도 허용(기존 예약 유지)
    for (const key of newMap.keys()) {
        if (!oldMap.has(key)) continue;
        const oldS = oldMap.get(key);
        const newS = newMap.get(key);
        const oldEnd = String((oldS as any)?.endTime ?? '');
        const newEnd = String(newS.endTime);
        const oldCap = Number((oldS as any)?.capacity ?? 0);
        const newCap = Number(newS.capacity);
        if (oldEnd !== newEnd || oldCap !== newCap) {
            modifiedKeys.push(key);
        }
    }

    async function hasFutureReservationsForSessionKey(key: string): Promise<boolean> {
        const [dStr, st] = key.split('_');
        const d = Number(dStr);
        const q = db
            .collection('reservations')
            .where('placeId', '==', placeId)
            .where('courseId', '==', courseId)
            .where('dayOfWeek', '==', d)
            .where('startTime', '==', st)
            .where('reservedDateString', '>=', todayString)
            .limit(1);
        const snap = await q.get();
        return !snap.empty;
    }

    // 삭제: 예약 있으면 무조건 차단 → 일괄 취소 유도
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
    // 정원 변경 / 시간 변경(modify): 예약이 있어도 차단하지 않음. 허용 후 place만 업데이트.
    // (modifiedKeys에 대해 throw 하지 않음. 기존 예약 유지, 새 정원은 이후 예약부터 적용.)

    // 코스 문서 업데이트 (서브컬렉션 places/{placeId}/courses/{courseId} 의 sessions만 교체)
    const courseRef = db.collection('places').doc(placeId).collection('courses').doc(courseId);
    await courseRef.update({
        sessions: Array.from(newMap.values()),
    });

    // 매니저·코스매니저에게 정기 일정 변경 푸시 알림 (변경한 사람 제외)
    try {
        const adminUids = await getManagerUidsForPlaceAndCourse(placeId, courseId);
        for (const uid of adminUids) {
            if (uid === callerId) continue;
            await createNotification({
                userId: uid,
                type: 'system',
                title: '정기 일정 변경',
                body: `${courseName ?? '코스'} 정기 일정이 변경되었습니다`,
                placeId,
                data: { courseId, placeId, kind: 'schedule-update' },
                isAdmin: true,
            });
        }
    } catch (notifErr: any) {
        console.error(`[updateCourseSchedule] 관리자 알림 전송 실패:`, notifErr?.message ?? notifErr);
    }

    logFunctionSuccess(functionName, { callerId, placeId, courseId, removed: removedKeys.length, modified: modifiedKeys.length });
    return { success: true, courseName };
});

/**
 * 코스 삭제 (관리자, 서버 단일 진실)
 *
 * 요구사항:
 * - 코스를 places/{placeId}.courses 에서 제거
 * - 관련 데이터(예약/세션카운트/오버라이드/정책/주차오픈/멤버데이터)를 모두 정리
 * - 미래 예약이 남아있으면 cascade=false일 때 requiresCascade로 차단
 *
 * 주의:
 * - 대량 데이터 대비: batch + pagination
 * - 예약 트리거는 no-op이므로 서버에서 직접 reservations 삭제
 */
export const deleteCourse = functions.https.onCall(async (data, context) => {
    const functionName = 'deleteCourse';
    logFunctionStart(functionName, { userId: context.auth?.uid, ...data });

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const callerId = context.auth.uid;
    const placeId = String(data?.placeId ?? '');
    const courseId = String(data?.courseId ?? '');
    const cascade = data?.cascade === true;

    if (!placeId || !courseId) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId, courseId가 필요합니다.');
    }

    await assertAdminForPlaceUid(callerId, placeId);

    const db = admin.firestore();
    const callerMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(callerId).get();
    const callerData = callerMemberSnap.data();
    const callerRole = String(callerData?.role ?? '').toLowerCase();
    if (callerRole === 'submanager') {
        const rawManageable = callerData?.manageableCourseIds;
        const manageableCourseIds: string[] = Array.isArray(rawManageable)
            ? (rawManageable as string[]).map((id: string) => String(id)).filter(Boolean)
            : [];
        if (manageableCourseIds.length === 0) {
            await demoteSubManagerToMemberIfNoCoursesInternal(db, placeId, callerId);
            throw new functions.https.HttpsError('permission-denied', '관리할 코스가 없습니다.');
        }
        if (!manageableCourseIds.includes(courseId)) {
            throw new functions.https.HttpsError(
                'permission-denied',
                '부매니저는 지정된 관리 코스만 삭제할 수 있습니다.',
            );
        }
    }

    const realNow = new Date();
    const todayString = formatDateToSeoul(realNow);

    // 0) place + course 확인 (코스는 서브컬렉션)
    const placeDoc = await db.collection('places').doc(placeId).get();
    if (!placeDoc.exists) {
        throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
    }
    const course = await getCourseOrThrow(placeId, courseId);
    const courseName = getCourseNameFromCourse(course);

    // 1) 미래 예약 존재 확인 (cascade=false면 차단) — 글로벌 reservations
    const futureQuery = db
        .collection('reservations')
        .where('placeId', '==', placeId)
        .where('courseId', '==', courseId)
        .where('reservedDateString', '>=', todayString)
        .orderBy('reservedDateString')
        .limit(500);

    let cancellableFutureCount = 0;
    let lastFutureDoc: FirebaseFirestore.QueryDocumentSnapshot | null = null;
    const futureUserCounts = new Map<string, number>(); // userId -> cancellable count

    while (true) {
        let q: FirebaseFirestore.Query = futureQuery;
        if (lastFutureDoc) q = q.startAfter(lastFutureDoc);
        const snap = await q.get();
        if (snap.empty) break;

        for (const d of snap.docs) {
            const r = d.data() as any;
            const dateStr = String(r?.reservedDateString ?? '');
            const startTime = String(r?.startTime ?? '');
            const uid = String(r?.userId ?? '');
            if (!dateStr || !startTime || !uid) continue;
            try {
                const { y, mo, d: dd } = parseYYYYMMDD(dateStr);
                const { h, m } = parseHHmm(startTime);
                const sessionStart = makeSeoulDateTime(y, mo, dd, h, m);
                if (realNow.getTime() < sessionStart.getTime()) {
                    cancellableFutureCount++;
                    futureUserCounts.set(uid, (futureUserCounts.get(uid) ?? 0) + 1);
                }
            } catch {
                // 날짜/시간 형식 오류는 무시(삭제 진행 시에도 결국 문서 삭제로 정리)
            }
        }

        if (snap.docs.length < 500) break;
        lastFutureDoc = snap.docs[snap.docs.length - 1];
    }

    if (cancellableFutureCount > 0 && !cascade) {
        // UI가 확인 후 cascade=true로 재호출할 수 있도록 상세 정보 반환
        throwRequiresCascadeDeleteCourse({
            courseId,
            courseName,
            reservationCount: cancellableFutureCount,
        });
    }

    const courseRef = db.collection('places').doc(placeId).collection('courses').doc(courseId);

    // 2) 예약(reservations)은 삭제하지 않음 — 이력 보존
    const deletedReservations = 0;

    // 3.5) reservationSummary 정리 (코스 삭제 시 해당 코스의 집계 문서 일괄 삭제)
    const deletedSummaries = await deleteSummariesForCourse(db, placeId, courseId);

    // 4) courseOverrides (add/cancel/capacity) / bookingWeekOpens 정리
    const deletedCourseOverrides = await deleteByQuery(
        db,
        db.collection('courseOverrides').where('placeId', '==', placeId).where('courseId', '==', courseId),
    );
    const deletedBookingWeekOpens = await deleteByQuery(
        db,
        db.collection('bookingWeekOpens').where('placeId', '==', placeId).where('courseId', '==', courseId),
    );

    // 6) enrollments 정리 (서브컬렉션 actionHistory/extensionRequests 먼저 삭제 후 문서 삭제)
    const deletedEnrollments = await deleteEnrollmentsWithSubcollections(
        db,
        db.collection('enrollments').where('placeId', '==', placeId).where('courseId', '==', courseId),
    );
    const deletedCourseMembers = 0;

    // 7) places/{placeId}/pendingMembers에서 해당 course 제거 (allowedCourseIds)
    let updatedPendingMembers = 0;
    let lastPendingDoc: FirebaseFirestore.QueryDocumentSnapshot | null = null;
    const pendingPageSize = 300;
    const pendingCollRef = db.collection('places').doc(placeId).collection('pendingMembers');
    while (true) {
        let q: FirebaseFirestore.Query = pendingCollRef.orderBy(admin.firestore.FieldPath.documentId()).limit(pendingPageSize);
        if (lastPendingDoc) q = q.startAfter(lastPendingDoc);
        const snap = await q.get();
        if (snap.empty) break;

        const batch = db.batch();
        let wrote = 0;
        for (const d of snap.docs) {
            const p = d.data() as any;
            const beforeAllowed = Array.isArray(p?.allowedCourseIds) ? (p.allowedCourseIds as string[]) : [];
            const beforeCourseIds = Array.isArray(p?.courseIds) ? (p.courseIds as string[]) : [];
            const beforeEnrollments = Array.isArray(p?.courseEnrollments) ? (p.courseEnrollments as any[]) : [];

            let changed = false;
            const nextAllowed = beforeAllowed.filter((x) => String(x ?? '') !== courseId);
            const nextCourseIds = beforeCourseIds.filter((x) => String(x ?? '') !== courseId);
            const nextEnrollments = beforeEnrollments.filter((ce) => String((ce as any)?.courseId ?? '') !== courseId);

            if (nextAllowed.length !== beforeAllowed.length) { changed = true; }
            if (nextCourseIds.length !== beforeCourseIds.length) { changed = true; }
            if (nextEnrollments.length !== beforeEnrollments.length) { changed = true; }

            if (changed) {
                const update: any = {};
                if (nextAllowed.length !== beforeAllowed.length) update.allowedCourseIds = nextAllowed;
                if (nextCourseIds.length !== beforeCourseIds.length) update.courseIds = nextCourseIds;
                if (nextEnrollments.length !== beforeEnrollments.length) update.courseEnrollments = nextEnrollments;
                batch.update(d.ref, update);
                wrote++;
            }
        }
        if (wrote > 0) {
            await batch.commit();
            updatedPendingMembers += wrote;
        }

        if (snap.docs.length < pendingPageSize) break;
        lastPendingDoc = snap.docs[snap.docs.length - 1];
    }

    // 8) coursePolicies 정리 (courseId docId, placeId가 일치할 때만 삭제)
    let deletedCoursePolicy = false;
    const policyRef = db.collection('coursePolicies').doc(courseId);
    const policySnap = await policyRef.get();
    if (policySnap.exists) {
        const policyData = policySnap.data() as any;
        const policyPlaceId =
            String(policyData?.placeId ?? policyData?.active?.placeId ?? policyData?.scheduled?.placeId ?? '');
        if (policyPlaceId === placeId) {
            await policyRef.delete();
            deletedCoursePolicy = true;
        }
    }

    // 2') 코스 문서 삭제 — 정리(예약/집계/오버라이드/등록/정책 등) 완료 후 수행해 고아 데이터 방지
    await courseRef.delete();

    // 8.5) 부매니저: 해당 코스 제거, 관리 코스 0개면 일반 멤버로 전락
    const membersSnap = await db.collection('places').doc(placeId).collection('members').get();
    let demotedSubManagers = 0;
    for (const doc of membersSnap.docs) {
        const d = doc.data() as any;
        const role = String(d?.role ?? '').toLowerCase();
        if (role !== 'submanager') continue;
        const before = Array.isArray(d?.manageableCourseIds) ? (d.manageableCourseIds as string[]) : [];
        const next = before.filter((id: string) => String(id ?? '') !== courseId);
        if (next.length === before.length) continue;
        const update: any = { updatedAt: admin.firestore.Timestamp.now() };
        if (next.length === 0) {
            update.role = 'member';
            update.manageableCourseIds = [];
            demotedSubManagers++;
        } else {
            update.manageableCourseIds = next;
        }
        await doc.ref.update(update);
    }

    // 9) 알림: 해당 코스에 미래 예약이 있던 사용자에게 코스 삭제 안내 (예약 문서는 삭제하지 않고 이력 보존)
    if (futureUserCounts.size > 0) {
        for (const [uid, cnt] of futureUserCounts.entries()) {
            await createNotification({
                userId: uid,
                type: 'reservation',
                title: '코스가 삭제되었습니다',
                body: `${courseName} 코스가 삭제되었습니다. 예약 이력은 보존됩니다.`,
                placeId,
                data: {
                    kind: 'course-deleted',
                    courseId,
                    placeId,
                    cancelledReservations: cnt,
                },
                isAdmin: false,
            });
        }
    }

    logFunctionSuccess(functionName, {
        callerId,
        placeId,
        courseId,
        courseName,
        cascade,
        cancellableFutureCount,
        deletedReservations,
        deletedSummaries,
        deletedCourseOverrides,
        deletedBookingWeekOpens,
        deletedEnrollments,
        deletedCourseMembers,
        updatedPendingMembers,
        deletedCoursePolicy,
        demotedSubManagers,
    });

    return {
        success: true,
        courseName,
        cancellableFutureCount,
        deletedReservations,
    };
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
    const callerMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(callerId).get();
    const callerData = callerMemberSnap.data();
    const callerRole = String(callerData?.role ?? '').toLowerCase();
    if (callerRole === 'submanager') {
        throw new functions.https.HttpsError(
            'permission-denied',
            '플레이스 삭제는 매니저만 할 수 있습니다.',
        );
    }

    // place 존재 확인 및 코스 ID 수집
    const placeDoc = await db.collection('places').doc(placeId).get();
    if (!placeDoc.exists) {
        throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
    }
    const coursesSnap = await db.collection('places').doc(placeId).collection('courses').get();
    const courseIds = coursesSnap.docs.map((d) => d.id);

    // 1) 글로벌 컬렉션 먼저 정리 (실패 시 place는 삭제하지 않음 → 고아 데이터 방지)
    let deletedReservations = 0;
    let deletedEnrollments = 0;
    let deletedPromotions = 0;
    let deletedNotifications = 0;
    let deletedBookingWeekOpens = 0;
    let deletedCourseOverrides = 0;
    let deletedCoursePolicies = 0;
    const deletedCourseMembers = 0;
    let deletedSummaries = 0;

    // reservations는 삭제하지 않음 — 이력 보존 (deletedReservations = 0 유지)
    // reservationSummary: 코스별로 삭제 (고아 방지)
    for (const courseId of courseIds) {
        deletedSummaries += await deleteSummariesForCourse(db, placeId, courseId);
    }
    deletedEnrollments = await deleteEnrollmentsWithSubcollections(
        db,
        db.collection('enrollments').where('placeId', '==', placeId),
    );
    deletedPromotions = await deleteByQuery(
        db,
        db.collection('promotions').where('placeId', '==', placeId),
    );
    deletedNotifications = await deleteByQuery(
        db,
        db.collectionGroup('notifications').where('placeId', '==', placeId),
    );
    deletedBookingWeekOpens = await deleteByQuery(
        db,
        db.collection('bookingWeekOpens').where('placeId', '==', placeId),
    );
    deletedCourseOverrides = await deleteByQuery(
        db,
        db.collection('courseOverrides').where('placeId', '==', placeId),
    );
    for (const courseId of courseIds) {
        const policyRef = db.collection('coursePolicies').doc(courseId);
        const policySnap = await policyRef.get();
        if (policySnap.exists) {
            await policyRef.delete();
            deletedCoursePolicies++;
        }
    }

    // 2) place 서브컬렉션 + place 문서 삭제 (위 단계 성공 후에만 실행)
    const deletedPendingMembers = await deleteCollectionByPath(db, `places/${placeId}/pendingMembers`);

    const coursesRef = db.collection('places').doc(placeId).collection('courses');
    while (true) {
        const snap = await coursesRef.limit(400).get();
        if (snap.empty) break;
        const batch = db.batch();
        snap.docs.forEach((d) => batch.delete(d.ref));
        await batch.commit();
    }

    const storiesRef = db.collection('places').doc(placeId).collection('stories');
    while (true) {
        const snap = await storiesRef.limit(400).get();
        if (snap.empty) break;
        const batch = db.batch();
        snap.docs.forEach((d) => batch.delete(d.ref));
        await batch.commit();
    }

    let deletedMembers = 0;
    const membersRef = db.collection('places').doc(placeId).collection('members');
    while (true) {
        const snap = await membersRef.limit(400).get();
        if (snap.empty) break;
        const batch = db.batch();
        snap.docs.forEach((d) => batch.delete(d.ref));
        deletedMembers += snap.size;
        await batch.commit();
    }

    await db.collection('places').doc(placeId).delete();

    logFunctionSuccess(functionName, {
        callerId,
        placeId,
        deletedReservations,
        deletedSummaries,
        deletedEnrollments,
        deletedCourseMembers,
        deletedPendingMembers,
        deletedMembers,
        deletedPromotions,
        deletedNotifications,
        deletedBookingWeekOpens,
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
 * - Firestore: users, enrollments, reservations, pendingMembers, notifications, adminUsers 정리
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
        // 0) 전체 매니저 또는 플레이스 소유자이면 탈퇴 거부 (먼저 플레이스 삭제 필요). 코스매니저만이면 허용.
        const placeIdsRequiringDeleteFirst = await getPlaceIdsWhereUserMustDeletePlaceFirst(userId);
        if (placeIdsRequiringDeleteFirst.length > 0) {
            logFunctionError(functionName, new Error('Manager/owner has places'), { userId, placeCount: placeIdsRequiringDeleteFirst.length });
            throw new functions.https.HttpsError(
                'failed-precondition',
                '관리자인 경우 소속 플레이스를 먼저 삭제해주세요.',
            );
        }

        // 1) users 문서 조회 (phoneNumber 등 후속 정리용)
        const userRef = db.collection('users').doc(userId);
        const userDoc = await userRef.get();
        const userData = userDoc.exists ? userDoc.data() : null;
        const phoneNumber = userData?.phoneNumber ? String(userData.phoneNumber).replace(/\D/g, '') : '';

        // 2) enrollments에서 placeId 수집 (예약 삭제용)
        const enrollmentsSnap = await db.collection('enrollments').where('userId', '==', userId).get();
        const placeIds = [...new Set(enrollmentsSnap.docs.map((d) => d.data().placeId as string))];
        console.log(`[${functionName}] placeIds from enrollments: ${placeIds.join(', ')}`);

        // 2.3) users/{userId} 서브컬렉션 삭제 (고아 방지 — 문서 삭제 전에 수행)
        const notificationsCollRef = userRef.collection('notifications');
        const fcmTokensCollRef = userRef.collection('fcmTokens');
        const deletedUserNotifications = await deleteByQuery(db, notificationsCollRef as any);
        const deletedFcmTokens = await deleteByQuery(db, fcmTokensCollRef as any);
        if (deletedUserNotifications > 0 || deletedFcmTokens > 0) {
            console.log(`[${functionName}] Deleted users subcollections: notifications=${deletedUserNotifications}, fcmTokens=${deletedFcmTokens}`);
        }

        // 2.5) users 문서 삭제 (필요한 정보(phoneNumber, placeIds)는 이미 확보, 서브컬렉션 정리 완료)
        await userRef.delete();
        console.log(`[${functionName}] Deleted users doc: ${userId}`);

        // 3) enrollments 삭제
        const deletedEnrollments = await deleteByQuery(
            db,
            db.collection('enrollments').where('userId', '==', userId),
        );
        console.log(`[${functionName}] Deleted enrollments: ${deletedEnrollments}`);

        // 4) courseMembers 미사용
        const deletedCourseMembers = 0;

        // 5) 예약 삭제 (글로벌 reservations만 사용)
        let deletedReservations = 0;
        const reservationsSnap = await db
            .collection('reservations')
            .where('userId', '==', userId)
            .get();
        if (!reservationsSnap.empty) {
            const batchSize = 400;
            const docs = reservationsSnap.docs;
            for (let i = 0; i < docs.length; i += batchSize) {
                const batch = db.batch();
                docs.slice(i, i + batchSize).forEach((d) => batch.delete(d.ref));
                await batch.commit();
                deletedReservations += Math.min(batchSize, docs.length - i);
            }
        }
        console.log(`[${functionName}] Deleted reservations: ${deletedReservations}`);

        // 6) pendingMembers 삭제 (places/{placeId}/pendingMembers, collectionGroup으로 phoneNumber 검색)
        let deletedPending = 0;
        if (phoneNumber) {
            const pendingSnap = await db.collectionGroup('pendingMembers')
                .where('phoneNumber', '==', phoneNumber)
                .get();
            for (const doc of pendingSnap.docs) {
                await doc.ref.delete();
                deletedPending++;
            }
            console.log(`[${functionName}] Deleted pendingMembers (phoneNumber): ${deletedPending}`);
        }

        // 7) places/{placeId}/members/{userId} 삭제 (기존 collectionGroup members userId 인덱스 사용)
        const memberSnap = await db.collectionGroup('members')
            .where('userId', '==', userId)
            .get();
        const deletedMemberships = memberSnap.size;
        for (const doc of memberSnap.docs) {
            await doc.ref.delete();
        }
        if (deletedMemberships > 0) {
            console.log(`[${functionName}] Deleted place memberships: ${deletedMemberships}`);
        }

        // 8) notifications는 2.3에서 users 서브컬렉션으로 이미 삭제됨. 로그용 변수만 유지.
        const deletedNotifications = deletedUserNotifications;

        // 9) Firebase Auth 사용자 삭제 (마지막에 수행)
        try {
            await admin.auth().deleteUser(userId);
            console.log(`[${functionName}] Deleted Firebase Auth user: ${userId}`);
        } catch (authErr: any) {
            if (authErr?.code === 'auth/user-not-found') {
                console.log(`[${functionName}] Firebase Auth user already gone: ${userId}`);
            } else {
                throw authErr;
            }
        }

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
    if (!userId || userId.startsWith('pending_')) return; // pending은 유저 문서 없음, 알림 생성 스킵
    try {
        const ref = await admin.firestore()
            .collection('users')
            .doc(userId)
            .collection('notifications')
            .add({
                type,
                title,
                body,
                placeId: placeId || null,
                data: data || {},
                isRead: false,
                isAdminNotification: isAdmin,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        console.log(`[createNotification] Firestore 알림 문서 생성됨 notificationId=${ref.id} userId=${userId} type=${type} title=${title?.substring(0, 30)}`);
    } catch (error) {
        console.error(`[createNotification] Error creating notification:`, error);
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
    console.log(`[sendPushNotification] called userId=${userId} title=${title?.substring(0, 40)}`);
    try {
        const userDoc = await admin.firestore().collection('users').doc(userId).get();
        if (!userDoc.exists) {
            console.warn(`[sendPushNotification] User not found: users/${userId}`);
            return;
        }

        const userData = userDoc.data();
        const fcmToken = userData?.fcmToken as string | undefined;
        const notificationsEnabled = userData?.notificationsEnabled !== false;

        if (!fcmToken) {
            console.warn(`[sendPushNotification] No FCM token for user ${userId} (users/${userId}.fcmToken missing or empty)`);
            return;
        }
        const tokenPreview = fcmToken.length > 20 ? `${fcmToken.substring(0, 10)}...${fcmToken.substring(fcmToken.length - 8)}` : fcmToken;
        console.log(`[sendPushNotification] userId=${userId} hasToken=true tokenLen=${fcmToken.length} tokenPreview=${tokenPreview} notificationsEnabled=${notificationsEnabled}`);

        if (!notificationsEnabled) {
            console.log(`[sendPushNotification] Notifications disabled for user ${userId} → skip send`);
            return;
        }

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

        const response = await admin.messaging().send(message);
        console.log(`[sendPushNotification] FCM 전송 성공 userId=${userId} messageId=${response}`);
    } catch (error: any) {
        console.error(`[sendPushNotification] FCM 전송 실패 userId=${userId} error=${error?.message ?? error} code=${error?.code ?? '-'}`);
    }
}

/**
 * 코스 문서(정책·이름 등) 변경 시 매니저·코스매니저에게 푸시 알림
 * 정기 일정(sessions)만 변경된 경우는 updateCourseSchedule에서 이미 알림 전송하므로 스킵
 */
export const onCourseDocumentUpdated = functions.firestore
    .document('places/{placeId}/courses/{courseId}')
    .onUpdate(async (change: Change<QueryDocumentSnapshot>, context: EventContext) => {
        const placeId = context.params.placeId as string;
        const courseId = context.params.courseId as string;
        const before = change.before.data() || {};
        const after = change.after.data() || {};

        // sessions만 변경된 경우(정기 일정은 updateCourseSchedule에서 알림 처리) 스킵
        const allKeys = new Set([...Object.keys(before), ...Object.keys(after)]);
        const changedKeys = [...allKeys].filter(
            (k) => JSON.stringify((before as any)[k]) !== JSON.stringify((after as any)[k]),
        );
        const onlySessionsAndMeta =
            changedKeys.length > 0 &&
            changedKeys.every((k) => k === 'sessions' || k === 'updatedAt') &&
            changedKeys.includes('sessions');
        if (onlySessionsAndMeta) return;

        const policyChanged = JSON.stringify(before.policy ?? {}) !== JSON.stringify(after.policy ?? {});
        const courseName = (after.name as string) || '코스';
        const title = policyChanged ? '예약 정책 변경' : '코스 정보 변경';
        const body = policyChanged
            ? `${courseName} 예약 정책이 변경되었습니다`
            : `${courseName} 정보가 변경되었습니다`;

        try {
            const adminUids = await getManagerUidsForPlaceAndCourse(placeId, courseId);
            for (const uid of adminUids) {
                await createNotification({
                    userId: uid,
                    type: 'system',
                    title,
                    body,
                    placeId,
                    data: { courseId, placeId, kind: policyChanged ? 'policy-update' : 'course-update' },
                    isAdmin: true,
                });
            }
        } catch (err: any) {
            console.error(`[onCourseDocumentUpdated] 관리자 알림 실패:`, err?.message ?? err);
        }
    });

/**
 * 알림 생성 시 FCM 푸시 알림도 함께 전송
 * 경로: users/{userId}/notifications/{notificationId}
 */
export const onNotificationCreated = functions.firestore
    .document('users/{userId}/notifications/{notificationId}')
    .onCreate(async (snap: QueryDocumentSnapshot, context: EventContext) => {
        const notificationId = context.params.notificationId as string;
        const userId = context.params.userId as string;
        const notification = snap.data();
        console.log(`[onNotificationCreated] 트리거 실행 notificationId=${notificationId} userId=${userId} title=${notification.title?.substring(0, 30)}`);

        try {
            await sendPushNotification({
                userId,
                title: notification.title || '알림',
                body: notification.body || '',
                data: {
                    notificationId,
                    userId,
                    type: notification.type || 'system',
                    ...(notification.data || {}),
                },
            });
        } catch (error: any) {
            console.error(`[onNotificationCreated] sendPushNotification 실패: ${error?.message ?? error}`);
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

            // 코스명 조회 (서브컬렉션)
            const courseName = await getCourseName(placeId, courseId);

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
 * 수강 액션(재등록/기간연장/횟수조정) 시 사용자에게 푸시 알림 전송
 * enrollments/{enrollmentId}/actionHistory/{actionId} onCreate
 */
export const onEnrollmentActionCreated = functions.firestore
    .document('enrollments/{enrollmentId}/actionHistory/{actionId}')
    .onCreate(async (snap: QueryDocumentSnapshot, context: EventContext) => {
        const enrollmentId = context.params.enrollmentId as string;
        const actionData = snap.data();
        const actionType = (actionData?.actionType as string) || '';
        const oldValue = (actionData?.oldValue || {}) as Record<string, any>;
        const newValue = (actionData?.newValue || {}) as Record<string, any>;

        // 재등록, 기간연장, 횟수조정만 알림 대상
        if (!['reenroll', 'periodAdjust', 'adjustCount'].includes(actionType)) {
            return;
        }

        try {
            const enrollmentDoc = await admin.firestore()
                .collection('enrollments')
                .doc(enrollmentId)
                .get();
            if (!enrollmentDoc.exists) {
                console.warn(`[onEnrollmentActionCreated] Enrollment not found: ${enrollmentId}`);
                return;
            }

            const enrollment = enrollmentDoc.data();
            const userId = enrollment?.userId as string;
            const placeId = enrollment?.placeId as string;
            const courseId = enrollment?.courseId as string;

            if (!userId) {
                console.warn(`[onEnrollmentActionCreated] No userId in enrollment: ${enrollmentId}`);
                return;
            }

            const courseName = await getCourseName(placeId, courseId).catch(() => '코스');
            const displayName = courseName || '코스';

            /** ISO8601 또는 Date를 서울 기준 "YYYY.MM.DD"로 변환 (알림 표시용) */
            const toDisplayDate = (v: any): string => {
                if (!v) return '';
                let d: Date;
                if (typeof v === 'string') {
                    d = new Date(v);
                    if (isNaN(d.getTime())) return v;
                } else if (v && typeof v.toDate === 'function') {
                    d = v.toDate();
                } else {
                    return String(v);
                }
                return formatDateToSeoul(d).replace(/-/g, '.');
            };

            let title = '';
            let body = '';

            if (actionType === 'periodAdjust') {
                title = '유효 기간 조정';
                const fromStr = toDisplayDate(oldValue?.validUntil ?? newValue?.validFrom);
                const toStr = toDisplayDate(newValue?.validUntil ?? newValue?.validFrom);
                body = `${displayName} 유효기간이 ${fromStr}에서 ${toStr}로 변경되었습니다`;
            } else if (actionType === 'adjustCount') {
                title = '예약 가능 횟수 변경';
                const remaining = newValue?.remainingReservations ?? '?';
                body = `${displayName} 예약 가능횟수가 ${remaining}회로 변경되었습니다`;
            } else if (actionType === 'reenroll') {
                title = '재등록 알림';
                body = `${displayName}이(가) 재등록 처리 되었습니다`;
            }

            if (title && body) {
                await createNotification({
                    userId,
                    type: 'system',
                    title,
                    body,
                    placeId,
                    data: { enrollmentId, courseId, actionType },
                    isAdmin: false,
                });
                console.log(`[onEnrollmentActionCreated] Notification sent userId=${userId} actionType=${actionType}`);
            }
        } catch (error: any) {
            console.error(`[onEnrollmentActionCreated] Error:`, error?.message ?? error);
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
            const realNow = new Date();
            const inThreeHours = new Date(realNow.getTime() + 3 * 60 * 60 * 1000);

            // 3시간 후의 날짜와 시간 계산 (서울 기준)
            const targetDateString = formatDateToSeoul(inThreeHours);
            const { h: targetHour, m: targetMinute } = getSeoulTimeParts(inThreeHours);
            const targetHHmm = `${pad2(targetHour)}:${pad2(targetMinute)}`;

            console.log(`[sendUpcomingSessionNotifications] Checking for sessions at ${targetDateString} ${targetHHmm}`);

            // 모든 플레이스의 예약 조회 (2시간 후 날짜와 시간으로 필터링)
            const placesSnapshot = await admin.firestore().collection('places').get();
            let totalNotifications = 0;

            for (const placeDoc of placesSnapshot.docs) {
                const placeId = placeDoc.id;

                // 해당 플레이스의 예약 조회 (글로벌 reservations)
                const reservationsSnapshot = await admin.firestore()
                    .collection('reservations')
                    .where('placeId', '==', placeId)
                    .where('reservedDateString', '==', targetDateString)
                    .where('startTime', '==', targetHHmm)
                    .get();

                if (reservationsSnapshot.empty) {
                    continue;
                }

                // 코스 정보 가져오기 (서브컬렉션)
                const coursesSnap = await admin.firestore().collection('places').doc(placeId).collection('courses').get();
                const courseMap = new Map<string, any>();
                coursesSnap.docs.forEach((doc) => courseMap.set(doc.id, doc.data()));

                // 각 예약에 대해 알림 전송 (중복 방지: 오늘 이미 보낸 알림인지 확인)
                const notificationPromises = reservationsSnapshot.docs.map(async (reservationDoc) => {
                    const reservation = reservationDoc.data();
                    const userId = reservation.userId as string;
                    if (!userId || userId.startsWith('pending_')) return; // pending은 유저 문서 없음, 알림 스킵

                    const courseId = reservation.courseId as string;
                    const reservationId = reservationDoc.id;

                    // 이미 오늘 알림을 보냈는지 확인 (중복 방지)
                    const todayString = formatDateToSeoul(realNow);
                    const notificationQuery = await admin.firestore()
                        .collection('users')
                        .doc(userId)
                        .collection('notifications')
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

                    const tomorrow = new Date(realNow.getTime() + 24 * 60 * 60 * 1000);
                    const tomorrowString = formatDateToSeoul(tomorrow);
                    const dateLabel = targetDateString === todayString ? '오늘' : targetDateString === tomorrowString ? '내일' : targetDateString;

                    // 알림 생성 (3시간 전, 한 번만)
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: courseName,
                        body: `${dateLabel} ${targetHHmm}시에 ${courseName} 세션이 시작됩니다.`,
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
 * 주기적 과거 데이터 정리 (매일 새벽 4시)
 * - 현재 시점 기준 30일 이전 데이터 삭제
 * - courseOverrides, reservationSummary, bookingWeekOpens (각 단계 사이 2초 텀)
 * - reservations 컬렉션은 정리하지 않음 (사용자 예약 히스토리 보존)
 */
const CLEANUP_DAYS_AGO = 30;
const CLEANUP_STEP_DELAY_MS = 2000;

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export const cleanupOldData = functions.pubsub
    .schedule('0 4 * * *') // 매일 새벽 4시 (서울 시간)
    .timeZone('Asia/Seoul')
    .onRun(async (_context: EventContext) => {
        const db = admin.firestore();
        const realNow = new Date();
        const cutoffDate = addDaysUtc(realNow, -CLEANUP_DAYS_AGO);
        const cutoffString = formatDateToSeoul(cutoffDate);

        let totalDeleted = 0;

        try {
            // 1) courseOverrides (date < 30일 전)
            const ovQuery = db.collection('courseOverrides')
                .where('date', '<', cutoffString)
                .orderBy('date');
            const deletedOverrides = await deleteByQuery(db, ovQuery);
            totalDeleted += deletedOverrides;
            if (deletedOverrides > 0) {
                console.log(`[cleanupOldData] courseOverrides: ${deletedOverrides} deleted (date < ${cutoffString})`);
            }
            await sleep(CLEANUP_STEP_DELAY_MS);

            // 2) reservationSummary (date < 30일 전)
            const sumQuery = db.collection('reservationSummary')
                .where('date', '<', cutoffString)
                .orderBy('date');
            const deletedSummary = await deleteByQuery(db, sumQuery);
            totalDeleted += deletedSummary;
            if (deletedSummary > 0) {
                console.log(`[cleanupOldData] reservationSummary: ${deletedSummary} deleted (date < ${cutoffString})`);
            }
            await sleep(CLEANUP_STEP_DELAY_MS);

            // 3) bookingWeekOpens (weekStartDate < 30일 전 — 이미 지난 주의 미리예약 열기 문서)
            const bwoQuery = db.collection('bookingWeekOpens')
                .where('weekStartDate', '<', cutoffString)
                .orderBy('weekStartDate');
            const deletedBookingWeekOpens = await deleteByQuery(db, bwoQuery);
            totalDeleted += deletedBookingWeekOpens;
            if (deletedBookingWeekOpens > 0) {
                console.log(`[cleanupOldData] bookingWeekOpens: ${deletedBookingWeekOpens} deleted (weekStartDate < ${cutoffString})`);
            }

            console.log(`[cleanupOldData] done. total deleted: ${totalDeleted}`);
            return { success: true, totalDeleted };
        } catch (error) {
            console.error('[cleanupOldData] Error:', error);
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
            const realNow = new Date();
            const in7Days = new Date(realNow.getTime() + 7 * 24 * 60 * 60 * 1000);

            // 7일 이내 만료되는 등록 조회
            const enrollmentsSnapshot = await admin.firestore()
                .collection('enrollments')
                .where('validUntil', '<=', admin.firestore.Timestamp.fromDate(in7Days))
                .where('validUntil', '>', admin.firestore.Timestamp.fromDate(realNow))
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
                const daysUntilExpiry = Math.ceil((validUntil.getTime() - realNow.getTime()) / (24 * 60 * 60 * 1000));

                // 이미 오늘 알림을 보냈는지 확인 (중복 방지)
                const todayString = formatDateToSeoul(realNow);
                const notificationQuery = await admin.firestore()
                    .collection('users')
                    .doc(userId)
                    .collection('notifications')
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

                // 코스명 조회 (서브컬렉션)
                let courseName = courseId;
                try {
                    courseName = await getCourseName(placeId, courseId);
                } catch {
                    // 코스 없으면 courseId 그대로 사용
                }

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
    const callerId = context.auth.uid;
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

    await assertAdminForPlaceUid(callerId, placeId);
    const db = admin.firestore();
    const callerMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(callerId).get();
    const callerData = callerMemberSnap.data();
    const callerRole = String(callerData?.role ?? '').toLowerCase();
    const rawManageable = callerData?.manageableCourseIds;
    const manageableCourseIds: string[] = callerRole === 'submanager' && Array.isArray(rawManageable)
        ? (rawManageable as string[]).map((id: string) => String(id)).filter(Boolean)
        : [];

    if (callerRole === 'submanager' && manageableCourseIds.length === 0) {
        await demoteSubManagerToMemberIfNoCoursesInternal(db, placeId, callerId);
        throw new functions.https.HttpsError('permission-denied', '관리할 코스가 없습니다.');
    }

    if (newDayOfWeek < 1 || newDayOfWeek > 7) {
        throw new functions.https.HttpsError('invalid-argument', 'newDayOfWeek는 1-7(월-일) 사이여야 합니다.');
    }
    if (reservationIds.length > 200) {
        throw new functions.https.HttpsError('invalid-argument', '한 번에 최대 200건까지 이동할 수 있습니다.');
    }
    parseYYYYMMDD(newReservedDateString); // validate
    const realNow = new Date();
    const todayString = formatDateToSeoul(realNow);
    if (seoulDateOnly(newReservedDateString).getTime() < seoulDateOnly(todayString).getTime()) {
        throw new functions.https.HttpsError('failed-precondition', '과거 날짜로는 이동할 수 없습니다.');
    }

    // 트랜잭션 외부에서 사용할 변수들
    const results: Array<{ reservationId: string; success: boolean; error?: string }> = [];
    const userIds = new Set<string>();
    let reservationsByCourse: Map<string, Array<{ doc: FirebaseFirestore.DocumentSnapshot; ref: FirebaseFirestore.DocumentReference }>> = new Map();

    return await db.runTransaction(async (tx) => {
        // 1) 모든 예약 조회 (선행 read, 글로벌 reservations)
        const reservationRefs = reservationIds.map((id: string) =>
            db.collection('reservations').doc(id)
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

            if (manageableCourseIds.length > 0 && !manageableCourseIds.includes(courseId)) {
                results.push({ reservationId: reservationIds[i], success: false, error: '해당 코스에 대한 권한이 없습니다.' });
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

        // 3) 선행 읽기: 중복 검사 + 이동 대상별 reservationSummary 문서 (쓰기 후 읽기 금지 준수)
        type MoveOp = { ref: FirebaseFirestore.DocumentReference; reservation: any; courseId: string };
        const moves: MoveOp[] = [];
        const oldSummaryKeys = new Set<string>();
        for (const [courseId, reservations] of reservationsByCourse.entries()) {
            for (const { doc, ref } of reservations) {
                const reservation = doc.data() as any;
                const userId = String(reservation?.userId ?? '');

                const dupQuery = db.collection('reservations')
                    .where('placeId', '==', placeId)
                    .where('courseId', '==', courseId)
                    .where('dayOfWeek', '==', newDayOfWeek)
                    .where('startTime', '==', newStartTime)
                    .where('reservedDateString', '==', newReservedDateString)
                    .where('userId', '==', userId)
                    .limit(2);
                const dupSnap = await tx.get(dupQuery);
                const otherInTarget = dupSnap.docs.filter((d) => d.id !== ref.id);
                if (otherInTarget.length > 0) {
                    results.push({ reservationId: ref.id, success: false, error: '이미 해당 세션에 예약이 있습니다.' });
                    continue;
                }

                const oldDayOfWeek = reservation?.dayOfWeek ?? 0;
                const oldStartTime = String(reservation?.startTime ?? '');
                const oldReservedDateString = String(reservation?.reservedDateString ?? '');
                const oldSessionId = `${courseId}_${oldDayOfWeek}_${oldStartTime}`;
                const oldKey = `${oldSessionId}_${oldReservedDateString}`;
                oldSummaryKeys.add(oldKey);
                moves.push({ ref, reservation: { ...reservation, courseId, oldSessionId, oldReservedDateString }, courseId });
            }
        }

        // old/new별 delta 집계 (배치 삭제·배치 추가)
        const oldDeltaByKey = new Map<string, { sessionId: string; reservedDateString: string; delta: number }>();
        const newDeltaByKey = new Map<string, { courseId: string; delta: number }>();
        for (const m of moves) {
            const oldKey = `${m.reservation.oldSessionId}_${m.reservation.oldReservedDateString}`;
            const prev = oldDeltaByKey.get(oldKey);
            if (!prev) oldDeltaByKey.set(oldKey, { sessionId: m.reservation.oldSessionId, reservedDateString: m.reservation.oldReservedDateString, delta: 1 });
            else prev.delta += 1;

            const newKey = `${m.courseId}_${newDayOfWeek}_${newStartTime}_${newReservedDateString}`;
            const prevNew = newDeltaByKey.get(newKey);
            if (!prevNew) newDeltaByKey.set(newKey, { courseId: m.courseId, delta: 1 });
            else prevNew.delta += 1;
        }

        const oldKeysArray = [...oldSummaryKeys];
        const newKeysArray = [...newDeltaByKey.keys()];
        const allSummaryRefs = [
            ...oldKeysArray.map((key) => db.collection('reservationSummary').doc(key)),
            ...newKeysArray.map((key) => db.collection('reservationSummary').doc(key)),
        ];
        const summarySnaps = await Promise.all(allSummaryRefs.map((r) => tx.get(r)));
        const summarySnapByKey = new Map<string, FirebaseFirestore.DocumentSnapshot>();
        oldKeysArray.forEach((key, i) => summarySnapByKey.set(key, summarySnaps[i]));
        newKeysArray.forEach((key, i) => summarySnapByKey.set(key, summarySnaps[oldKeysArray.length + i]));

        // 4) 쓰기: 예약 문서 배치 업데이트 + summary는 old별 배치 감소, new별 배치 증가
        for (const { ref } of moves) {
            tx.update(ref, {
                dayOfWeek: newDayOfWeek,
                startTime: newStartTime,
                reservedDateString: newReservedDateString,
                reservedDate: admin.firestore.Timestamp.fromDate(seoulDateOnly(newReservedDateString)),
            });
            results.push({ reservationId: ref.id, success: true });
        }
        for (const [oldKey, { sessionId, reservedDateString, delta }] of oldDeltaByKey.entries()) {
            const snap = summarySnapByKey.get(oldKey);
            await decrementReservedCountBy(tx, db, { sessionId, reservedDateString }, delta, snap);
        }
        for (const [newKey, { courseId, delta }] of newDeltaByKey.entries()) {
            const newSessionId = `${courseId}_${newDayOfWeek}_${newStartTime}`;
            const snap = summarySnapByKey.get(newKey);
            await incrementReservedCountBy(tx, db, {
                sessionId: newSessionId,
                courseId,
                placeId,
                dayOfWeek: newDayOfWeek,
                startTime: newStartTime,
                reservedDateString: newReservedDateString,
                capacity: 0,
            }, delta, snap);
        }

        const movedCount = results.filter(r => r.success).length;
        const movedUserIds = [...new Set(moves.map((m) => String(m.reservation?.userId ?? '')))].filter(Boolean);
        logFunctionSuccess(functionName, { reservationIds: reservationIds.length, moved: movedCount });
        return { success: true, results, movedCount, movedUserIds };
    }).then(async (result) => {
        // 실제로 이동된 건이 있을 때만, 이동된 사용자에게만 알림 전송
        const movedCount = (result?.movedCount ?? 0) as number;
        const movedUserIds = (result?.movedUserIds ?? []) as string[];
        if (result?.success && movedCount > 0 && movedUserIds.length > 0) {
            try {
                const firstCourseId = Array.from(reservationsByCourse.keys())[0];
                const courseName = firstCourseId ? (await getCourseName(placeId, firstCourseId)) || '코스' : '코스';
                const newDateTimeKr = formatDateTimeKr(newReservedDateString, newStartTime);

                for (const userId of movedUserIds) {
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: `${courseName} 예약이 변경되었습니다`,
                        body: `${newDateTimeKr}로 변경되었습니다.`,
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
    // 시각 비교는 epoch 기준 new Date()만 사용 (서울 날짜 문자열은 formatDateToSeoul(now))
    const nowForComparison = new Date();
    const isAdminForThisPlace = await isAdminForPlaceUid(callerId, placeId);

    let manageableCourseIds: string[] = [];
    if (isAdminForThisPlace) {
        const callerMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(callerId).get();
        const callerData = callerMemberSnap.data();
        const callerRole = String(callerData?.role ?? '').toLowerCase();
        const rawManageable = callerData?.manageableCourseIds;
        if (callerRole === 'submanager' && Array.isArray(rawManageable)) {
            manageableCourseIds = (rawManageable as string[]).map((id: string) => String(id)).filter(Boolean);
        }
        if (callerRole === 'submanager' && manageableCourseIds.length === 0) {
            await demoteSubManagerToMemberIfNoCoursesInternal(db, placeId, callerId);
            throw new functions.https.HttpsError('permission-denied', '관리할 코스가 없습니다.');
        }
    }

    // 본인 예약 1건 취소는 일반 사용자도 허용 (관리자 아님 + 1건 + 예약 소유자 확인은 아래에서)
    const allowSelfCancelSingle = !isAdminForThisPlace && reservationIds.length === 1;
    if (!isAdminForThisPlace && !allowSelfCancelSingle) {
        throw new functions.https.HttpsError('permission-denied', '해당 플레이스에 대한 관리자 권한이 필요합니다.');
    }

    // results[i] = reservationIds[i]에 대한 결과 (입력 순서 보장)
    const results: Array<{ reservationId: string; success: boolean; error?: string } | undefined> = new Array(reservationIds.length);
    const userIds = new Set<string>();
    const courseIds = new Set<string>();

    // 트랜잭션 밖에서 예약 조회 및 검증 (글로벌 reservations)
    const reservationRefs = reservationIds.map((id: string) =>
        db.collection('reservations').doc(id)
    );
    const reservationDocs = await Promise.all(reservationRefs.map((ref: FirebaseFirestore.DocumentReference) => ref.get()));

    // 예약 데이터 검증 및 취소 가능 여부 확인 (inputIndex로 results 순서 유지)
    const reservationsToCancel: Array<{ doc: FirebaseFirestore.DocumentSnapshot; ref: FirebaseFirestore.DocumentReference; reservation: any; inputIndex: number }> = [];

    for (let i = 0; i < reservationDocs.length; i++) {
        const doc = reservationDocs[i];
        if (!doc.exists) {
            results[i] = { reservationId: reservationIds[i], success: false, error: '예약을 찾을 수 없습니다.' };
            continue;
        }

        const reservation = doc.data() as any;
        const reservationPlaceId = String(reservation?.placeId ?? '');
        if (reservationPlaceId !== placeId) {
            results[i] = { reservationId: reservationIds[i], success: false, error: '해당 플레이스의 예약이 아닙니다.' };
            continue;
        }
        const reservationUserId = String(reservation?.userId ?? '');
        const courseId = String(reservation?.courseId ?? '');
        const dayOfWeek = Number(reservation?.dayOfWeek ?? 0);
        const startTime = String(reservation?.startTime ?? '');
        const reservedDateString = String(reservation?.reservedDateString ?? '');

        if (!reservationUserId || !courseId || !startTime || !reservedDateString || !Number.isFinite(dayOfWeek)) {
            results[i] = { reservationId: reservationIds[i], success: false, error: '예약 데이터가 올바르지 않습니다.' };
            continue;
        }

        if (manageableCourseIds.length > 0 && !manageableCourseIds.includes(courseId)) {
            results[i] = { reservationId: reservationIds[i], success: false, error: '해당 코스에 대한 권한이 없습니다.' };
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
            results[i] = { reservationId: reservationIds[i], success: false, error: '날짜/시간 형식이 올바르지 않습니다.' };
            continue;
        }

        const sessionStart = makeSeoulDateTime(y, mo, d, h, m);
        if (nowForComparison.getTime() >= sessionStart.getTime()) {
            results[i] = { reservationId: reservationIds[i], success: false, error: '이미 시작된 세션은 취소할 수 없습니다.' };
            continue;
        }

        userIds.add(reservationUserId);
        courseIds.add(courseId);
        reservationsToCancel.push({ doc, ref: reservationRefs[i], reservation, inputIndex: i });
    }

    // 본인 예약 1건 취소 시: 해당 예약의 userId가 호출자와 일치하는지 확인
    if (allowSelfCancelSingle && reservationsToCancel.length === 1) {
        const r = reservationsToCancel[0].reservation;
        if (String(r?.userId ?? '') !== callerId) {
            throw new functions.https.HttpsError('permission-denied', '본인 예약만 취소할 수 있습니다.');
        }
    }

    // 트랜잭션 밖에서 enrollment 조회
    const enrollmentRefs = new Map<string, FirebaseFirestore.DocumentReference>();
    const enrollmentDocs = new Map<string, FirebaseFirestore.DocumentSnapshot>();
    const pendingRefs = new Map<string, FirebaseFirestore.DocumentReference>(); // key: pendingId (placeId_phoneNumber)

    for (const { reservation } of reservationsToCancel) {
        const reservationEnrollmentId = String(reservation?.enrollmentId ?? '');
        if (!reservationEnrollmentId) continue; // 일회성 더미 예약은 환불 대상 아님 → ref 수집 생략

        const userId = String(reservation.userId);
        const courseId = String(reservation.courseId);
        const enrollmentId = `${userId}_${placeId}_${courseId}`;

        // pending 멤버: places/{placeId}/pendingMembers
        if (userId.startsWith('pending_')) {
            const pendingId = userId.replace('pending_', '');
            if (pendingId) {
                pendingRefs.set(pendingId, db.collection('places').doc(placeId).collection('pendingMembers').doc(pendingId));
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

        // 2) enrollment remainingReservations 업데이트 (write)
        const enrollmentUpdates = new Map<string, { remaining: number; total: number }>();
        const pendingCreditAdds = new Map<string, Map<string, number>>(); // pendingId -> (courseId -> count)

        for (const { reservation } of reservationsToCancel) {
            const reservationEnrollmentId = String(reservation?.enrollmentId ?? '');
            if (!reservationEnrollmentId) continue; // 일회성 더미 예약: enrollment/pending 차감한 적 없으므로 환불하지 않음

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

        // 4) 예약 삭제 (write) — results[inputIndex]로 입력 순서 유지
        for (const { ref, inputIndex } of reservationsToCancel) {
            tx.delete(ref);
            results[inputIndex] = { reservationId: ref.id, success: true };
        }

        const finalResults = results.filter((r): r is { reservationId: string; success: boolean; error?: string } => r != null);
        logFunctionSuccess(functionName, { reservationIds: reservationIds.length, cancelled: finalResults.filter(r => r.success).length });
        return { success: true, results: finalResults, cancelledCount: finalResults.filter(r => r.success).length };
    }).then(async (result) => {
        // 트랜잭션 완료 후 알림: 관리자가 취소한 경우에만 전송 (일반 유저 직접 취소 시 알림 X)
        if (result?.success && userIds.size > 0 && isAdminForThisPlace) {
            try {
                const courseId = Array.from(courseIds)[0];
                const courseName = courseId ? (await getCourseName(placeId, courseId)) || '코스' : '코스';
                const userIdToFirstRes = new Map<string, { reservedDateString: string; startTime: string }>();
                for (const { reservation } of reservationsToCancel) {
                    const uid = String(reservation?.userId ?? '');
                    if (uid && !userIdToFirstRes.has(uid)) {
                        userIdToFirstRes.set(uid, {
                            reservedDateString: String(reservation?.reservedDateString ?? ''),
                            startTime: String(reservation?.startTime ?? ''),
                        });
                    }
                }

                for (const userId of userIds) {
                    const first = userIdToFirstRes.get(userId);
                    const dateTimeStr = first ? formatDateTimeKr(first.reservedDateString, first.startTime).replace('시', '') : '';
                    const body = dateTimeStr ? `${dateTimeStr} 예약이 취소되었습니다` : '예약이 취소되었습니다.';
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: `${courseName} 예약이 취소되었습니다`,
                        body,
                        placeId,
                        data: {
                            reservationIds: reservationIds,
                            courseId,
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

/**
 * 관리자 멤버 등록 (기존 사용자: enrollments + place member, 미가입: pendingMembers)
 * - 클라이언트 Firestore 권한 이슈 회피 (서버에서 처리)
 */
export const registerMemberByAdmin = functions.https.onCall(async (data, context) => {
    const functionName = 'registerMemberByAdmin';
    logFunctionStart(functionName, {});

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const adminId = context.auth.uid;
    const placeId = String(data?.placeId ?? '').trim();
    const phoneNumber = String(data?.phoneNumber ?? '').trim();
    const name = String(data?.name ?? '').trim();
    const courseEnrollments = Array.isArray(data?.courseEnrollments) ? data.courseEnrollments as any[] : [];

    if (!placeId || !phoneNumber) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId와 phoneNumber가 필요합니다.');
    }

    const normalizedPhone = phoneNumber.replace(/\D/g, '');
    const koreaPhone = normalizedPhone.startsWith('82')
        ? '0' + normalizedPhone.slice(2)
        : normalizedPhone.startsWith('0')
            ? normalizedPhone
            : '0' + normalizedPhone;
    if (koreaPhone.length !== 11) {
        throw new functions.https.HttpsError('invalid-argument', '전화번호 형식이 올바르지 않습니다.');
    }

    await assertAdminForPlaceUid(adminId, placeId);

    const db = admin.firestore();
    const adminMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(adminId).get();
    const adminMemberData = adminMemberSnap.data();
    const adminRole = (adminMemberData?.role as string) ?? 'member';
    const isSubManager = adminRole === 'submanager' || adminRole === 'subManager';
    const rawManageable = adminMemberData?.manageableCourseIds;
    const manageableCourseIds: string[] = Array.isArray(rawManageable)
        ? (rawManageable as string[]).map((id: string) => String(id)).filter(Boolean)
        : [];

    if (isSubManager && manageableCourseIds.length === 0) {
        await demoteSubManagerToMemberIfNoCoursesInternal(db, placeId, adminId);
        throw new functions.https.HttpsError('permission-denied', '관리할 코스가 없습니다.');
    }

    let courseIds = courseEnrollments.map((e: any) => e?.courseId).filter(Boolean) as string[];
    if (isSubManager && manageableCourseIds.length > 0) {
        const allowedSet = new Set(manageableCourseIds);
        courseIds = courseIds.filter((id) => allowedSet.has(id));
    }
    if (courseIds.length === 0) {
        throw new functions.https.HttpsError('invalid-argument', '최소 1개 이상의 코스를 선택해주세요. (부매니저는 관리 코스만 등록 가능합니다.)');
    }
    const allowedCourseIdSet = new Set(courseIds);
    const courseEnrollmentsFiltered = courseEnrollments.filter((e: any) => e?.courseId && allowedCourseIdSet.has(String(e.courseId)));

    const pendingId = `${placeId}_${koreaPhone}`;
    const pendingRef = db.collection('places').doc(placeId).collection('pendingMembers').doc(pendingId);

    const pendingSnap = await pendingRef.get();
    if (pendingSnap.exists) {
        throw new functions.https.HttpsError('already-exists', '이미 해당 전화번호로 초대되었습니다.');
    }

    const userSnap = await db.collection('users').where('phoneNumber', '==', koreaPhone).limit(1).get();
    const existingUser = userSnap.empty ? null : userSnap.docs[0];
    const existingUserId = existingUser?.id ?? null;

    const now = admin.firestore.Timestamp.now();
    const enrollmentTime = now.toDate();

    const toDate = (v: unknown): Date => {
        if (!v) return enrollmentTime;
        if (typeof (v as any)?.toDate === 'function') return (v as admin.firestore.Timestamp).toDate();
        const d = new Date(v as any);
        return isNaN(d.getTime()) ? enrollmentTime : d;
    };

    if (existingUserId) {
        const memberRef = db.collection('places').doc(placeId).collection('members').doc(existingUserId);
        const existingMemberSnap = await memberRef.get();
        // 이미 멤버 문서가 있으면 role·manageableCourseIds는 덮어쓰지 않음 (코스매니저 지정 유지)
        if (existingMemberSnap.exists) {
            await memberRef.update({
                adminDisplayName: name || null,
                phoneNumber: koreaPhone,
                updatedAt: now,
            });
        } else {
            await memberRef.set({
                userId: existingUserId,
                role: 'member',
                adminDisplayName: name || null,
                phoneNumber: koreaPhone,
                manageableCourseIds: [],
                createdAt: now,
                updatedAt: now,
            }, { merge: true });
        }

        // Firestore 'in' 쿼리는 최대 30개 → 30개씩 청크 조회
        const existingCourseIds = new Set<string>();
        const IN_LIMIT = 30;
        for (let i = 0; i < courseIds.length; i += IN_LIMIT) {
            const chunk = courseIds.slice(i, i + IN_LIMIT);
            const snap = await db.collection('enrollments')
                .where('userId', '==', existingUserId)
                .where('placeId', '==', placeId)
                .where('courseId', 'in', chunk)
                .get();
            snap.docs.forEach(d => existingCourseIds.add(d.data().courseId as string));
        }

        const batch = db.batch();
        for (const ce of courseEnrollmentsFiltered) {
            const courseId = ce?.courseId;
            if (!courseId || existingCourseIds.has(courseId)) continue;

            let totalReservations = 10;
            // validFrom = 등록 시점(enrolledAt)과 동일하게 유지
            const validFrom = enrollmentTime;
            let validUntil = new Date(validFrom);
            validUntil.setFullYear(validUntil.getFullYear() + 1);
            if (ce.totalReservations != null) totalReservations = Number(ce.totalReservations);
            if (ce.validUntil) validUntil = toDate(ce.validUntil);

            // 수강 유효기간: validFrom = 등록 시점, validUntil = 마감일 23:59:59 (그날 전체)
            const untilParts = getSeoulDateParts(validUntil);
            const validUntilNorm = makeSeoulEndOfDay(untilParts.y, untilParts.mo, untilParts.d);

            const enrollmentId = `${existingUserId}_${placeId}_${courseId}`;
            const courseDoc = await db.collection('places').doc(placeId).collection('courses').doc(courseId).get();
            const courseData = courseDoc.data();
            const defaultTotal = courseData?.defaultTotalReservations ?? 10;
            if (ce.totalReservations == null) totalReservations = defaultTotal;

            const validFromDate = validFrom instanceof Date ? validFrom : new Date(validFrom);
            batch.set(db.collection('enrollments').doc(enrollmentId), {
                id: enrollmentId,
                userId: existingUserId,
                courseId,
                placeId,
                enrolledAt: now,
                validFrom: admin.firestore.Timestamp.fromDate(validFromDate),
                validUntil: admin.firestore.Timestamp.fromDate(validUntilNorm),
                totalReservations,
                remainingReservations: totalReservations,
                totalEnrollmentCount: 1,
                adminDisplayName: name || '',
            });
        }
        await batch.commit();
        logFunctionSuccess(functionName, { userId: existingUserId, enrollments: courseIds.length });
        return { success: true, existingUser: true, userId: existingUserId };
    } else {
        // pendingMembers에 과목별 totalReservations, validFrom, validUntil, remainingReservations 저장
        // → 가입 시 createEnrollmentsFromPendingMembers에서 enrollment로 정확히 이전
        const pendingCourseEnrollments: Array<{
            courseId: string;
            totalReservations: number;
            validFrom: admin.firestore.Timestamp;
            validUntil: admin.firestore.Timestamp;
            remainingReservations: number;
        }> = [];
        for (const ce of courseEnrollmentsFiltered) {
            const courseId = ce?.courseId;
            if (!courseId) continue;
            let totalReservations = 10;
            const validFrom = enrollmentTime;
            let validUntil = new Date(validFrom);
            validUntil.setFullYear(validUntil.getFullYear() + 1);
            if (ce.totalReservations != null) totalReservations = Number(ce.totalReservations);
            if (ce.validUntil) validUntil = toDate(ce.validUntil);
            const untilParts = getSeoulDateParts(validUntil);
            const validUntilNorm = makeSeoulEndOfDay(untilParts.y, untilParts.mo, untilParts.d);
            const validFromDate = validFrom instanceof Date ? validFrom : new Date(validFrom);
            pendingCourseEnrollments.push({
                courseId,
                totalReservations,
                validFrom: admin.firestore.Timestamp.fromDate(validFromDate),
                validUntil: admin.firestore.Timestamp.fromDate(validUntilNorm),
                remainingReservations: totalReservations,
            });
        }
        await pendingRef.set({
            placeId,
            phoneNumber: koreaPhone,
            invitedBy: adminId,
            role: 'member',
            allowedCourseIds: courseIds,
            courseEnrollments: pendingCourseEnrollments,
            adminDisplayName: name || null,
            createdAt: now,
        });
        logFunctionSuccess(functionName, { pending: true, courseCount: courseIds.length });
        return { success: true, existingUser: false };
    }
});

/**
 * 코스별 부매니저 초대 (pendingMembers에 role: subManager, allowedCourseIds에 courseId 추가/병합)
 * - 매니저만 호출 가능. 기존 pending이 있으면 allowedCourseIds에만 courseId 추가.
 */
export const inviteSubManagerForCourse = functions.https.onCall(async (data, context) => {
    const functionName = 'inviteSubManagerForCourse';
    logFunctionStart(functionName, {});

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const adminId = context.auth.uid;
    const placeId = String(data?.placeId ?? '').trim();
    const courseId = String(data?.courseId ?? '').trim();
    const phoneNumber = String(data?.phoneNumber ?? '').trim();
    const adminDisplayName = (data?.adminDisplayName as string)?.trim() || null;

    if (!placeId || !courseId || !phoneNumber) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId, courseId, phoneNumber가 필요합니다.');
    }

    const normalizedPhone = phoneNumber.replace(/\D/g, '');
    const koreaPhone = normalizedPhone.startsWith('82')
        ? '0' + normalizedPhone.slice(2)
        : normalizedPhone.startsWith('0')
            ? normalizedPhone
            : '0' + normalizedPhone;
    if (koreaPhone.length !== 11) {
        throw new functions.https.HttpsError('invalid-argument', '전화번호 형식이 올바르지 않습니다.');
    }

    await assertAdminForPlaceUid(adminId, placeId);

    const db = admin.firestore();
    const callerMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(adminId).get();
    const callerData = callerMemberSnap.data();
    const callerRole = String(callerData?.role ?? '').toLowerCase();
    if (callerRole === 'submanager') {
        throw new functions.https.HttpsError(
            'permission-denied',
            '부매니저 추가는 매니저만 할 수 있습니다.',
        );
    }

    const pendingId = `${placeId}_${koreaPhone}`;
    const pendingRef = db.collection('places').doc(placeId).collection('pendingMembers').doc(pendingId);
    const now = admin.firestore.Timestamp.now();

    const pendingSnap = await pendingRef.get();
    if (pendingSnap.exists) {
        const pendingData = pendingSnap.data() || {};
        const currentRole = (pendingData.role as string) || 'member';
        if (currentRole !== 'subManager' && currentRole !== 'submanager') {
            throw new functions.https.HttpsError(
                'failed-precondition',
                '이미 일반 멤버로 초대된 전화번호입니다. 부매니저는 별도 전화번호로 초대해주세요.',
            );
        }
        const beforeAllowed = Array.isArray(pendingData.allowedCourseIds)
            ? (pendingData.allowedCourseIds as string[]).map((id: string) => String(id)).filter(Boolean)
            : [];
        if (beforeAllowed.includes(courseId)) {
            logFunctionSuccess(functionName, { updated: false, alreadyHasCourse: true });
            return { success: true, alreadyHasCourse: true };
        }
        const nextAllowed = [...beforeAllowed, courseId];
        await pendingRef.update({
            role: 'submanager',
            allowedCourseIds: nextAllowed,
            ...(adminDisplayName != null ? { adminDisplayName } : {}),
            updatedAt: now,
        });
        logFunctionSuccess(functionName, { updated: true, allowedCourseIds: nextAllowed.length });
        return { success: true, updated: true };
    }

    const userSnap = await db.collection('users').where('phoneNumber', '==', koreaPhone).limit(1).get();
    if (!userSnap.empty) {
        const existingUserId = userSnap.docs[0].id;
        const memberRef = db.collection('places').doc(placeId).collection('members').doc(existingUserId);
        const memberSnap = await memberRef.get();
        const memberData = memberSnap.data() || {};
        const currentRole = String((memberData.role as string) ?? 'member').toLowerCase();
        const beforeIds = Array.isArray(memberData.manageableCourseIds)
            ? (memberData.manageableCourseIds as string[]).map((id: string) => String(id)).filter(Boolean)
            : [];
        if (beforeIds.includes(courseId)) {
            logFunctionSuccess(functionName, { existingMember: true, alreadyHasCourse: true });
            return { success: true, existingMember: true, alreadyHasCourse: true };
        }
        const nextIds = [...beforeIds, courseId];
        const updateData: Record<string, unknown> = {
            manageableCourseIds: nextIds,
            updatedAt: now,
        };
        if (adminDisplayName != null) (updateData as any).adminDisplayName = adminDisplayName;
        if (currentRole === 'member') {
            (updateData as any).role = 'submanager';
        }
        await memberRef.update(updateData);
        logFunctionSuccess(functionName, {
            existingMember: true,
            manageableCourseIds: nextIds.length,
            promoted: currentRole === 'member',
        });
        return { success: true, existingMember: true, promoted: currentRole === 'member' };
    }

    await pendingRef.set({
        placeId,
        phoneNumber: koreaPhone,
        invitedBy: adminId,
        role: 'submanager',
        allowedCourseIds: [courseId],
        adminDisplayName: adminDisplayName || null,
        createdAt: now,
    });
    logFunctionSuccess(functionName, { pending: true });
    return { success: true, pending: true };
});

/**
 * 코스별 부매니저 지정 취소 (해당 코스를 manageableCourseIds / allowedCourseIds에서 제거)
 * - 매니저 또는 해당 코스 관리 권한이 있는 부매니저만 호출 가능
 */
export const removeSubManagerFromCourse = functions.https.onCall(async (data, context) => {
    const functionName = 'removeSubManagerFromCourse';
    logFunctionStart(functionName, {});

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const callerId = context.auth.uid;
    const placeId = String(data?.placeId ?? '').trim();
    const courseId = String(data?.courseId ?? '').trim();
    const targetUserId = String(data?.targetUserId ?? '').trim();

    if (!placeId || !courseId || !targetUserId) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId, courseId, targetUserId가 필요합니다.');
    }

    await assertAdminForPlaceUid(callerId, placeId);

    const db = admin.firestore();
    const callerMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(callerId).get();
    const callerData = callerMemberSnap.data();
    const callerRole = String(callerData?.role ?? '').toLowerCase();
    const isSubManager = callerRole === 'submanager';
    const rawManageable = callerData?.manageableCourseIds;
    const manageableCourseIds: string[] = Array.isArray(rawManageable)
        ? (rawManageable as string[]).map((id: string) => String(id)).filter(Boolean)
        : [];
    if (isSubManager) {
        if (manageableCourseIds.length === 0) {
            await demoteSubManagerToMemberIfNoCoursesInternal(db, placeId, callerId);
            throw new functions.https.HttpsError('permission-denied', '관리할 코스가 없습니다.');
        }
        if (!manageableCourseIds.includes(courseId)) {
            throw new functions.https.HttpsError(
                'permission-denied',
                '이 코스에 대한 관리 권한이 없습니다.',
            );
        }
    }

    const now = admin.firestore.Timestamp.now();

    if (targetUserId.startsWith('pending_')) {
        const pendingDocId = targetUserId.slice('pending_'.length);
        const pendingRef = db.collection('places').doc(placeId).collection('pendingMembers').doc(pendingDocId);
        const pendingSnap = await pendingRef.get();
        if (!pendingSnap.exists) {
            return { success: true, removed: false, reason: 'pending_not_found' };
        }
        const pendingData = pendingSnap.data() || {};
        const beforeAllowed = Array.isArray(pendingData.allowedCourseIds)
            ? (pendingData.allowedCourseIds as string[]).map((id: string) => String(id)).filter(Boolean)
            : [];
        const nextAllowed = beforeAllowed.filter((id: string) => String(id) !== courseId);
        if (nextAllowed.length === beforeAllowed.length) {
            return { success: true, removed: false, reason: 'course_not_in_list' };
        }
        await pendingRef.update({
            allowedCourseIds: nextAllowed,
            updatedAt: now,
        });
        logFunctionSuccess(functionName, { pending: true, remainingCourses: nextAllowed.length });
        return { success: true, removed: true, pending: true };
    }

    const memberRef = db.collection('places').doc(placeId).collection('members').doc(targetUserId);
    const memberSnap = await memberRef.get();
    if (!memberSnap.exists) {
        return { success: true, removed: false, reason: 'member_not_found' };
    }
    const memberData = memberSnap.data() || {};
    const role = String(memberData.role ?? '').toLowerCase();
    if (role !== 'submanager') {
        return { success: true, removed: false, reason: 'not_submanager' };
    }
    const before = Array.isArray(memberData.manageableCourseIds)
        ? (memberData.manageableCourseIds as string[]).map((id: string) => String(id)).filter(Boolean)
        : [];
    const next = before.filter((id: string) => String(id) !== courseId);
    if (next.length === before.length) {
        return { success: true, removed: false, reason: 'course_not_in_list' };
    }
    const update: { manageableCourseIds: string[]; role?: string; updatedAt: admin.firestore.Timestamp } = {
        manageableCourseIds: next.length > 0 ? next : [],
        updatedAt: now,
    };
    if (next.length === 0) {
        update.role = 'member';
    }
    await memberRef.update(update);
    logFunctionSuccess(functionName, { removed: true, remainingCourses: next.length, demoted: next.length === 0 });
    return { success: true, removed: true, demoted: next.length === 0 };
});

/**
 * 기존 멤버(place/members 소속)에게 코스 추가 — 서버에서 enrollment 생성 (클라이언트 permission-denied 회피)
 */
export const addEnrollmentForExistingMember = functions.https.onCall(async (data, context) => {
    const functionName = 'addEnrollmentForExistingMember';
    logFunctionStart(functionName, {});

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const callerId = context.auth.uid;
    const placeId = String(data?.placeId ?? '').trim();
    const userId = String(data?.userId ?? '').trim();
    const adminDisplayName = String(data?.adminDisplayName ?? '').trim();
    const courseEnrollments = Array.isArray(data?.courseEnrollments) ? data.courseEnrollments as any[] : [];

    if (!placeId || !userId || courseEnrollments.length === 0) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId, userId, courseEnrollments가 필요합니다.');
    }

    await assertAdminForPlaceUid(callerId, placeId);

    const db = admin.firestore();
    const callerMemberSnap = await db.collection('places').doc(placeId).collection('members').doc(callerId).get();
    const callerData = callerMemberSnap.data();
    const callerRole = String(callerData?.role ?? '').toLowerCase();
    const isSubManager = callerRole === 'submanager';
    const rawManageable = callerData?.manageableCourseIds;
    const manageableCourseIds: string[] = Array.isArray(rawManageable)
        ? (rawManageable as string[]).map((id: string) => String(id)).filter(Boolean)
        : [];

    if (isSubManager && manageableCourseIds.length === 0) {
        await demoteSubManagerToMemberIfNoCoursesInternal(db, placeId, callerId);
        throw new functions.https.HttpsError('permission-denied', '관리할 코스가 없습니다.');
    }

    let courseEnrollmentsFiltered = courseEnrollments;
    if (isSubManager && manageableCourseIds.length > 0) {
        const allowedSet = new Set(manageableCourseIds);
        courseEnrollmentsFiltered = courseEnrollments.filter((e: any) => e?.courseId && allowedSet.has(String(e.courseId)));
    }
    if (courseEnrollmentsFiltered.length === 0) {
        throw new functions.https.HttpsError('invalid-argument', '최소 1개 이상의 코스를 선택해주세요. (부매니저는 관리 코스만 등록 가능합니다.)');
    }

    const now = admin.firestore.Timestamp.now();
    const enrollmentTime = now.toDate();

    const toDate = (v: unknown): Date => {
        if (!v) return enrollmentTime;
        if (typeof (v as any)?.toDate === 'function') return (v as admin.firestore.Timestamp).toDate();
        const d = new Date(v as any);
        return isNaN(d.getTime()) ? enrollmentTime : d;
    };

    const courseIds = courseEnrollmentsFiltered.map((e: any) => e?.courseId).filter(Boolean);
    const existingCourseIds = new Set<string>();
    const IN_LIMIT = 30;
    for (let i = 0; i < courseIds.length; i += IN_LIMIT) {
        const chunk = courseIds.slice(i, i + IN_LIMIT);
        const snap = await db.collection('enrollments')
            .where('userId', '==', userId)
            .where('placeId', '==', placeId)
            .where('courseId', 'in', chunk)
            .get();
        snap.docs.forEach(d => existingCourseIds.add(d.data().courseId as string));
    }

    const batch = db.batch();
    let added = 0;
    for (const ce of courseEnrollmentsFiltered) {
        const courseId = ce?.courseId;
        if (!courseId || existingCourseIds.has(courseId)) continue;

        let totalReservations = 10;
        // validFrom = 등록 시점(enrolledAt)과 동일하게 유지
        const validFrom = enrollmentTime;
        let validUntil = new Date(validFrom);
        validUntil.setFullYear(validUntil.getFullYear() + 1);
        if (ce.totalReservations != null) totalReservations = Number(ce.totalReservations);
        if (ce.validUntil) validUntil = toDate(ce.validUntil);

        const untilParts = getSeoulDateParts(validUntil);
        const validUntilNorm = makeSeoulEndOfDay(untilParts.y, untilParts.mo, untilParts.d);
        const validFromDate = validFrom instanceof Date ? validFrom : new Date(validFrom);

        const courseDoc = await db.collection('places').doc(placeId).collection('courses').doc(courseId).get();
        const courseData = courseDoc.data();
        if (ce.totalReservations == null && courseData?.defaultTotalReservations != null) {
            totalReservations = courseData.defaultTotalReservations as number;
        }

        const enrollmentId = `${userId}_${placeId}_${courseId}`;
        batch.set(db.collection('enrollments').doc(enrollmentId), {
            id: enrollmentId,
            userId,
            courseId,
            placeId,
            enrolledAt: now,
            validFrom: admin.firestore.Timestamp.fromDate(validFromDate),
            validUntil: admin.firestore.Timestamp.fromDate(validUntilNorm),
            totalReservations,
            remainingReservations: totalReservations,
            totalEnrollmentCount: 1,
            adminDisplayName: adminDisplayName || '',
        });
        added++;
    }
    await batch.commit();
    logFunctionSuccess(functionName, { userId, placeId, added });
    return { success: true, added };
});

/**
 * 부매니저가 관리 코스가 0개일 때 일반 멤버로 전락 (클라이언트에서 호출)
 * - caller가 해당 플레이스의 submanager이고 manageableCourseIds가 비어 있으면 role을 member로 변경
 */
export const demoteSubManagerToMemberIfNoCourses = functions.https.onCall(async (data, context) => {
    const functionName = 'demoteSubManagerToMemberIfNoCourses';
    logFunctionStart(functionName, {});

    if (!context.auth?.uid) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const uid = context.auth.uid;
    const placeId = String(data?.placeId ?? '').trim();
    if (!placeId) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId가 필요합니다.');
    }

    const db = admin.firestore();
    const memberRef = db.collection('places').doc(placeId).collection('members').doc(uid);
    const snap = await memberRef.get();
    if (!snap.exists) {
        return { demoted: false, reason: 'no_member_doc' };
    }
    const d = snap.data() as any;
    const role = String(d?.role ?? '').toLowerCase();
    if (role !== 'submanager') {
        return { demoted: false, reason: 'not_submanager' };
    }
    const manageableCourseIds = Array.isArray(d?.manageableCourseIds) ? (d.manageableCourseIds as string[]) : [];
    if (manageableCourseIds.length > 0) {
        return { demoted: false, reason: 'has_courses' };
    }

    await memberRef.update({
        role: 'member',
        manageableCourseIds: [],
        updatedAt: admin.firestore.Timestamp.now(),
    });
    logFunctionSuccess(functionName, { uid, placeId });
    return { demoted: true };
});

/**
 * 가입 시 사용자 문서 생성 (클라이언트 권한 이슈 회피)
 * - 인증된 사용자만 호출 가능
 * - users/{auth.uid} 에 username, phoneNumber 생성/병합 (name 필드 사용 안 함)
 */
export const createUserDoc = functions.https.onCall(async (data, context) => {
    const functionName = 'createUserDoc';
    logFunctionStart(functionName, {});

    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const uid = context.auth.uid;
    const username = typeof data?.username === 'string'
        ? (data.username as string).trim()
        : (typeof data?.name === 'string' ? (data.name as string).trim() : '');
    const phoneNumber = typeof data?.phoneNumber === 'string' ? (data.phoneNumber as string).trim() : '';
    if (!username || !phoneNumber) {
        throw new functions.https.HttpsError('invalid-argument', '이름과 전화번호가 필요합니다.');
    }

    const db = admin.firestore();
    const now = new Date();
    const ref = db.collection('users').doc(uid);
    await ref.set({
        userId: uid,
        username,
        phoneNumber,
        updatedAt: admin.firestore.Timestamp.fromDate(now),
        createdAt: admin.firestore.Timestamp.fromDate(now),
    }, { merge: true });

    logFunctionSuccess(functionName, { userId: uid });
    return { userId: uid, username, phoneNumber, createdAt: now.toISOString() };
});
