import 'package:flutter/services.dart';

class RtspService {
  static const MethodChannel _channel = MethodChannel('com.rtspstreamer/rtsp');

  /// Start the RTSP server on the given port
  static Future<bool> startServer({int port = 8554}) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'startServer',
        {'port': port},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      throw Exception('Failed to start server: ${e.message}');
    }
  }

  /// Stop the RTSP server
  static Future<bool> stopServer() async {
    try {
      final result = await _channel.invokeMethod<bool>('stopServer');
      return result ?? false;
    } on PlatformException catch (e) {
      throw Exception('Failed to stop server: ${e.message}');
    }
  }

  /// Get local device IP address (WiFi)
  static Future<String?> getDeviceIp() async {
    try {
      final result = await _channel.invokeMethod<String>('getDeviceIp');
      return result;
    } on PlatformException catch (e) {
      throw Exception('Failed to get IP: ${e.message}');
    }
  }

  /// Check if streaming is active
  static Future<bool> isStreaming() async {
    try {
      final result = await _channel.invokeMethod<bool>('isStreaming');
      return result ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Check camera permissions
  static Future<bool> checkPermissions() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkPermissions');
      return result ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Request camera + microphone permissions
  static Future<bool> requestPermissions() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermissions');
      return result ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Switch between front / back camera
  static Future<void> switchCamera() async {
    try {
      await _channel.invokeMethod('switchCamera');
    } on PlatformException catch (e) {
      throw Exception('Failed to switch camera: ${e.message}');
    }
  }

  /// Toggle torch/flashlight
  static Future<void> toggleTorch() async {
    try {
      await _channel.invokeMethod('toggleTorch');
    } on PlatformException catch (_) {}
  }
}