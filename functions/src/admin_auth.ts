import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';

export async function assertAdminUid(uid: string): Promise<void> {
    const snap = await admin
        .firestore()
        .collection('adminUsers')
        .where('userId', '==', uid)
        .limit(1)
        .get();
    if (snap.empty) {
        throw new functions.https.HttpsError(
            'permission-denied',
            '관리자 권한이 필요합니다.',
        );
    }
}

export async function isAdminForPlaceUid(
    uid: string,
    placeId: string,
): Promise<boolean> {
    const snap = await admin
        .firestore()
        .collection('adminUsers')
        .where('userId', '==', uid)
        .where('placeIds', 'array-contains', placeId)
        .limit(1)
        .get();
    return !snap.empty;
}

export async function assertAdminForPlaceUid(
    uid: string,
    placeId: string,
): Promise<void> {
    const ok = await isAdminForPlaceUid(uid, placeId);
    if (!ok) {
        throw new functions.https.HttpsError(
            'permission-denied',
            '해당 플레이스에 대한 관리자 권한이 필요합니다.',
        );
    }
}


