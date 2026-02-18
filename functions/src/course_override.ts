import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import { logFunctionStart, logFunctionSuccess, logFunctionError } from './logger';
import { assertAdminForPlaceUid, demoteSubManagerToMemberIfNoCoursesInternal, getManagerUidsForPlaceAndCourse } from './admin_auth';

/** 알림 본문용 날짜 포맷: "2026년 2월 17일" */
function formatDateKr(dateStr: string): string {
    const [yRaw, mRaw, dRaw] = (dateStr || '').split('-');
    const y = Number(yRaw);
    const mo = Number(mRaw);
    const d = Number(dRaw);
    if (!Number.isFinite(y) || !Number.isFinite(mo) || !Number.isFinite(d)) return dateStr;
    return `${y}년 ${mo}월 ${d}일`;
}

/** 알림 본문용 날짜+시간 포맷: "2026년 2월 17일 16:00시" */
function formatDateTimeKr(dateStr: string, timeStr: string): string {
    return `${formatDateKr(dateStr)} ${timeStr}시`;
}

/**
 * 비정기 일정 생성/수정/삭제 (관리자)
 * 
 * 비정기 일정은 특정 주에만 적용되는 일정 변경사항입니다.
 * - 추가: 정기 일정에 없는 새로운 세션 추가
 * - 취소: 정기 일정을 해당 주에만 취소
 * 
 * 취소 시: batchCancelReservations 로직 재활용하여 예약자 처리
 */
