import * as admin from 'firebase-admin';

type Tx = FirebaseFirestore.Transaction;
const COLLECTION = 'reservationSummary';

function docId(sessionId: string, dateString: string): string {
    return `${sessionId}_${dateString}`;
}

/** 예약 생성 시: reservedCount +1 (없으면 생성). 트랜잭션 규칙 준수: readsBeforeWrites가 있으면 get 생략(호출 측에서 쓰기 전에 읽어 둔 스냅샷 전달) */
export async function incrementReservedCount(
    tx: Tx,
    db: FirebaseFirestore.Firestore,
    params: {
        sessionId: string;
        courseId: string;
        placeId: string;
        dayOfWeek: number;
        startTime: string;
        reservedDateString: string;
        capacity: number;
    },
    readsBeforeWrites?: FirebaseFirestore.DocumentSnapshot,
): Promise<void> {
    const { sessionId, courseId, placeId, dayOfWeek, startTime, reservedDateString, capacity } = params;
    const ref = db.collection(COLLECTION).doc(docId(sessionId, reservedDateString));
    const snap: FirebaseFirestore.DocumentSnapshot = readsBeforeWrites ?? await tx.get(ref);

    if (!snap.exists) {
        tx.set(ref, {
            id: docId(sessionId, reservedDateString),
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
        tx.update(ref, {
            reservedCount: admin.firestore.FieldValue.increment(1),
            lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
}

/** 배치 예약 생성 시: reservedCount +delta (한 번에 N명 반영). readsBeforeWrites 있으면 get 생략 */
export async function incrementReservedCountBy(
    tx: Tx,
    db: FirebaseFirestore.Firestore,
    params: {
        sessionId: string;
        courseId: string;
        placeId: string;
        dayOfWeek: number;
        startTime: string;
        reservedDateString: string;
        capacity: number;
    },
    delta: number,
    readsBeforeWrites?: FirebaseFirestore.DocumentSnapshot,
): Promise<void> {
    if (delta <= 0) return;
    const { sessionId, courseId, placeId, dayOfWeek, startTime, reservedDateString, capacity } = params;
    const ref = db.collection(COLLECTION).doc(docId(sessionId, reservedDateString));
    const snap: FirebaseFirestore.DocumentSnapshot = readsBeforeWrites ?? await tx.get(ref);

    if (!snap.exists) {
        tx.set(ref, {
            id: docId(sessionId, reservedDateString),
            sessionId,
            courseId,
            placeId,
            dayOfWeek,
            startTime,
            date: reservedDateString,
            capacity,
            reservedCount: delta,
            lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    } else {
        tx.update(ref, {
            reservedCount: admin.firestore.FieldValue.increment(delta),
            lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
}

/** 배치 예약 이동/취소 시: reservedCount -delta (0 이하면 문서 삭제). readsBeforeWrites 있으면 get 생략 */
export async function decrementReservedCountBy(
    tx: Tx,
    db: FirebaseFirestore.Firestore,
    params: {
        sessionId: string;
        reservedDateString: string;
    },
    delta: number,
    readsBeforeWrites?: FirebaseFirestore.DocumentSnapshot,
): Promise<void> {
    if (delta <= 0) return;
    const { sessionId, reservedDateString } = params;
    const ref = db.collection(COLLECTION).doc(docId(sessionId, reservedDateString));
    const snap: FirebaseFirestore.DocumentSnapshot = readsBeforeWrites ?? await tx.get(ref);

    if (!snap.exists) return;
    const data = snap.data() as any;
    const current = Number(data?.reservedCount ?? 0);
    if (current <= delta) {
        tx.delete(ref);
    } else {
        tx.update(ref, {
            reservedCount: admin.firestore.FieldValue.increment(-delta),
            lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
}

/** 예약 취소/삭제 시: reservedCount -1 (0이면 문서 삭제). readsBeforeWrites 있으면 get 생략 */
export async function decrementReservedCount(
    tx: Tx,
    db: FirebaseFirestore.Firestore,
    params: {
        sessionId: string;
        reservedDateString: string;
    },
    readsBeforeWrites?: FirebaseFirestore.DocumentSnapshot,
): Promise<void> {
    const { sessionId, reservedDateString } = params;
    const ref = db.collection(COLLECTION).doc(docId(sessionId, reservedDateString));
    const snap: FirebaseFirestore.DocumentSnapshot = readsBeforeWrites ?? await tx.get(ref);

    if (!snap.exists) {
        // 이미 없으면 무시 (데이터 정합성 방어)
        return;
    }
    const data = snap.data() as any;
    const current = Number(data?.reservedCount ?? 0);
    if (current <= 1) {
        tx.delete(ref);
    } else {
        tx.update(ref, {
            reservedCount: admin.firestore.FieldValue.increment(-1),
            lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
}

/** 코스 삭제 시: 해당 courseId의 reservationSummary 문서 일괄 삭제 */
export async function deleteSummariesForCourse(
    db: FirebaseFirestore.Firestore,
    placeId: string,
    courseId: string,
    batchSize = 400,
): Promise<number> {
    const q = db.collection(COLLECTION).where('placeId', '==', placeId).where('courseId', '==', courseId);
    return deleteByQuery(db, q, batchSize);
}

async function deleteByQuery(
    db: FirebaseFirestore.Firestore,
    query: FirebaseFirestore.Query,
    batchSize: number,
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
