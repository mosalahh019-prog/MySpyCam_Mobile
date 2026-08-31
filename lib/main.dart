import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'services/chunk_uploader.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: SpyCamClientApp(),
  ));
}

class SpyCamClientApp extends StatefulWidget {
  const SpyCamClientApp({Key? key}) : super(key: key);

  @override
  _SpyCamClientAppState createState() => _SpyCamClientAppState();
}

class _SpyCamClientAppState extends State<SpyCamClientApp> {
  static const platform = MethodChannel('com.example.myspycam/camera');
  
  final TextEditingController _ipController = TextEditingController(text: "192.168.1.5");
  IOWebSocketChannel? _controlChannel;
  
  bool _isConnected = false;
  String _status = "غير متصل بالسيرفر";
  List<String> _logs = [];

  void _addLog(String log) {
    setState(() {
      _logs.insert(0, "[${DateTime.now().toString().split('.').first}] $log");
    });
  }

  void _connectToPC() {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;

    final wsUrl = "ws://$ip:8000/ws/control";
    _addLog("جاري الاتصال بـ $wsUrl...");

    try {
      _controlChannel = IOWebSocketChannel.connect(wsUrl);
      
      _controlChannel!.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message);
            _handleServerCommand(data, ip);
          } catch (e) {
            _addLog("خطأ في قراءة الرسالة: $e");
          }
        },
        onDone: () {
          setState(() {
            _isConnected = false;
            _status = "انقطع الاتصال، جاري إعادة المحاولة...";
          });
          _addLog("انقطع الاتصال بالسيرفر.");
          Future.delayed(const Duration(seconds: 4), _connectToPC);
        },
        onError: (error) {
          setState(() {
            _isConnected = false;
            _status = "خطأ في الاتصال";
          });
          _addLog("خطأ شبكة: $error");
        },
      );

      setState(() {
        _isConnected = true;
        _status = "متصل بنجاح باللابتوب";
      });
      _addLog("تم الاتصال بالسيرفر بنجاح.");
    } catch (e) {
      setState(() {
        _status = "فشل الاتصال";
      });
      _addLog("فشل الاتصال: $e");
    }
  }

  Future<void> _handleServerCommand(Map<String, dynamic> data, String pcIp) async {
    String action = data['action'] ?? '';
    _addLog("أمر مستلم من البي سي: $action");

    if (action == "START_RECORDING") {
      try {
        await platform.invokeMethod('startService');
        _addLog("تم تشغيل خدمة الكاميرا في الخلفية.");
        _sendACK("RECORDING_STARTED");
      } catch (e) {
        _addLog("فشل تشغيل الكاميرا: $e");
      }
    } 
    else if (action == "STOP_RECORDING") {
      try {
        String? recordedPath = await platform.invokeMethod('stopService');
        _addLog("تم إيقاف التصوير. المسار: $recordedPath");
        _sendACK("RECORDING_STOPPED");

        if (recordedPath != null && recordedPath.isNotEmpty) {
          _addLog("جاري إرسال الفيديو مقطعاً إلى اللابتوب...");
          ResumableChunkUploader uploader = ResumableChunkUploader(serverUrl: "http://$pcIp:8000");
          uploader.uploadFileWithRetry(recordedPath).then((_) {
            _addLog("اكتمل الرفع وتم تنظيف ذاكرة الهاتف.");
          });
        }
      } catch (e) {
        _addLog("خطأ أثناء إيقاف التسجيل: $e");
      }
    } 
    else if (action == "DELETE_MOBILE_FILE") {
      String fileName = data['filename'] ?? '';
      _addLog("طلب حذف الملف: $fileName");

      try {
        final directory = await getExternalStorageDirectory();
        if (directory != null) {
          final file = File("${directory.path}/$fileName");
          if (await file.exists()) {
            await file.delete();
            _addLog("تم حذف الملف $fileName لتوفير المساحة.");
            _sendACK("FILE_DELETED_SUCCESS", {"filename": fileName});
          } else {
            _addLog("الملف غير موجود في هذا المسار.");
            _sendACK("FILE_NOT_FOUND", {"filename": fileName});
          }
        }
      } catch (e) {
        _addLog("فشل حذف الملف: $e");
      }
    }
  }

  void _sendACK(String action, [Map<String, dynamic>? extra]) {
    if (_controlChannel != null && _isConnected) {
      Map<String, dynamic> msg = {"action": action};
      if (extra != null) msg.addAll(extra);
      _controlChannel?.sink.add(jsonEncode(msg));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("MySpyCam - الموبايل"),
        backgroundColor: const Color(0xFF1F1F1F),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  children: [
                    TextField(
                      controller: _ipController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: "IP اللابتوب (الشبكة المحلية)",
                        labelStyle: TextStyle(color: Colors.grey),
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.teal)),
                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.tealAccent)),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _connectToPC,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: Text(_isConnected ? "إعادة الاتصال" : "ربط بالسيرفر"),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _isConnected ? Colors.teal.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _isConnected ? Colors.teal : Colors.red),
              ),
              child: Text(
                "الحالة: $_status",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _isConnected ? Colors.tealAccent : Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              "سجل العمليات والربط (System Logs):",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white10),
                ),
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Text(
                        _logs[index],
                        style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}