import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/rtsp_service.dart';
import '../widgets/url_card.dart';
import '../widgets/status_indicator.dart';
import '../widgets/control_button.dart';

class StreamScreen extends StatefulWidget {
  const StreamScreen({super.key});

  @override
  State<StreamScreen> createState() => _StreamScreenState();
}

class _StreamScreenState extends State<StreamScreen>
    with SingleTickerProviderStateMixin {
  bool _isStreaming = false;
  bool _isLoading = false;
  bool _torchOn = false;
  String? _deviceIp;
  String? _errorMessage;
  int _port = 8554;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Timer? _statusTimer;

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
    _init();
  }

  Future<void> _init() async {
    await _fetchIp();
    await _checkIfAlreadyStreaming();
  }

  Future<void> _fetchIp() async {
    try {
      final ip = await RtspService.getDeviceIp();
      setState(() => _deviceIp = ip);
    } catch (_) {}
  }

  Future<void> _checkIfAlreadyStreaming() async {
    final streaming = await RtspService.isStreaming();
    if (mounted) setState(() => _isStreaming = streaming);
  }

  Future<void> _startStreaming() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Check/request permissions first
      bool hasPermission = await RtspService.checkPermissions();
      if (!hasPermission) {
        hasPermission = await RtspService.requestPermissions();
      }

      if (!hasPermission) {
        setState(() {
          _errorMessage =
          'Camera and microphone permissions are required.\nGo to Settings → App → Permissions.';
          _isLoading = false;
        });
        return;
      }

      // Refresh IP before starting
      await _fetchIp();

      final success = await RtspService.startServer(port: _port);

      if (success) {
        setState(() => _isStreaming = true);
        // Poll status every 5 seconds
        _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
          final live = await RtspService.isStreaming();
          if (mounted && !live) {
            setState(() => _isStreaming = false);
            _statusTimer?.cancel();
          }
        });
      } else {
        setState(() => _errorMessage = 'Failed to start server. Check logs.');
      }
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _stopStreaming() async {
    setState(() => _isLoading = true);
    _statusTimer?.cancel();
    try {
      await RtspService.stopServer();
      setState(() => _isStreaming = false);
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _switchCamera() async {
    try {
      await RtspService.switchCamera();
    } catch (e) {
      _showSnack('Could not switch camera: $e');
    }
  }

  Future<void> _toggleTorch() async {
    await RtspService.toggleTorch();
    setState(() => _torchOn = !_torchOn);
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

  String get _rtspUrl {
    final ip = _deviceIp ?? '0.0.0.0';
    return 'rtsp://$ip:$_port/live';
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
              const SizedBox(height: 28),
              StatusIndicator(
                isStreaming: _isStreaming,
                pulseAnimation: _pulseAnimation,
              ),
              const SizedBox(height: 24),
              UrlCard(
                url: _rtspUrl,
                isStreaming: _isStreaming,
                onCopy: () {
                  Clipboard.setData(ClipboardData(text: _rtspUrl));
                  _showSnack('URL copied to clipboard!');
                },
              ),
              const SizedBox(height: 20),
              _buildPortRow(),
              const SizedBox(height: 32),
              ControlButton(
                isStreaming: _isStreaming,
                isLoading: _isLoading,
                onStart: _startStreaming,
                onStop: _stopStreaming,
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 20),
                _buildErrorBox(),
              ],
              const SizedBox(height: 32),
              _buildVlcInstructions(),
              const SizedBox(height: 20),
              _buildNetworkInfo(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0xFF00E5FF).withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
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
              'RTSP Streamer',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            Text(
              'LAN · VLC Compatible',
              style: TextStyle(
                color: Colors.white.withOpacity(0.4),
                fontSize: 12,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const Spacer(),
        IconButton(
          onPressed: _init,
          icon: Icon(
            Icons.refresh_rounded,
            color: Colors.white.withOpacity(0.5),
          ),
          tooltip: 'Refresh IP',
        ),
      ],
    );
  }

  Widget _buildPortRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF13131F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      child: Row(
        children: [
          Icon(Icons.settings_ethernet, color: const Color(0xFF00E5FF).withOpacity(0.7), size: 18),
          const SizedBox(width: 10),
          Text(
            'Port',
            style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13),
          ),
          const Spacer(),
          _portChip(1935),
          const SizedBox(width: 8),
          _portChip(8554),
          const SizedBox(width: 8),
          _portChip(554),
        ],
      ),
    );
  }

  Widget _portChip(int port) {
    final selected = _port == port;
    return GestureDetector(
      onTap: _isStreaming ? null : () => setState(() => _port = port),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF00E5FF).withOpacity(0.18)
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? const Color(0xFF00E5FF).withOpacity(0.6)
                : Colors.transparent,
          ),
        ),
        child: Text(
          '$port',
          style: TextStyle(
            color: selected ? const Color(0xFF00E5FF) : Colors.white.withOpacity(0.4),
            fontSize: 13,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFFFFD600).withOpacity(0.1)
              : const Color(0xFF13131F),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? const Color(0xFFFFD600).withOpacity(0.4)
                : Colors.white.withOpacity(0.08),
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: active ? const Color(0xFFFFD600) : Colors.white.withOpacity(0.6),
              size: 22,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: active ? const Color(0xFFFFD600) : Colors.white.withOpacity(0.4),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFF1744).withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFF1744).withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFFF1744), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Color(0xFFFF1744), fontSize: 13, height: 1.5),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _errorMessage = null),
            child: Icon(Icons.close, color: const Color(0xFFFF1744).withOpacity(0.6), size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildVlcInstructions() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF13131F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.play_circle_outline, color: Color(0xFFFF9800), size: 18),
              const SizedBox(width: 8),
              Text(
                'Open in VLC',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _step('1', 'Start streaming on this device'),
          _step('2', 'Open VLC on your computer'),
          _step('3', 'Media → Open Network Stream'),
          _step('4', 'Paste the RTSP URL above'),
          _step('5', 'Click Play — live video starts!'),
          const SizedBox(height: 10),
          Text(
            '⚠  Both devices must be on the same WiFi network.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(String num, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF00E5FF).withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              num,
              style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNetworkInfo() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi, color: const Color(0xFF00E5FF).withOpacity(0.5), size: 18),
          const SizedBox(width: 10),
          Text(
            'Device IP: ',
            style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13),
          ),
          Text(
            _deviceIp ?? 'Not connected',
            style: TextStyle(
              color: _deviceIp != null ? const Color(0xFF00E5FF) : Colors.red.withOpacity(0.6),
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          Text(
            'Port $_port',
            style: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 12),
          ),
        ],
      ),
    );
  }
}