import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';

/** places/{placeId}/members 기반 관리자 권한 검증 */

function canManagePlace(data: FirebaseFirestore.DocumentData | undefined): boolean {
    if (!data) return false;
    const role = String(data.role ?? '').toLowerCase();
    return role === 'manager' || role === 'submanager';
}

/** uid가 어느 플레이스에서든 매니저/부매니저인지 확인 */
export async function assertAdminUid(uid: string): Promise<void> {
    const snap = await admin
        .firestore()
        .collectionGroup('members')
        .where('userId', '==', uid)
        .limit(10)
        .get();
    const hasManagerRole = snap.docs.some((d) => canManagePlace(d.data()));
    if (!hasManagerRole) {
        throw new functions.https.HttpsError(
            'permission-denied',
            '관리자 권한이 필요합니다.',
        );
    }
}

/** uid가 해당 placeId 플레이스의 매니저/부매니저인지 확인 */
export async function isAdminForPlaceUid(
    uid: string,
    placeId: string,
): Promise<boolean> {
    const doc = await admin
        .firestore()
        .collection('places')
        .doc(placeId)
        .collection('members')
        .doc(uid)
        .get();
    return doc.exists && canManagePlace(doc.data());
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

/** 해당 플레이스의 매니저/부매니저 uid 목록 (알림 전송용) */
export async function getManagerUidsForPlace(placeId: string): Promise<string[]> {
    const snap = await admin
        .firestore()
        .collection('places')
        .doc(placeId)
        .collection('members')
        .get();
    return snap.docs
        .filter((d) => canManagePlace(d.data()))
        .map((d) => d.id);
}

/** uid가 매니저/부매니저인 플레이스 ID 목록 */
export async function getManagedPlaceIdsForUid(uid: string): Promise<string[]> {
    const snap = await admin
        .firestore()
        .collectionGroup('members')
        .where('userId', '==', uid)
        .limit(100)
        .get();
    return snap.docs
        .filter((d) => canManagePlace(d.data()))
        .map((d) => {
            const path = d.ref.path;
            const parts = path.split('/');
            return parts[1] ?? ''; // places/{placeId}/members/{uid}
        })
        .filter((id) => id.length > 0);
}
