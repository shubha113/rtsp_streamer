import 'package:flutter/material.dart';

class UrlCard extends StatelessWidget {
  final String url;
  final bool isStreaming;
  final VoidCallback onCopy;

  const UrlCard({
    super.key,
    required this.url,
    required this.isStreaming,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B2A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isStreaming
              ? const Color(0xFF00E5FF).withOpacity(0.4)
              : Colors.white.withOpacity(0.07),
          width: 1.5,
        ),
        boxShadow: isStreaming
            ? [
          BoxShadow(
            color: const Color(0xFF00E5FF).withOpacity(0.08),
            blurRadius: 20,
            spreadRadius: 2,
          )
        ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'RTSP URL',
            style: TextStyle(
              color: Colors.white.withOpacity(0.35),
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  url,
                  style: TextStyle(
                    color: isStreaming
                        ? const Color(0xFF00E5FF)
                        : Colors.white.withOpacity(0.7),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: onCopy,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isStreaming
                        ? const Color(0xFF00E5FF).withOpacity(0.15)
                        : Colors.white.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.copy_rounded,
                    size: 16,
                    color: isStreaming
                        ? const Color(0xFF00E5FF)
                        : Colors.white.withOpacity(0.4),
                  ),
                ),
              ),
            ],
          ),
          if (isStreaming) ...[
            const SizedBox(height: 10),
            Text(
              '● LIVE — Ready to connect in VLC',
              style: TextStyle(
                color: const Color(0xFF00E57F).withOpacity(0.8),
                fontSize: 12,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}