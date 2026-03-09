import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/rtsp_service.dart';

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

  String? _streamId;
  String? _mediamtxHost;
  int _mediamtxPort = 8554;

  final _urlCtrl = TextEditingController();

  static const String _mediamtxIp = '103.211.202.131';

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
    try {
      final ip = await RtspService.getDeviceIp();
      if (mounted) setState(() => _deviceIp = ip);
    } catch (_) {}
    final streaming = await RtspService.isStreaming();
    if (mounted) setState(() => _isStreaming = streaming);
  }

  bool _parseUrl(String input) {
    input = input.trim();
    if (input.startsWith('rtsp://')) {
      try {
        final uri = Uri.parse(input);
        _mediamtxHost = uri.host.isNotEmpty ? uri.host : _mediamtxIp;
        _mediamtxPort = uri.port > 0 ? uri.port : 8554;
        _streamId = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : null;
        return _streamId != null && _streamId!.isNotEmpty;
      } catch (_) {
        return false;
      }
    } else if (input.startsWith('cam_') || input.isNotEmpty) {
      _mediamtxHost = _mediamtxIp;
      _mediamtxPort = 8554;
      _streamId = input;
      return true;
    }
    return false;
  }

  Future<void> _startStreaming() async {
    final input = _urlCtrl.text.trim();
    if (input.isEmpty) {
      setState(
        () => _errorMessage = 'Paste the RTSP URL from the streamer app.',
      );
      return;
    }
    if (!_parseUrl(input)) {
      setState(
        () => _errorMessage =
            'Invalid URL. Example: rtsp://103.211.202.131:8554/cam_abc123.',
      );
      return;
    }

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
        mediamtxIp: _mediamtxHost!,
        streamId: _streamId!,
        port: _mediamtxPort,
      );

      if (!success) {
        setState(() {
          _errorMessage =
              'Failed to connect to MediaMTX at $_mediamtxHost:$_mediamtxPort\n'
              'Make sure MediaMTX is running.';
          _isLoading = false;
        });
        return;
      }

      setState(() => _isStreaming = true);

      _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        final live = await RtspService.isStreaming();
        if (mounted && !live) {
          setState(() => _isStreaming = false);
          _statusTimer?.cancel();
        }
      });
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _stopStreaming() async {
    setState(() => _isLoading = true);
    _statusTimer?.cancel();
    await RtspService.stopServer();
    setState(() {
      _isStreaming = false;
    });
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _statusTimer?.cancel();
    _urlCtrl.dispose();
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
              if (!_isStreaming) ...[
                _buildUrlInput(),
                const SizedBox(height: 20),
              ],
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
            'RTSP Publisher',
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

  Widget _buildUrlInput() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF13131F),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Stream URL',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Paste the RTSP URL from the streamer app.\nExample: rtsp://192.168.0.105:8554/cam_abc123',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.35),
            fontSize: 11,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _urlCtrl,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  hintText: 'rtsp://192.168.0.105:8554/cam_xxx',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.25),
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(
                      color: Color(0xFF00E5FF),
                      width: 1.5,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      Icons.paste_rounded,
                      color: Colors.white.withValues(alpha: 0.4),
                      size: 18,
                    ),
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) _urlCtrl.text = data!.text!;
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _buildStatusCard() => AnimatedBuilder(
    animation: _pulseAnimation,
    builder: (_, __) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF13131F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _isStreaming
              ? const Color(0xFF00E57F).withOpacity(_pulseAnimation.value * 0.6)
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
                if (_streamId != null && _isStreaming)
                  Text(
                    'ID: $_streamId',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildControlButton() => SizedBox(
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                  _isStreaming ? Icons.stop_rounded : Icons.play_arrow_rounded,
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
        _netRow(
          Icons.dns_rounded,
          'MediaMTX',
          '${_mediamtxHost ?? _mediamtxIp}:$_mediamtxPort',
          true,
        ),
        const SizedBox(height: 6),
        _netRow(
          Icons.key_rounded,
          'Stream ID',
          _streamId ?? '(paste URL above)',
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
