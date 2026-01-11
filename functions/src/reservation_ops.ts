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
    const sid = sessionIdOf(courseId, dayOfWeek, startTime);
    const srRef = db.collection('sessionReservations').doc(sessionReservationDocId(sid, reservedDateString));
    const srDoc = await tx.get(srRef);
    if (!srDoc.exists) return;
    const current = Number((srDoc.data() as any)?.reservedCount ?? 0);
    tx.update(srRef, {
        reservedCount: Math.max(0, current - 1),
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
    });
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
    if (count <= 0) return;
    const enrollmentQuery = db
        .collection('enrollments')
        .where('userId', '==', userId)
        .where('courseId', '==', courseId)
        .limit(1);
    const enrollmentSnap = await tx.get(enrollmentQuery as any);
    if (enrollmentSnap.empty) return;
    const enrollmentDoc = enrollmentSnap.docs[0];
    const enrollmentData = enrollmentDoc.data() as any;
    const remaining = Number((enrollmentData?.remainingReservations ?? 0) as any);
    const total = Number((enrollmentData?.totalReservations ?? 0) as any);
    const newRemaining = Math.min(total, remaining + count);
    tx.update(enrollmentDoc.ref, { remainingReservations: newRemaining });
}


