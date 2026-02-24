import 'package:flutter/material.dart';

class ControlButton extends StatelessWidget {
  final bool isStreaming;
  final bool isLoading;
  final VoidCallback onStart;
  final VoidCallback onStop;

  const ControlButton({
    super.key,
    required this.isStreaming,
    required this.isLoading,
    required this.onStart,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          gradient: isStreaming
              ? const LinearGradient(
            colors: [Color(0xFFFF1744), Color(0xFFD50000)],
          )
              : const LinearGradient(
            colors: [Color(0xFF00E5FF), Color(0xFF0091EA)],
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: isStreaming
                  ? const Color(0xFFFF1744).withValues(alpha: 0.35)
                  : const Color(0xFF00E5FF).withValues(alpha: 0.35),
              blurRadius: 20,
              spreadRadius: 0,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ElevatedButton(
          onPressed: isLoading
              ? null
              : (isStreaming ? onStop : onStart),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: isLoading
              ? const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          )
              : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isStreaming
                    ? Icons.stop_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 26,
              ),
              const SizedBox(width: 10),
              Text(
                isStreaming ? 'STOP STREAMING' : 'START STREAMING',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}