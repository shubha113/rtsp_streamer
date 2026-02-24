import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../services/rtsp_service.dart';
import '../widgets/watch_url_card.dart';

class StreamScreen extends StatefulWidget {
  const StreamScreen({super.key});

  @override
  State<StreamScreen> createState() => _StreamScreenState();
}

class _StreamScreenState extends State<StreamScreen>
    with SingleTickerProviderStateMixin {
  bool _isStreaming = false;
  bool _isLoading = false;
  String? _deviceIp;
  String? _errorMessage;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Timer? _statusTimer;

  String? _watchUrl;
  String? _qrCodeBase64;
  String? _streamId;
  String? _deviceName;
  bool _isRegistering = false;
  int _viewerCount = 0;

  static const String _serverIp = '192.168.0.102';
  static const String _backendUrl = 'http://$_serverIp:3001';
  static const String _mediamtxIp = _serverIp;
  static const int _rtspPort = 8554;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _generateStreamIdentity();
    _init();
  }

  void _generateStreamIdentity() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    final suffix = List.generate(
      6,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
    _streamId = 'cam_$suffix';
    _deviceName = 'Camera ${suffix.substring(0, 4).toUpperCase()}';
  }

  Future<void> _init() async {
    try {
      final ip = await RtspService.getDeviceIp();
      if (mounted) setState(() => _deviceIp = ip);
    } catch (_) {}
    final streaming = await RtspService.isStreaming();
    if (mounted) setState(() => _isStreaming = streaming);
  }

  Future<void> _startStreaming() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (!await RtspService.checkPermissions()) {
        if (!await RtspService.requestPermissions()) {
          setState(() {
            _errorMessage =
                'Camera permission required.\nGo to Settings → App → Permissions.';
            _isLoading = false;
          });
          return;
        }
      }

      // 2. Refresh IP
      final ip = await RtspService.getDeviceIp();
      if (ip == null) {
        setState(() {
          _errorMessage = 'Could not detect device IP. Connect to WiFi first.';
          _isLoading = false;
        });
        return;
      }
      setState(() => _deviceIp = ip);

      final success = await RtspService.startServer(
        mediamtxIp: _mediamtxIp,
        streamId: _streamId!,
        port: _rtspPort,
      );

      if (!success) {
        setState(() {
          _errorMessage =
              'Failed to connect to MediaMTX.\n'
              'Make sure MediaMTX is running at $_mediamtxIp:$_rtspPort\n'
              'and your phone is on the same WiFi.';
          _isLoading = false;
        });
        return;
      }

      setState(() => _isStreaming = true);

      await _registerWithBackend();

      _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        final live = await RtspService.isStreaming();
        if (mounted) {
          if (!live) {
            setState(() => _isStreaming = false);
            _statusTimer?.cancel();
          } else {
            _updateViewerCount();
          }
        }
      });
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _registerWithBackend() async {
    setState(() => _isRegistering = true);
    try {
      final res = await http
          .post(
            Uri.parse('$_backendUrl/api/register'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'mobileIp': _deviceIp,
              'streamId': _streamId,
              'deviceName': _deviceName,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _watchUrl = data['watchUrl'] as String?;
          _qrCodeBase64 = data['qrCode'] as String?;
        });
      } else {
        setState(() => _errorMessage = 'Backend error: ${res.statusCode}');
      }
    } catch (e) {
      setState(
        () => _errorMessage =
            'Stream is live but backend unreachable: $e\n'
            'Make sure Node server is running at $_backendUrl',
      );
    } finally {
      if (mounted) setState(() => _isRegistering = false);
    }
  }

  Future<void> _updateViewerCount() async {
    if (_streamId == null) return;
    try {
      final res = await http
          .get(Uri.parse('$_backendUrl/api/stream/$_streamId'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final count = data['viewers'] as int? ?? 0;
        if (mounted && count != _viewerCount)
          setState(() => _viewerCount = count);
      }
    } catch (_) {}
  }

  Future<void> _stopStreaming() async {
    setState(() => _isLoading = true);
    _statusTimer?.cancel();

    // Unregister from backend
    if (_streamId != null) {
      try {
        await http
            .post(
              Uri.parse('$_backendUrl/api/unregister'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'streamId': _streamId}),
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }

    await RtspService.stopServer();
    setState(() {
      _isStreaming = false;
      _watchUrl = null;
      _qrCodeBase64 = null;
      _viewerCount = 0;
    });
    if (mounted) setState(() => _isLoading = false);
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'monospace')),
        backgroundColor: const Color(0xFF1A1A2E),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 24),

              _buildStatusCard(),
              const SizedBox(height: 20),

              if (_watchUrl != null && _qrCodeBase64 != null) ...[
                WatchUrlCard(
                  watchUrl: _watchUrl!,
                  qrCodeBase64: _qrCodeBase64!,
                  deviceName: _deviceName ?? 'Camera',
                  streamId: _streamId!,
                  viewerCount: _viewerCount,
                  onCopy: () {
                    Clipboard.setData(ClipboardData(text: _watchUrl!));
                    _showSnack('Watch URL copied!');
                  },
                ),
                const SizedBox(height: 20),
              ],

              if (_isStreaming && _watchUrl == null && _isRegistering)
                _buildRegistering(),

              if (_errorMessage != null) ...[
                _buildErrorBox(),
                const SizedBox(height: 20),
              ],

              _buildControlButton(),
              const SizedBox(height: 20),
              _buildNetworkInfo(),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() => Row(
    children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.3),
          ),
        ),
        child: const Icon(
          Icons.videocam_rounded,
          color: Color(0xFF00E5FF),
          size: 22,
        ),
      ),
      const SizedBox(width: 12),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'RTSP → WebRTC',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            'Powered by MediaMTX',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 12,
            ),
          ),
        ],
      ),
    ],
  );

  Widget _buildStatusCard() {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (_, __) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF13131F),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _isStreaming
                ? const Color(
                    0xFF00E57F,
                  ).withOpacity(_pulseAnimation.value * 0.6)
                : Colors.white.withValues(alpha: 0.07),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isStreaming ? const Color(0xFF00E57F) : Colors.grey,
                boxShadow: _isStreaming
                    ? [
                        BoxShadow(
                          color: const Color(0xFF00E57F).withValues(alpha: 0.5),
                          blurRadius: 8 * _pulseAnimation.value,
                          spreadRadius: 2 * _pulseAnimation.value,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isStreaming
                        ? 'LIVE — Publishing to MediaMTX'
                        : 'Ready to stream',
                    style: TextStyle(
                      color: _isStreaming
                          ? const Color(0xFF00E57F)
                          : Colors.white.withValues(alpha: 0.6),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_streamId != null)
                    Text(
                      '$_deviceName  ·  ID: $_streamId',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                ],
              ),
            ),
            if (_isStreaming && _viewerCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E57F).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.remove_red_eye,
                      color: Color(0xFF00E57F),
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$_viewerCount',
                      style: const TextStyle(
                        color: Color(0xFF00E57F),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRegistering() => Container(
    padding: const EdgeInsets.all(14),
    margin: const EdgeInsets.only(bottom: 20),
    decoration: BoxDecoration(
      color: const Color(0xFF13131F),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
    ),
    child: Row(
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(Color(0xFF00E5FF)),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'Registering with backend...',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 13,
          ),
        ),
      ],
    ),
  );

  Widget _buildControlButton() {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        onPressed: _isLoading
            ? null
            : (_isStreaming ? _stopStreaming : _startStreaming),
        style: ElevatedButton.styleFrom(
          backgroundColor: _isStreaming
              ? const Color(0xFFFF1744)
              : const Color(0xFF00E5FF),
          foregroundColor: _isStreaming ? Colors.white : Colors.black,
          disabledBackgroundColor: Colors.grey.withValues(alpha: 0.3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
        child: _isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isStreaming
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _isStreaming ? 'STOP STREAMING' : 'START STREAMING',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildErrorBox() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFFF1744).withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFFF1744).withValues(alpha: 0.3)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, color: Color(0xFFFF1744), size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _errorMessage!,
            style: const TextStyle(
              color: Color(0xFFFF1744),
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
        GestureDetector(
          onTap: () => setState(() => _errorMessage = null),
          child: Icon(
            Icons.close,
            color: const Color(0xFFFF1744).withValues(alpha: 0.6),
            size: 18,
          ),
        ),
      ],
    ),
  );

  Widget _buildNetworkInfo() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF0D1B2A),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: const Color(0xFF00E5FF).withValues(alpha: 0.08),
      ),
    ),
    child: Column(
      children: [
        _netRow(
          Icons.phone_android_rounded,
          'Phone IP',
          _deviceIp ?? 'Not on WiFi',
          _deviceIp != null,
        ),
        const SizedBox(height: 6),
        _netRow(Icons.dns_rounded, 'MediaMTX', '$_mediamtxIp:$_rtspPort', true),
        const SizedBox(height: 6),
        _netRow(Icons.cloud_rounded, 'Backend', _backendUrl, true),
        const SizedBox(height: 6),
        _netRow(
          Icons.key_rounded,
          'Stream ID',
          _streamId ?? '-',
          _streamId != null,
        ),
      ],
    ),
  );

  Widget _netRow(IconData icon, String label, String value, bool ok) => Row(
    children: [
      Icon(
        icon,
        color: const Color(0xFF00E5FF).withValues(alpha: 0.5),
        size: 16,
      ),
      const SizedBox(width: 8),
      Text(
        '$label: ',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.4),
          fontSize: 12,
        ),
      ),
      Expanded(
        child: Text(
          value,
          style: TextStyle(
            color: ok
                ? const Color(0xFF00E5FF)
                : Colors.red.withValues(alpha: 0.6),
            fontSize: 12,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}
