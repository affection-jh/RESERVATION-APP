import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';

/// Firebase Storage 이미지 업로드 서비스
class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// 이미지를 Firebase Storage에 업로드
  ///
  /// [imageFile] 업로드할 이미지 파일
  /// [folder] 저장할 폴더 경로 (예: 'places', 'promotions')
  /// [fileName] 파일명 (없으면 자동 생성)
  ///
  /// Returns: 업로드된 이미지의 다운로드 URL
  Future<String> uploadImage({
    required File imageFile,
    required String folder,
    String? fileName,
  }) async {
    try {
      // 파일명 생성 (없으면 타임스탬프 기반)
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = imageFile.path;
      final extension = filePath.contains('.')
          ? filePath.substring(filePath.lastIndexOf('.'))
          : '.jpg';
      final finalFileName = fileName ?? 'image_$timestamp$extension';

      // Storage 경로 생성: folder/filename
      final storagePath = '$folder/$finalFileName';

      // Reference 생성
      final ref = _storage.ref().child(storagePath);

      // 업로드
      final uploadTask = ref.putFile(
        imageFile,
        SettableMetadata(
          contentType: _getContentType(extension),
          cacheControl: 'public, max-age=31536000', // 1년 캐시
        ),
      );

      // 업로드 진행률 모니터링 (선택사항)
      // uploadTask.snapshotEvents.listen((TaskSnapshot snapshot) {
      //   final progress = snapshot.bytesTransferred / snapshot.totalBytes;
      //   print('Upload progress: ${(progress * 100).toStringAsFixed(2)}%');
      // });

      // 업로드 완료 대기
      final snapshot = await uploadTask;

      // 다운로드 URL 가져오기
      final downloadUrl = await snapshot.ref.getDownloadURL();

      return downloadUrl;
    } on FirebaseException catch (e) {
      throw Exception('이미지 업로드 중 오류가 발생했습니다: ${e.message}');
    } catch (e) {
      throw Exception('이미지 업로드 중 오류가 발생했습니다: ${e.toString()}');
    }
  }

  /// 이미지 삭제
  ///
  /// [imageUrl] 삭제할 이미지의 다운로드 URL
  Future<void> deleteImage(String imageUrl) async {
    try {
      // URL에서 파일 경로 추출
      final ref = _storage.refFromURL(imageUrl);
      await ref.delete();
    } on FirebaseException catch (e) {
      // 파일이 없어도 에러로 처리하지 않음
      if (e.code != 'object-not-found') {
        throw Exception('이미지 삭제 중 오류가 발생했습니다: ${e.message}');
      }
    } catch (e) {
      throw Exception('이미지 삭제 중 오류가 발생했습니다: ${e.toString()}');
    }
  }

  /// Content-Type 반환
  String _getContentType(String extension) {
    switch (extension.toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      default:
        return 'image/jpeg';
    }
  }
}
