import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';

class ImageDownloadService {
  final Dio _dio;

  ImageDownloadService({Dio? dio}) : _dio = dio ?? Dio();

  /// 네트워크 이미지 URL을 다운로드하여 갤러리에 저장합니다.
  ///
  /// Returns: 저장 성공 여부
  Future<bool> saveToGallery({
    required String imageUrl,
    String? fileName,
  }) async {
    final response = await _dio.get<List<int>>(
      imageUrl,
      options: Options(responseType: ResponseType.bytes, followRedirects: true),
    );

    final data = response.data;
    if (data == null || data.isEmpty) return false;

    final result = await ImageGallerySaver.saveImage(
      Uint8List.fromList(data),
      quality: 100,
      name: fileName,
    );

    // image_gallery_saver는 플랫폼별로 Map 형태로 반환합니다.
    final isSuccess =
        (result['isSuccess'] == true) ||
        (result['success'] == true) ||
        (result['filePath'] != null);
    return isSuccess;
  }
}
