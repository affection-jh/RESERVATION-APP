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

/**
 * 해당 플레이스·코스에 대해 알림을 받을 관리자 uid 목록 (매니저 전원 + 해당 코스를 관리하는 부매니저)
 * 비정기 일정 변경 등 코스 단위 알림 전송 시 사용.
 */
export async function getManagerUidsForPlaceAndCourse(placeId: string, courseId: string): Promise<string[]> {
    const snap = await admin
        .firestore()
        .collection('places')
        .doc(placeId)
        .collection('members')
        .get();
    const uids: string[] = [];
    for (const d of snap.docs) {
        const data = d.data();
        const role = String(data?.role ?? '').toLowerCase();
        if (role === 'manager') {
            uids.push(d.id);
        } else if (role === 'submanager') {
            const manageableCourseIds: string[] = Array.isArray(data?.manageableCourseIds)
                ? (data.manageableCourseIds as string[]).map((id: string) => String(id)).filter(Boolean)
                : [];
            if (manageableCourseIds.includes(courseId)) {
                uids.push(d.id);
            }
        }
    }
    return uids;
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

/**
 * uid가 "전체 매니저"이거나 플레이스 소유자(adminId)인 플레이스 ID 목록.
 * 회원탈퇴 시 이 목록이 비어있지 않으면 "먼저 플레이스 삭제" 요구.
 * 코스매니저(부매니저)만인 경우는 제외 → 그냥 탈퇴 가능(member에서 제거되면 됨).
 */
export async function getPlaceIdsWhereUserMustDeletePlaceFirst(uid: string): Promise<string[]> {
    const db = admin.firestore();
    const placeIds = new Set<string>();

    // 1) 매니저(role === 'manager')인 플레이스만 (부매니저 제외)
    const memberSnap = await db.collectionGroup('members')
        .where('userId', '==', uid)
        .limit(100)
        .get();
    for (const d of memberSnap.docs) {
        const role = String((d.data().role ?? '')).toLowerCase();
        if (role === 'manager') {
            const path = d.ref.path;
            const parts = path.split('/');
            const placeId = parts[1] ?? '';
            if (placeId) placeIds.add(placeId);
        }
    }

    // 2) 플레이스 소유자(adminId === uid)인 플레이스
    const placesSnap = await db.collection('places').where('adminId', '==', uid).limit(100).get();
    placesSnap.docs.forEach((d) => placeIds.add(d.id));

    return Array.from(placeIds);
}

/**
 * 부매니저가 관리 코스 0개일 때 일반 멤버로 강등 (점검 시 자동 강등용).
 * - Callable에서 "관리할 코스가 없습니다" throw 전에 호출하면, 다음 로드부터 member로 반영됨.
 */
export async function demoteSubManagerToMemberIfNoCoursesInternal(
    db: FirebaseFirestore.Firestore,
    placeId: string,
    uid: string,
): Promise<boolean> {
    const memberRef = db.collection('places').doc(placeId).collection('members').doc(uid);
    const snap = await memberRef.get();
    if (!snap.exists) return false;
    const d = snap.data() as any;
    const role = String(d?.role ?? '').toLowerCase();
    if (role !== 'submanager') return false;
    const manageableCourseIds = Array.isArray(d?.manageableCourseIds) ? (d.manageableCourseIds as string[]) : [];
    if (manageableCourseIds.length > 0) return false;

    await memberRef.update({
        role: 'member',
        manageableCourseIds: [],
        updatedAt: admin.firestore.Timestamp.now(),
    });
    return true;
}
