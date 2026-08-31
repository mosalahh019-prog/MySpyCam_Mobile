import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class ResumableChunkUploader {
  final String serverUrl;
  static const int chunkSize = 2 * 1024 * 1024;

  ResumableChunkUploader({required this.serverUrl});

  Future<void> uploadFileWithRetry(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) throw Exception('الملف غير موجود');

    final fileId = file.uri.pathSegments.last;
    final totalBytes = await file.length();
    final totalChunks = totalBytes == 0 ? 1 : (totalBytes / chunkSize).ceil();

    while (true) {
      try {
        final uploaded = await _getUploadedChunks(fileId);
        final raf = await file.open(mode: FileMode.read);
        try {
          for (var i = 0; i < totalChunks; i++) {
            if (uploaded.contains(i)) continue;
            final start = i * chunkSize;
            final end = (start + chunkSize > totalBytes) ? totalBytes : start + chunkSize;
            final length = end - start;
            await raf.setPosition(start);
            final bytes = length > 0 ? await raf.read(length) : <int>[];
            final ok = await _uploadSingleChunk(fileId, i, totalChunks, bytes);
            if (!ok) throw Exception('فشل رفع الجزء $i');
          }
        } finally {
          await raf.close();
        }

        final complete = await http.post(
          Uri.parse('$serverUrl/upload/complete'),
          headers: {'X-Upload-Id': fileId, 'X-File-Name': fileId, 'X-Total-Chunks': '$totalChunks'},
        ).timeout(const Duration(seconds: 30));
        if (complete.statusCode != 200) throw Exception('فشل تجميع الملف: ${complete.body}');
        return;
      } catch (e) {
        await Future.delayed(const Duration(seconds: 3));
      }
    }
  }

  Future<List<int>> _getUploadedChunks(String fileId) async {
    try {
      final response = await http.get(Uri.parse('$serverUrl/upload/status/$fileId')).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return (data['uploaded_chunks'] as List<dynamic>? ?? []).map((e) => e as int).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<bool> _uploadSingleChunk(String fileId, int index, int totalChunks, List<int> bytes) async {
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/upload/chunk'),
        headers: {
          'X-Upload-Id': fileId,
          'X-Chunk-Index': '$index',
          'X-File-Name': fileId,
        },
        body: bytes,
      ).timeout(const Duration(seconds: 60));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
