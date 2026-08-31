import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';

import 'services/chunk_uploader.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MySpyCamApp());
}

class MySpyCamApp extends StatelessWidget {
  const MySpyCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MySpyCam',
      theme: ThemeData.dark(useMaterial3: true),
      home: const CameraHomePage(),
    );
  }
}

class CameraHomePage extends StatefulWidget {
  const CameraHomePage({super.key});

  @override
  State<CameraHomePage> createState() => _CameraHomePageState();
}

class _CameraHomePageState extends State<CameraHomePage> {
  CameraController? _camera;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  ResolutionPreset _resolution = ResolutionPreset.medium;

  IOWebSocketChannel? _controlChannel;
  StreamSubscription? _controlSubscription;
  String _serverIp = '';
  bool _connected = false;
  bool _recording = false;
  bool _initializingCamera = false;
  String _status = 'الكاميرا غير مهيأة';
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<bool> _requestCameraPermissions() async {
    final camera = await Permission.camera.request();
    final microphone = await Permission.microphone.request();
    return camera.isGranted && microphone.isGranted;
  }

  Future<void> _initializeCamera({int? index}) async {
    if (_initializingCamera) return;
    _initializingCamera = true;
    try {
      final granted = await _requestCameraPermissions();
      if (!granted) {
        _setStatus('يجب السماح بالكاميرا والميكروفون للتسجيل.');
        _addLog('تم رفض إذن الكاميرا أو الميكروفون.');
        return;
      }

      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        _setStatus('لم يتم العثور على كاميرا.');
        return;
      }

      _cameraIndex = index ?? (_cameraIndex < _cameras.length ? _cameraIndex : 0);
      final old = _camera;
      _camera = null;
      await old?.dispose();

      final controller = CameraController(
        _cameras[_cameraIndex],
        _resolution,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();

      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _status = 'الكاميرا جاهزة';
      });
      _addLog('تم تشغيل الكاميرا الحقيقية: ${_cameraName()}');
    } on CameraException catch (e) {
      _setStatus('خطأ بالكاميرا: ${e.description ?? e.code}');
      _addLog('CameraException: ${e.code} ${e.description}');
    } catch (e) {
      _setStatus('تعذر تهيئة الكاميرا.');
      _addLog('خطأ تهيئة الكاميرا: $e');
    } finally {
      _initializingCamera = false;
    }
  }

  String _cameraName() {
    if (_cameras.isEmpty) return 'غير معروف';
    return _cameras[_cameraIndex].lensDirection == CameraLensDirection.front
        ? 'أمامية'
        : 'خلفية';
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '[${DateTime.now().toLocal().toString().split('.').first}] $message');
      if (_logs.length > 200) _logs.removeLast();
    });
  }

  void _setStatus(String value) {
    if (mounted) setState(() => _status = value);
  }

  Future<void> _connectDialog() async {
    final controller = TextEditingController(text: _serverIp);
    final ip = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('اتصال بالشبكة'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'IP الكمبيوتر',
            hintText: 'مثال: 192.168.1.3',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('اتصال')),
        ],
      ),
    );
    controller.dispose();
    if (ip == null || ip.isEmpty) return;
    await _connectToServer(ip);
  }

  Future<void> _connectToServer(String ip) async {
    await _controlSubscription?.cancel();
    await _controlChannel?.sink.close();
    _serverIp = ip;
    _setStatus('جاري الاتصال...');
    _addLog('الاتصال بـ $ip:8000');

    try {
      final channel = IOWebSocketChannel.connect(
        Uri.parse('ws://$ip:8000/ws/control'),
        connectTimeout: const Duration(seconds: 5),
      );
      _controlChannel = channel;
      _controlSubscription = channel.stream.listen(
        (message) => _handleServerMessage(message),
        onDone: () {
          if (!mounted) return;
          setState(() {
            _connected = false;
            _status = 'انقطع اتصال الكمبيوتر';
          });
          _addLog('تم قطع قناة التحكم.');
        },
        onError: (error) {
          if (!mounted) return;
          setState(() {
            _connected = false;
            _status = 'خطأ في الاتصال';
          });
          _addLog('خطأ شبكة: $error');
        },
      );

      setState(() {
        _connected = true;
        _status = 'متصل بالكمبيوتر';
      });
      _sendControl({'action': 'DEVICE_STATUS', 'camera': _cameraName(), 'recording': _recording});
      _addLog('تم الاتصال بنجاح.');
    } catch (e) {
      _connected = false;
      _setStatus('فشل الاتصال');
      _addLog('فشل الاتصال: $e');
    }
  }

  void _sendControl(Map<String, dynamic> message) {
    if (_controlChannel == null || !_connected) return;
    try {
      _controlChannel!.sink.add(jsonEncode(message));
    } catch (e) {
      _addLog('فشل إرسال الأمر: $e');
    }
  }

  Future<void> _handleServerMessage(dynamic raw) async {
    try {
      final data = jsonDecode(raw.toString()) as Map<String, dynamic>;
      final action = data['action']?.toString() ?? '';
      _addLog('أمر من الكمبيوتر: $action');

      switch (action) {
        case 'START_RECORDING':
          await _confirmRemoteAction(
            title: 'طلب بدء التسجيل',
            message: 'برنامج الكمبيوتر يطلب بدء التسجيل بالكاميرا والميكروفون. هل توافق؟',
            onAccept: _startRecording,
          );
          break;
        case 'STOP_RECORDING':
          await _confirmRemoteAction(
            title: 'طلب إيقاف التسجيل',
            message: 'برنامج الكمبيوتر يطلب إيقاف التسجيل وحفظ الفيديو. هل توافق؟',
            onAccept: _stopRecordingAndUpload,
          );
          break;
        case 'SWITCH_CAMERA':
          await _confirmRemoteAction(
            title: 'طلب تغيير الكاميرا',
            message: 'برنامج الكمبيوتر يطلب التبديل إلى الكاميرا ${data['target'] ?? ''}. هل توافق؟',
            onAccept: () => _switchCameraByTarget(data['target']?.toString()),
          );
          break;
        case 'DELETE_MOBILE_FILE':
          await _confirmRemoteAction(
            title: 'طلب حذف ملف',
            message: 'سيتم حذف النسخة المحلية من الهاتف: ${data['filename'] ?? ''}. هل توافق؟',
            onAccept: () => _deleteMobileFile(data['filename']?.toString() ?? ''),
          );
          break;
      }
    } catch (e) {
      _addLog('رسالة غير صالحة: $e');
    }
  }

  Future<void> _confirmRemoteAction({
    required String title,
    required String message,
    required Future<void> Function() onAccept,
  }) async {
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('رفض')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('موافقة')),
        ],
      ),
    );
    if (accepted == true) {
      await onAccept();
    } else {
      _sendControl({'action': 'ACTION_DENIED', 'requested': title});
      _addLog('تم رفض طلب التحكم عن بُعد.');
    }
  }

  Future<void> _startRecording() async {
    final controller = _camera;
    if (controller == null || !controller.value.isInitialized) {
      _setStatus('الكاميرا غير جاهزة.');
      return;
    }
    if (controller.value.isRecordingVideo) return;

    try {
      await controller.startVideoRecording();
      setState(() {
        _recording = true;
        _status = '🔴 التسجيل جارٍ';
      });
      _sendControl({'action': 'RECORDING_STARTED', 'camera': _cameraName()});
      _addLog('بدأ التسجيل الحقيقي.');
    } catch (e) {
      _addLog('فشل بدء التسجيل: $e');
      _setStatus('تعذر بدء التسجيل.');
    }
  }

  Future<void> _stopRecordingAndUpload() async {
    final controller = _camera;
    if (controller == null || !controller.value.isRecordingVideo) return;

    try {
      final xFile = await controller.stopVideoRecording();
      setState(() {
        _recording = false;
        _status = 'جاري حفظ الفيديو...';
      });

      final appDir = await getApplicationDocumentsDirectory();
      final recordings = Directory('${appDir.path}/recordings');
      await recordings.create(recursive: true);
      final name = 'recording_${DateTime.now().toIso8601String().replaceAll(':', '-')}.mp4';
      final localFile = File('${recordings.path}/$name');
      await File(xFile.path).copy(localFile.path);
      try {
        await File(xFile.path).delete();
      } catch (_) {}

      _addLog('تم حفظ نسخة الهاتف: ${localFile.path}');
      _sendControl({'action': 'RECORDING_STOPPED', 'filename': name});

      if (_serverIp.isNotEmpty && _connected) {
        _setStatus('جاري إرسال نسخة للكمبيوتر...');
        final uploader = ResumableChunkUploader(serverUrl: 'http://$_serverIp:8000');
        await uploader.uploadFileWithRetry(localFile.path);
        _setStatus('تم حفظ النسختين بنجاح');
        _sendControl({'action': 'FILE_UPLOADED', 'filename': name});
        _addLog('تم رفع نسخة الكمبيوتر مع إبقاء نسخة الهاتف.');
      } else {
        _setStatus('تم الحفظ على الهاتف — الكمبيوتر غير متصل');
      }
    } catch (e) {
      setState(() => _recording = false);
      _setStatus('خطأ أثناء حفظ الفيديو.');
      _addLog('فشل إيقاف/حفظ التسجيل: $e');
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) {
      _addLog('الجهاز لا يحتوي على كاميرتين متاحتين.');
      return;
    }
    if (_recording) {
      _addLog('لا يمكن تبديل الكاميرا أثناء التسجيل.');
      return;
    }
    final next = (_cameraIndex + 1) % _cameras.length;
    await _initializeCamera(index: next);
    _sendControl({'action': 'CAMERA_CHANGED', 'camera': _cameraName()});
  }

  Future<void> _switchCameraByTarget(String? target) async {
    if (_recording) {
      _addLog('لا يمكن تبديل الكاميرا أثناء التسجيل.');
      return;
    }
    final desired = target == 'front' || target == 'أمامية'
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    final idx = _cameras.indexWhere((c) => c.lensDirection == desired);
    if (idx < 0) {
      _addLog('الكاميرا المطلوبة غير متاحة.');
      return;
    }
    await _initializeCamera(index: idx);
    _sendControl({'action': 'CAMERA_CHANGED', 'camera': _cameraName()});
  }

  Future<void> _deleteMobileFile(String filename) async {
    if (filename.isEmpty) return;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/recordings/$filename');
      if (await file.exists()) {
        await file.delete();
        _sendControl({'action': 'FILE_DELETED_SUCCESS', 'filename': filename});
        _addLog('تم حذف $filename بعد موافقة المستخدم.');
      } else {
        _sendControl({'action': 'FILE_NOT_FOUND', 'filename': filename});
      }
    } catch (e) {
      _addLog('فشل حذف الملف: $e');
      _sendControl({'action': 'FILE_DELETE_ERROR', 'filename': filename, 'error': '$e'});
    }
  }

  Future<void> _openSettings() async {
    final selected = await showDialog<ResolutionPreset>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إعدادات الكاميرا'),
        content: DropdownButtonFormField<ResolutionPreset>(
          value: _resolution,
          decoration: const InputDecoration(labelText: 'دقة التسجيل'),
          items: const [
            DropdownMenuItem(value: ResolutionPreset.low, child: Text('منخفضة')),
            DropdownMenuItem(value: ResolutionPreset.medium, child: Text('متوسطة')),
            DropdownMenuItem(value: ResolutionPreset.high, child: Text('عالية')),
            DropdownMenuItem(value: ResolutionPreset.veryHigh, child: Text('عالية جدًا')),
            DropdownMenuItem(value: ResolutionPreset.ultraHigh, child: Text('قصوى')),
          ],
          onChanged: (v) => Navigator.pop(context, v),
        ),
      ),
    );
    if (selected == null || selected == _resolution || _recording) return;
    _resolution = selected;
    await _initializeCamera(index: _cameraIndex);
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MySpyCam Mobile'),
        actions: [
          IconButton(onPressed: _openSettings, tooltip: 'الإعدادات', icon: const Icon(Icons.settings)),
          IconButton(onPressed: _connectDialog, tooltip: 'الشبكة', icon: const Icon(Icons.wifi)),
          IconButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Terminal / Logs'),
                content: SizedBox(
                  width: double.maxFinite,
                  height: 420,
                  child: ListView(children: _logs.map((e) => Text(e, style: const TextStyle(fontSize: 11, color: Colors.greenAccent))).toList()),
                ),
              ),
            ),
            tooltip: 'السجل',
            icon: const Icon(Icons.terminal),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(16)),
              clipBehavior: Clip.antiAlias,
              child: camera != null && camera.value.isInitialized
                  ? CameraPreview(camera)
                  : Center(child: Text(_status, textAlign: TextAlign.center)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: _statusCard(Icons.circle, _recording ? 'تسجيل حقيقي' : _status)),
                    const SizedBox(width: 8),
                    Expanded(child: _statusCard(Icons.camera_alt, _cameraName())),
                    const SizedBox(width: 8),
                    Expanded(child: _statusCard(Icons.wifi, _connected ? 'متصل' : 'غير متصل')),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _recording ? _stopRecordingAndUpload : _startRecording,
                        style: FilledButton.styleFrom(backgroundColor: _recording ? Colors.red : Colors.teal, minimumSize: const Size.fromHeight(52)),
                        icon: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
                        label: Text(_recording ? 'إيقاف وحفظ وإرسال' : 'بدء التسجيل'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(onPressed: _recording ? null : _switchCamera, icon: const Icon(Icons.flip_camera_android), tooltip: 'تبديل الكاميرا'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [Icon(icon, size: 14), const SizedBox(width: 5), Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)))]),
    );
  }

  @override
  void dispose() {
    _controlSubscription?.cancel();
    _controlChannel?.sink.close();
    _camera?.dispose();
    super.dispose();
  }
}
