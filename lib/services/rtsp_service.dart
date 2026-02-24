import 'package:flutter/services.dart';

class RtspService {
  static const _channel = MethodChannel('com.rtspstreamer/rtsp');

  static Future<bool> startServer({
    required String mediamtxIp,
    required String streamId,
    int port = 8554,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('startServer', {
        'mediamtxIp': mediamtxIp,
        'streamId': streamId,
        'port': port,
      });
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> stopServer() async {
    try {
      final result = await _channel.invokeMethod<bool>('stopServer');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> isStreaming() async {
    try {
      return await _channel.invokeMethod<bool>('isStreaming') ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<String?> getDeviceIp() async {
    try {
      return await _channel.invokeMethod<String>('getDeviceIp');
    } catch (e) {
      return null;
    }
  }

  static Future<bool> checkPermissions() async {
    try {
      return await _channel.invokeMethod<bool>('checkPermissions') ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> requestPermissions() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermissions') ?? false;
    } catch (e) {
      return false;
    }
  }
}