export const upsertCourseOverride = functions.https.onCall(async (data, context) => {
    const functionName = 'upsertCourseOverride';
    logFunctionStart(functionName, { userId: context.auth?.uid, ...data });

    if (!context.auth?.uid) {
        logFunctionError(functionName, new Error('Unauthenticated'), { data });
        throw new functions.https.HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const callerId = context.auth.uid;
    const placeId = String(data?.placeId ?? '');
    const courseId = String(data?.courseId ?? '');
    const date = String(data?.date ?? ''); // "YYYY-MM-DD"
    const dayOfWeek = Number(data?.dayOfWeek ?? 0);
    const startTime = String(data?.startTime ?? '');
    const endTime = String(data?.endTime ?? '');
    const capacity = Number(data?.capacity ?? 0);
    const isCancelled = data?.isCancelled === true;
    const weekStartDate = String(data?.weekStartDate ?? ''); // 해당 주 월요일 "YYYY-MM-DD"
    const action = String(data?.action ?? 'create'); // 'create' | 'update' | 'delete'
    const overrideId = String(data?.overrideId ?? '');
    const sendNotification = data?.sendNotification !== false; // 기본값: true

    if (!placeId || !courseId || !date || !weekStartDate) {
        throw new functions.https.HttpsError('invalid-argument', 'placeId, courseId, date, weekStartDate가 필요합니다.');
    }

    if (!dayOfWeek || dayOfWeek < 1 || dayOfWeek > 7) {
        throw new functions.https.HttpsError('invalid-argument', 'dayOfWeek는 1-7 사이여야 합니다.');
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
                '부매니저는 지정된 관리 코스의 비정기 일정만 편집할 수 있습니다.',
            );
        }
    }

    // add와 cancel은 별도 문서: add = courseId_date_startTime, cancel = courseId_date_startTime_cancel
    const baseId = `${courseId}_${date}_${startTime}`;
    const finalOverrideId = overrideId || (isCancelled ? `${baseId}_cancel` : baseId);
    const overrideRef = db.collection('courseOverrides').doc(finalOverrideId);

    if (action === 'delete') {
        // 삭제:
        // - cancel override(정기 취소) 삭제 = 정기 세션 복원 (예약 삭제 X)
        // - add override(비정기 추가) 삭제 = 세션 자체 삭제 (예약/크레딧 정리)
        const existingDoc = await overrideRef.get();
        const existingData = existingDoc.exists ? (existingDoc.data() as any) : null;
        const existingIsCancelled = existingData?.isCancelled === true;
        const effDate = String(existingData?.date ?? date);
        const effDayOfWeek = Number(existingData?.dayOfWeek ?? dayOfWeek);
        const effStartTime = String(existingData?.startTime ?? startTime ?? '');

        // cancel override 삭제는 복원 목적이므로 예약은 유지
        if (existingIsCancelled) {
            if (!effDate || !effStartTime || !effDayOfWeek) {
                // 문서가 오염된 경우라도 override 삭제는 진행
                await overrideRef.delete();
                logFunctionSuccess(functionName, { overrideId: finalOverrideId, action: 'delete', restored: true, clearedSrCancel: false });
                return { success: true, overrideId: finalOverrideId };
            }

            // cancel override 삭제 = 복원. createReservation은 courseOverrides isCancelled로 취소 여부 판단.
            await overrideRef.delete();
            logFunctionSuccess(functionName, { overrideId: finalOverrideId, action: 'delete', restored: true });
            return { success: true, overrideId: finalOverrideId };
        }

        // add override 삭제: 세션 자체 삭제로 간주 → 해당 세션 예약/크레딧 정리
        if (!effDate || !effStartTime || !effDayOfWeek) {
            throw new functions.https.HttpsError(
                'invalid-argument',
                '비정기 세션 삭제에는 date/dayOfWeek/startTime이 필요합니다.'
            );
        }

        // 해당 날짜의 예약 조회 (글로벌 reservations)
        const reservationQuery = db
            .collection('reservations')
            .where('placeId', '==', placeId)
            .where('courseId', '==', courseId)
            .where('dayOfWeek', '==', effDayOfWeek)
            .where('startTime', '==', effStartTime)
            .where('reservedDateString', '==', effDate);

        const reservationSnapshot = await reservationQuery.get();
        const reservationIds: string[] = [];
        const userIds = new Set<string>();
        const enrollmentRefByUserId = new Map<string, FirebaseFirestore.DocumentReference>();
        const pendingRefByPendingId = new Map<string, FirebaseFirestore.DocumentReference>();

        for (const doc of reservationSnapshot.docs) {
            const r = doc.data() as any;
            reservationIds.push(doc.id);
            const uid = String(r?.userId ?? '');
            if (!uid) continue;
            userIds.add(uid);

            const reservationEnrollmentId = String(r?.enrollmentId ?? '');
            if (!reservationEnrollmentId) continue; // 일회성 더미: 환불 대상 제외

            // pending 멤버 크레딧 복구 준비
            if (uid.startsWith('pending_')) {
                const pendingId = uid.replace('pending_', '');
                if (pendingId) {
                    pendingRefByPendingId.set(pendingId, db.collection('places').doc(placeId).collection('pendingMembers').doc(pendingId));
                }
                continue;
            }

            // enrollment 조회
            const enrollmentQuery = db
                .collection('enrollments')
                .where('userId', '==', uid)
                .where('courseId', '==', courseId)
                .where('placeId', '==', placeId)
                .limit(1);
            const enrollmentSnapshot = await enrollmentQuery.get();
            if (!enrollmentSnapshot.empty) {
                enrollmentRefByUserId.set(uid, enrollmentSnapshot.docs[0].ref);
            }
        }

        await db.runTransaction(async (tx) => {
            // enrollment 문서 다시 읽기
            const enrollmentDocsByUserId = new Map<string, FirebaseFirestore.DocumentSnapshot>();
            for (const [uid, ref] of enrollmentRefByUserId.entries()) {
                enrollmentDocsByUserId.set(uid, await tx.get(ref));
            }
            const pendingDocsByPendingId = new Map<string, FirebaseFirestore.DocumentSnapshot>();
            for (const [pendingId, ref] of pendingRefByPendingId.entries()) {
                pendingDocsByPendingId.set(pendingId, await tx.get(ref));
            }

            // 예약 삭제 및 enrollment 복구 (일회성 더미는 삭제만)
            for (const doc of reservationSnapshot.docs) {
                const r = doc.data() as any;
                tx.delete(doc.ref);

                const uid = String(r?.userId ?? '');
                if (!uid) continue;
                if (String(r?.enrollmentId ?? '') === '') continue; // 일회성 더미: 환불 스킵

                // ✅ enrollment/pending 크레딧 복구(최대 total까지 clamp)
                if (uid.startsWith('pending_')) {
                    const pendingId = uid.replace('pending_', '');
                    const pendingDoc = pendingDocsByPendingId.get(pendingId);
                    if (pendingDoc?.exists) {
                        const pendingData = pendingDoc.data() as any;
                        if (!Array.isArray(pendingData?.courseEnrollments)) continue;
                        const courseEnrollments = pendingData.courseEnrollments;
                        const updated = courseEnrollments.map((ce: any) => {
                            if (String(ce?.courseId ?? '') !== courseId) return ce;
                            const total = Number(ce?.totalReservations ?? 0);
                            const remainingBase = Number(ce?.remainingReservations ?? total);
                            const newRemaining = Math.min(total, remainingBase + 1);
                            return { ...ce, remainingReservations: newRemaining };
                        });
                        tx.update(pendingDoc.ref, { courseEnrollments: updated });
                    }
                } else {
                    const enrollmentDoc = enrollmentDocsByUserId.get(uid);
                    if (enrollmentDoc?.exists) {
                        const currentRemaining = Number((enrollmentDoc.data() as any)?.remainingReservations ?? 0);
                        const total = Number((enrollmentDoc.data() as any)?.totalReservations ?? 0);
                        const newRemaining = Math.min(total, currentRemaining + 1);
                        tx.update(enrollmentDoc.ref, { remainingReservations: newRemaining });
                    }
                }
            }

            // override 문서 삭제 (세션 자체 삭제)
            tx.delete(overrideRef);
        });

        // 알림 전송 (예약자가 있었고, sendNotification이 true일 때만)
        if (reservationIds.length > 0 && sendNotification) {
            try {
                for (const userId of userIds) {
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: '세션 취소',
                        body: `${formatDateTimeKr(effDate, effStartTime)} 세션이 취소되었습니다`,
                        placeId,
                        data: {
                            courseId,
                            date: effDate,
                            dayOfWeek: effDayOfWeek,
                            startTime: effStartTime,
                            placeId,
                        },
                        isAdmin: false,
                    });
                }
                // 매니저·코스매니저에게도 푸시 알림 (해당 코스 관리자)
                const adminUids = await getManagerUidsForPlaceAndCourse(placeId, courseId);
                for (const uid of adminUids) {
                    if (uid === callerId) continue;
                    await createNotification({
                        userId: uid,
                        type: 'system',
                        title: '비정기 일정 변경',
                        body: `${formatDateTimeKr(effDate, effStartTime)} 세션이 취소되었습니다`,
                        placeId,
                        data: { courseId, placeId, date: effDate, startTime: effStartTime, kind: 'override-delete' },
                        isAdmin: true,
                    });
                }
            } catch (error) {
                console.error(`[upsertCourseOverride] Error creating notifications (delete):`, error);
            }
        }

        logFunctionSuccess(functionName, {
            overrideId: finalOverrideId,
            action: 'delete',
            deletedReservations: reservationIds.length,
        });
        return { success: true, overrideId: finalOverrideId };
    }

    // 취소인 경우: 기존 예약자 처리 (batchCancelReservations 로직 재활용)
    if (isCancelled) {
        // 해당 날짜의 예약 조회 (글로벌 reservations)
        const reservationQuery = db
            .collection('reservations')
            .where('placeId', '==', placeId)
            .where('courseId', '==', courseId)
            .where('dayOfWeek', '==', dayOfWeek)
            .where('startTime', '==', startTime)
            .where('reservedDateString', '==', date);

        const reservationSnapshot = await reservationQuery.get();
        const reservationIds: string[] = [];
        const userIds = new Set<string>();
        const enrollmentRefByUserId = new Map<string, FirebaseFirestore.DocumentReference>();
        const pendingRefByPendingId = new Map<string, FirebaseFirestore.DocumentReference>();

        for (const doc of reservationSnapshot.docs) {
            const r = doc.data() as any;
            reservationIds.push(doc.id);
            const uid = String(r?.userId ?? '');
            if (!uid) continue;
            userIds.add(uid);

            const reservationEnrollmentId = String(r?.enrollmentId ?? '');
            if (!reservationEnrollmentId) continue; // 일회성 더미 예약: 차감한 적 없으므로 환불 대상에서 제외(ref만 수집 안 함, 삭제는 아래에서 수행)

            if (uid.startsWith('pending_')) {
                const pendingId = uid.replace('pending_', '');
                if (pendingId) {
                    pendingRefByPendingId.set(pendingId, db.collection('places').doc(placeId).collection('pendingMembers').doc(pendingId));
                }
                continue;
            }

            // enrollment 조회
            const enrollmentQuery = db
                .collection('enrollments')
                .where('userId', '==', uid)
                .where('courseId', '==', courseId)
                .where('placeId', '==', placeId)
                .limit(1);
            const enrollmentSnapshot = await enrollmentQuery.get();
            if (!enrollmentSnapshot.empty) {
                enrollmentRefByUserId.set(uid, enrollmentSnapshot.docs[0].ref);
            }
        }

        // 트랜잭션: 예약 취소 + enrollment 복구 (reservations만 사용)
        await db.runTransaction(async (tx) => {
            const enrollmentDocsByUserId = new Map<string, FirebaseFirestore.DocumentSnapshot>();
            for (const [uid, ref] of enrollmentRefByUserId.entries()) {
                enrollmentDocsByUserId.set(uid, await tx.get(ref));
            }
            const pendingDocsByPendingId = new Map<string, FirebaseFirestore.DocumentSnapshot>();
            for (const [pendingId, ref] of pendingRefByPendingId.entries()) {
                pendingDocsByPendingId.set(pendingId, await tx.get(ref));
            }

            // 예약 삭제 및 enrollment 복구 (일회성 더미는 삭제만, 환불 없음)
            for (const doc of reservationSnapshot.docs) {
                const r = doc.data() as any;
                tx.delete(doc.ref);

                const uid = String(r?.userId ?? '');
                if (!uid) continue;
                if (String(r?.enrollmentId ?? '') === '') continue; // 일회성 더미: 차감한 적 없으므로 환불 스킵

                // ✅ enrollment/pending 크레딧 복구(최대 total까지 clamp)
                if (uid.startsWith('pending_')) {
                    const pendingId = uid.replace('pending_', '');
                    const pendingDoc = pendingDocsByPendingId.get(pendingId);
                    if (pendingDoc?.exists) {
                        const pendingData = pendingDoc.data() as any;
                        if (!Array.isArray(pendingData?.courseEnrollments)) continue;
                        const courseEnrollments = pendingData.courseEnrollments;
                        const updated = courseEnrollments.map((ce: any) => {
                            if (String(ce?.courseId ?? '') !== courseId) return ce;
                            const total = Number(ce?.totalReservations ?? 0);
                            const remainingBase = Number(ce?.remainingReservations ?? total);
                            const newRemaining = Math.min(total, remainingBase + 1);
                            return { ...ce, remainingReservations: newRemaining };
                        });
                        tx.update(pendingDoc.ref, { courseEnrollments: updated });
                    }
                } else {
                    const enrollmentDoc = enrollmentDocsByUserId.get(uid);
                    if (enrollmentDoc?.exists) {
                        const currentRemaining = Number((enrollmentDoc.data() as any)?.remainingReservations ?? 0);
                        const total = Number((enrollmentDoc.data() as any)?.totalReservations ?? 0);
                        const newRemaining = Math.min(total, currentRemaining + 1);
                        tx.update(enrollmentDoc.ref, { remainingReservations: newRemaining });
                    }
                }
            }
            // 취소 여부는 courseOverride 문서(isCancelled: true)로만 판단.
        });

        // 알림 전송 (트랜잭션 외부, sendNotification이 true일 때만)
        if (reservationIds.length > 0 && sendNotification) {
            try {
                for (const userId of userIds) {
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: '세션 취소',
                        body: `${formatDateTimeKr(date, startTime)} 세션이 취소되었습니다`,
                        placeId,
                        data: {
                            courseId,
                            date,
                            dayOfWeek,
                            startTime,
                            placeId,
                        },
                        isAdmin: false,
                    });
                }
                // 매니저·코스매니저에게도 푸시 알림 (해당 코스 관리자)
                const adminUids = await getManagerUidsForPlaceAndCourse(placeId, courseId);
                for (const uid of adminUids) {
                    if (uid === callerId) continue;
                    await createNotification({
                        userId: uid,
                        type: 'system',
                        title: '비정기 일정 변경',
                        body: `${formatDateTimeKr(date, startTime)} 세션이 취소되었습니다`,
                        placeId,
                        data: { courseId, placeId, date, startTime, kind: 'override-cancel' },
                        isAdmin: true,
                    });
                }
            } catch (error) {
                console.error(`[upsertCourseOverride] Error creating notifications:`, error);
            }
        }
    }

    const sessionIdVal = `${courseId}_${dayOfWeek}_${startTime}`;

    // 비정기 일정 저장 (type: cancel | add)
    const overrideData: any = {
        id: finalOverrideId,
        courseId,
        placeId,
        date,
        sessionId: sessionIdVal,
        type: isCancelled ? 'cancel' : 'add',
        dayOfWeek,
        isCancelled,
        weekStartDate,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    if (!isCancelled) {
        // 추가인 경우
        if (!startTime || !endTime || capacity <= 0) {
            throw new functions.https.HttpsError('invalid-argument', '추가 일정의 경우 startTime, endTime, capacity가 필요합니다.');
        }
        overrideData.startTime = startTime;
        overrideData.endTime = endTime;
        overrideData.capacity = capacity;
    } else {
        // 취소인 경우 startTime만 저장 (어떤 정기 일정을 취소했는지 식별용)
        overrideData.startTime = startTime;
    }

    await overrideRef.set(overrideData, { merge: true });

    // 비정기일정 추가 시 수강생 알림 제거 (요청사항: 알림 보내지 않음)
    // 매니저·코스매니저에게는 비정기 일정 추가 알림 전송 (푸시 수신)
    if (sendNotification && !isCancelled) {
        try {
            const adminUids = await getManagerUidsForPlaceAndCourse(placeId, courseId);
            for (const uid of adminUids) {
                if (uid === callerId) continue;
                await createNotification({
                    userId: uid,
                    type: 'system',
                    title: '비정기 일정 추가',
                    body: `${formatDateTimeKr(date, startTime)} 세션이 추가되었습니다`,
                    placeId,
                    data: { courseId, placeId, date, startTime, kind: 'override-add' },
                    isAdmin: true,
                });
            }
        } catch (error) {
            console.error(`[upsertCourseOverride] Error creating admin notifications (add):`, error);
        }
    }

    logFunctionSuccess(functionName, { overrideId: finalOverrideId, action, isCancelled });
    return { success: true, overrideId: finalOverrideId };
});

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
        await admin.firestore()
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
        console.log(`[createNotification] Created notification for user ${userId}, type: ${type}`);
    } catch (error) {
        console.error(`[createNotification] Error creating notification:`, error);
        // 알림 생성 실패해도 메인 로직은 계속 진행
    }
}

