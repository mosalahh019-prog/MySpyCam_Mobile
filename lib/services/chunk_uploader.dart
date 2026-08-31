import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:convert';

class ResumableChunkUploader {
  final String serverUrl; //"http://192.168.1.3:8000"
  static const int chunkSize = 2 * 1024 * 1024; // 2 MegaByte لكل جزء

  ResumableChunkUploader({required this.serverUrl});

  Future<void> uploadFileWithRetry(String filePath) async {
    File file = File(filePath);
    if (!await file.exists()) return;

    String fileId = file.path.split('/').last;
    int totalBytes = await file.length();
    int totalChunks = (totalBytes / chunkSize).ceil();

    while (true) {
      try {
        // 1. الاستعلام عن القطع المرفوعة مسبقاً من السيرفر
        List<int> uploadedChunks = await _getUploadedChunks(fileId);

        if (uploadedChunks.length == totalChunks) {
          print("تم رفع وتجميع الملف بنجاح على اللابتوب!");
          // تأكيد الحذف من الموبايل بعد الاستلام الكامل
          await file.delete();
          break;
        }

        // 2. رفع القطع المتبقية فقط
        RandomAccessFile randomAccessFile = await file.open(mode: FileMode.read);
        for (int i = 0; i < totalChunks; i++) {
          if (uploadedChunks.contains(i)) continue; // تخطي ما تم رفعه

          int start = i * chunkSize;
          int end = (start + chunkSize > totalBytes) ? totalBytes : start + chunkSize;
          int length = end - start;

          await randomAccessFile.setPosition(start);
          List<int> chunkBytes = await randomAccessFile.read(length);

          bool success = await _uploadSingleChunk(fileId, i, totalChunks, chunkBytes);
          if (!success) {
            throw Exception("فشل رفع الجزء $i - سيتم إعادة المحاولة...");
          }
        }
        await randomAccessFile.close();
      } catch (e) {
        print("انقطع الاتصال: $e. إعادة المحاولة بعد 5 ثوانٍ...");
        await Future.delayed(Duration(seconds: 5)); // الانتظار لعودة الواي فاي
      }
    }
  }

  Future<List<int>> _getUploadedChunks(String fileId) async {
    try {
      final res = await http.get(Uri.parse('$serverUrl/upload/status/$fileId'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        List<dynamic> list = data['uploaded_chunks'] ?? [];
        return list.map((e) => e as int).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<bool> _uploadSingleChunk(String fileId, int chunkIdx, int totalChunks, List<int> bytes) async {
    var request = http.MultipartRequest('POST', Uri.parse('$serverUrl/upload/chunk'));
    request.fields['file_id'] = fileId;
    request.fields['chunk_index'] = chunkIdx.toString();
    request.fields['total_chunks'] = totalChunks.toString();

    request.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: 'chunk_$chunkIdx',
    ));

    try {
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}