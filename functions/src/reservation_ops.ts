import * as admin from 'firebase-admin';

type Tx = FirebaseFirestore.Transaction;

export function sessionIdOf(courseId: string, dayOfWeek: number, startTime: string): string {
    return `${courseId}_${dayOfWeek}_${startTime}`;
}

export function sessionReservationDocId(sessionId: string, dateString: string): string {
    return `${sessionId}_${dateString}`;
}

export async function decrementSessionReservedCountIfExists(
    tx: Tx,
    db: FirebaseFirestore.Firestore,
    courseId: string,
    dayOfWeek: number,
    startTime: string,
    reservedDateString: string,
): Promise<void> {
    try {
        const sid = sessionIdOf(courseId, dayOfWeek, startTime);
        const srRef = db.collection('sessionReservations').doc(sessionReservationDocId(sid, reservedDateString));
        const srDoc = await tx.get(srRef);
        if (!srDoc.exists) {
            console.log(`[decrementSessionReservedCount] SessionReservation not found. sessionId=${sid}, date=${reservedDateString}`);
            return;
        }
        const current = Number((srDoc.data() as any)?.reservedCount ?? 0);
        const newCount = Math.max(0, current - 1);
        console.log(`[decrementSessionReservedCount] Decrementing. sessionId=${sid}, date=${reservedDateString}, count=${current} -> ${newCount}`);
        tx.update(srRef, {
            reservedCount: newCount,
            lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        });
    } catch (error) {
        console.error(`[decrementSessionReservedCount] Error:`, error);
        throw error; // 트랜잭션 내부에서 발생한 에러는 그대로 throw하여 트랜잭션 실패 처리
    }
}

export async function incrementSessionReservedCountUpsert(
    tx: Tx,
    db: FirebaseFirestore.Firestore,
    params: {
        sessionId: string;
        srRef: FirebaseFirestore.DocumentReference;
        srDoc: FirebaseFirestore.DocumentSnapshot;
        courseId: string;
        placeId: string;
        dayOfWeek: number;
        startTime: string;
        reservedDateString: string;
        capacity: number;
        currentReservedCount: number;
    },
): Promise<void> {
    const {
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
    } = params;

    const srDocId = sessionReservationDocId(sessionId, reservedDateString);
    if (!srDoc.exists) {
        tx.set(srRef, {
            id: srDocId,
            sessionId,
            courseId,
            placeId,
            dayOfWeek,
            startTime,
            date: reservedDateString,
            capacity,
            reservedCount: 1,
            lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    } else {
        tx.update(srRef, {
            reservedCount: currentReservedCount + 1,
            lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
}

export async function restoreEnrollmentCreditsForCancelledReservations(
    tx: Tx,
    db: FirebaseFirestore.Firestore,
    userId: string,
    courseId: string,
    count: number,
): Promise<void> {
    if (count <= 0) {
        console.log(`[restoreEnrollmentCredits] count <= 0, skipping. userId=${userId}, courseId=${courseId}, count=${count}`);
        return;
    }
    try {
        const enrollmentQuery = db
            .collection('enrollments')
            .where('userId', '==', userId)
            .where('courseId', '==', courseId)
            .limit(1);
        const enrollmentSnap = await tx.get(enrollmentQuery as any);
        if (enrollmentSnap.empty) {
            console.warn(`[restoreEnrollmentCredits] Enrollment not found. userId=${userId}, courseId=${courseId}`);
            return;
        }
        const enrollmentDoc = enrollmentSnap.docs[0];
        const enrollmentData = enrollmentDoc.data() as any;
        const remaining = Number((enrollmentData?.remainingReservations ?? 0) as any);
        const total = Number((enrollmentData?.totalReservations ?? 0) as any);
        const newRemaining = Math.min(total, remaining + count);
        console.log(`[restoreEnrollmentCredits] Restoring credits. userId=${userId}, courseId=${courseId}, remaining=${remaining} -> ${newRemaining}, total=${total}, count=${count}`);
        tx.update(enrollmentDoc.ref, { remainingReservations: newRemaining });
    } catch (error) {
        console.error(`[restoreEnrollmentCredits] Error:`, error);
        throw error; // 트랜잭션 내부에서 발생한 에러는 그대로 throw하여 트랜잭션 실패 처리
    }
}


