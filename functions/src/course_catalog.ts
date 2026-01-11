import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';

export async function getPlaceOrThrow(placeId: string) {
    const db = admin.firestore();
    const placeDoc = await db.collection('places').doc(placeId).get();
    if (!placeDoc.exists) {
        throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
    }
    return placeDoc.data();
}

export function findCourse(place: any, courseId: string): any | null {
    const courses = (place?.courses as any[]) || [];
    return courses.find((c: any) => c?.id === courseId) ?? null;
}

export function getCourseName(place: any, courseId: string): string {
    const course = findCourse(place, courseId);
    const name = (course?.name as string | undefined) ?? '';
    const trimmed = name.trim();
    return trimmed.length > 0 ? trimmed : courseId;
}


