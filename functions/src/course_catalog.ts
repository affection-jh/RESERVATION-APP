import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';

const db = () => admin.firestore();

export async function getPlaceOrThrow(placeId: string) {
    const placeDoc = await db().collection('places').doc(placeId).get();
    if (!placeDoc.exists) {
        throw new functions.https.HttpsError('not-found', '플레이스를 찾을 수 없습니다.');
    }
    return placeDoc.data();
}

/** 코스 단일 문서 조회 (서브컬렉션: places/{placeId}/courses/{courseId}) */
export async function getCourseOrThrow(placeId: string, courseId: string): Promise<any> {
    const courseRef = db().collection('places').doc(placeId).collection('courses').doc(courseId);
    const courseDoc = await courseRef.get();
    if (!courseDoc.exists) {
        throw new functions.https.HttpsError('not-found', '코스를 찾을 수 없습니다.');
    }
    return courseDoc.data();
}

/** 레거시: place 객체 내 courses 배열에서 코스 찾기 (마이그레이션 후 사용 안 함) */
export function findCourse(place: any, courseId: string): any | null {
    const courses = (place?.courses as any[]) || [];
    return courses.find((c: any) => c?.id === courseId) ?? null;
}

export function getCourseNameFromCourse(course: any): string {
    const name = (course?.name as string | undefined) ?? '';
    const trimmed = name.trim();
    return trimmed.length > 0 ? trimmed : (course?.id ?? '');
}

/** placeId + courseId로 코스 이름 조회 (서브컬렉션에서 조회) */
export async function getCourseName(placeId: string, courseId: string): Promise<string> {
    const course = await getCourseOrThrow(placeId, courseId);
    return getCourseNameFromCourse(course);
}


