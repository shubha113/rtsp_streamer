import 'package:flutter/material.dart';

class StatusIndicator extends StatelessWidget {
  final bool isStreaming;
  final Animation<double> pulseAnimation;

  const StatusIndicator({
    super.key,
    required this.isStreaming,
    required this.pulseAnimation,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isStreaming
            ? const Color(0xFF00E57F).withValues(alpha: 0.07)
            : const Color(0xFF13131F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isStreaming
              ? const Color(0xFF00E57F).withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: pulseAnimation,
            builder: (context, child) {
              return Opacity(
                opacity: isStreaming ? pulseAnimation.value : 1.0,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: isStreaming
                        ? const Color(0xFF00E57F)
                        : Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                    boxShadow: isStreaming
                        ? [
                      BoxShadow(
                        color: const Color(0xFF00E57F).withValues(alpha: 0.5),
                        blurRadius: 8,
                        spreadRadius: 2,
                      )
                    ]
                        : null,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 12),
          Text(
            isStreaming ? 'STREAMING LIVE' : 'IDLE — Ready to stream',
            style: TextStyle(
              color: isStreaming
                  ? const Color(0xFF00E57F)
                  : Colors.white.withValues(alpha: 0.35),
              fontSize: 13,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          const Spacer(),
          if (isStreaming)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF00E57F).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'H264',
                style: TextStyle(
                  color: Color(0xFF00E57F),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
            ),
        ],
      ),
    );
  }
}