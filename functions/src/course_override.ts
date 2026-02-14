import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import { logFunctionStart, logFunctionSuccess, logFunctionError } from './logger';
import { assertAdminForPlaceUid } from './admin_auth';
import { getPlaceOrThrow, getCourseName } from './course_catalog';

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

    // overrideId 생성 (없으면 생성)
    const finalOverrideId = overrideId || `${courseId}_${date}_${startTime}_${isCancelled ? 'cancel' : 'add'}`;
    const overrideRef = db.collection('courseOverrides').doc(finalOverrideId);

    if (action === 'delete') {
        // 삭제:
        // - cancel override(정기 취소) 삭제 = 정기 세션 복원 (예약 삭제 X)
        // - add override(비정기 추가) 삭제 = 세션 자체 삭제 (예약/크레딧/sessionReservations까지 정리)
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

            // ✅ createReservation은 sessionReservations.isCancelled로 취소 여부를 판단하므로,
            // cancel override 삭제(복원) 시 sessionReservations의 취소 마커도 함께 해제해야 함.
            const sessionId = `${courseId}_${effDayOfWeek}_${effStartTime}`;
            const srRef = db.collection('sessionReservations').doc(`${sessionId}_${effDate}`);
            await db.runTransaction(async (tx) => {
                const srDoc = await tx.get(srRef);
                if (srDoc.exists) {
                    const reservedCount = Number((srDoc.data() as any)?.reservedCount ?? 0);
                    // 예약이 0이면 문서 자체를 제거(유령 cancel 마커 방지), 아니면 cancel만 해제
                    if (reservedCount <= 0) {
                        tx.delete(srRef);
                    } else {
                        tx.update(srRef, {
                            isCancelled: false,
                            lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                        });
                    }
                }
                tx.delete(overrideRef);
            });
            logFunctionSuccess(functionName, { overrideId: finalOverrideId, action: 'delete', restored: true });
            return { success: true, overrideId: finalOverrideId };
        }

        // add override 삭제: 세션 자체 삭제로 간주 → 해당 세션 예약/크레딧/sessionReservations 정리
        if (!effDate || !effStartTime || !effDayOfWeek) {
            throw new functions.https.HttpsError(
                'invalid-argument',
                '비정기 세션 삭제에는 date/dayOfWeek/startTime이 필요합니다.'
            );
        }

        // 해당 날짜의 예약 조회
        const reservationQuery = db
            .collection('places')
            .doc(placeId)
            .collection('reservations')
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

            // pending 멤버 크레딧 복구 준비
            if (uid.startsWith('pending_')) {
                const pendingId = uid.replace('pending_', '');
                if (pendingId) {
                    pendingRefByPendingId.set(pendingId, db.collection('pendingMembers').doc(pendingId));
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

            // sessionReservations 조회 (비정기 세션도 동일한 sessionId 규칙)
            const sessionId = `${courseId}_${effDayOfWeek}_${effStartTime}`;
            const srRef = db.collection('sessionReservations').doc(`${sessionId}_${effDate}`);
            const srDoc = await tx.get(srRef);

            // 예약 삭제 및 enrollment 복구
            for (const doc of reservationSnapshot.docs) {
                const r = doc.data() as any;
                tx.delete(doc.ref);

                const uid = String(r?.userId ?? '');
                if (!uid) continue;

                // ✅ enrollment/pending 크레딧 복구(최대 total까지 clamp)
                if (uid.startsWith('pending_')) {
                    const pendingId = uid.replace('pending_', '');
                    const pendingDoc = pendingDocsByPendingId.get(pendingId);
                    if (pendingDoc?.exists) {
                        const pendingData = pendingDoc.data() as any;
                        const courseEnrollments = Array.isArray(pendingData?.courseEnrollments) ? pendingData.courseEnrollments : [];
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

            // sessionReservations는 세션 자체가 삭제되므로 문서 제거 (남아있으면 '유령 카운트'가 될 수 있음)
            if (srDoc.exists) {
                tx.delete(srRef);
            }

            // override 문서 삭제 (세션 자체 삭제)
            tx.delete(overrideRef);
        });

        // 알림 전송 (예약자가 있었고, sendNotification이 true일 때만)
        if (reservationIds.length > 0 && sendNotification) {
            try {
                const place = await getPlaceOrThrow(placeId);
                const courseName = getCourseName(place, courseId);

                for (const userId of userIds) {
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: '세션이 취소되었습니다',
                        body: `${courseName} - ${effDate} ${effStartTime} 세션이 취소되었습니다`,
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
        // 해당 날짜의 예약 조회
        const reservationQuery = db
            .collection('places')
            .doc(placeId)
            .collection('reservations')
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

            if (uid.startsWith('pending_')) {
                const pendingId = uid.replace('pending_', '');
                if (pendingId) {
                    pendingRefByPendingId.set(pendingId, db.collection('pendingMembers').doc(pendingId));
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

        // 트랜잭션: 예약 취소 + enrollment 복구 + sessionReservations 업데이트
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

            // sessionReservations 조회
            const sessionId = `${courseId}_${dayOfWeek}_${startTime}`;
            const srRef = db.collection('sessionReservations').doc(`${sessionId}_${date}`);
            const srDoc = await tx.get(srRef);

            // 예약 삭제 및 enrollment 복구
            for (const doc of reservationSnapshot.docs) {
                const r = doc.data() as any;
                tx.delete(doc.ref);

                const uid = String(r?.userId ?? '');
                if (!uid) continue;

                // ✅ enrollment/pending 크레딧 복구(최대 total까지 clamp)
                if (uid.startsWith('pending_')) {
                    const pendingId = uid.replace('pending_', '');
                    const pendingDoc = pendingDocsByPendingId.get(pendingId);
                    if (pendingDoc?.exists) {
                        const pendingData = pendingDoc.data() as any;
                        const courseEnrollments = Array.isArray(pendingData?.courseEnrollments) ? pendingData.courseEnrollments : [];
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

            // sessionReservations 업데이트
            // ✅ createReservation은 sessionReservations.isCancelled를 보고 취소를 강제하므로,
            // sr 문서가 없더라도 "취소 마커"는 반드시 남겨야 함.
            const currentReservedCount = srDoc.exists ? Number((srDoc.data() as any)?.reservedCount ?? 0) : 0;
            const nextReservedCount = Math.max(0, currentReservedCount - reservationIds.length);
            if (srDoc.exists) {
                tx.update(srRef, {
                    reservedCount: nextReservedCount,
                    isCancelled: true,
                    lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                });
            } else {
                tx.set(srRef, {
                    id: `${sessionId}_${date}`,
                    sessionId,
                    courseId,
                    placeId,
                    dayOfWeek,
                    startTime,
                    date,
                    reservedCount: 0,
                    isCancelled: true,
                    lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });
            }
        });

        // 알림 전송 (트랜잭션 외부, sendNotification이 true일 때만)
        if (reservationIds.length > 0 && sendNotification) {
            try {
                const place = await getPlaceOrThrow(placeId);
                const courseName = getCourseName(place, courseId);

                for (const userId of userIds) {
                    await createNotification({
                        userId,
                        type: 'reservation',
                        title: '세션이 취소되었습니다',
                        body: `${courseName} - ${date} ${startTime} 세션이 취소되었습니다`,
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
            } catch (error) {
                console.error(`[upsertCourseOverride] Error creating notifications:`, error);
            }
        }
    }

    // 비정기 일정 저장
    const overrideData: any = {
        id: finalOverrideId,
        courseId,
        placeId,
        date,
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

    // 추가인 경우 알림 전송 (관리자 설정 확인)
    if (!isCancelled && action === 'create' && sendNotification) {
        try {
            // 플레이스 설정에서 비정기 일정 알림 활성화 여부 확인
            const placeDoc = await db.collection('places').doc(placeId).get();
            const placeData = placeDoc.data();
            const notifyOnOverrideAdd = placeData?.notifyOnOverrideAdd ?? true; // 기본값: true

            if (notifyOnOverrideAdd) {
                // 해당 코스에 등록된 멤버에게만 알림
                const enrollmentsSnapshot = await db
                    .collection('enrollments')
                    .where('placeId', '==', placeId)
                    .where('courseId', '==', courseId)
                    .where('status', '==', 'active')
                    .get();

                const place = await getPlaceOrThrow(placeId);
                const courseName = getCourseName(place, courseId);

                const notificationPromises = enrollmentsSnapshot.docs.map(async (doc) => {
                    const enrollment = doc.data();
                    const userId = enrollment.userId;

                    return createNotification({
                        userId,
                        type: 'system',
                        title: '새로운 수업 일정이 추가되었습니다',
                        body: `${courseName} - ${date} ${startTime}-${endTime} (${capacity}명)`,
                        placeId,
                        data: {
                            courseId,
                            date,
                            dayOfWeek,
                            startTime,
                            endTime,
                            capacity,
                            placeId,
                        },
                        isAdmin: false,
                    });
                });

                await Promise.allSettled(notificationPromises);
            }
        } catch (error) {
            console.error(`[upsertCourseOverride] Error creating add notifications:`, error);
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

