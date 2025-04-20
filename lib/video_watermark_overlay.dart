import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

class VideoWatermarkOverlay extends StatefulWidget {
  final Widget child;
  final String location;
  final DateTime initialTime;
  final bool showFrame;
  final TextStyle? timestampStyle;
  final TextStyle? locationStyle;
  final Color frameColor;
  final double frameWidth;
  final VideoPlayerController? controller;

  const VideoWatermarkOverlay({
    Key? key,
    required this.child,
    required this.location,
    required this.initialTime,
    required this.controller,
    this.showFrame = true,
    this.timestampStyle,
    this.locationStyle,
    this.frameColor = Colors.white,
    this.frameWidth = 2.0,
  }) : super(key: key);

  @override
  State<VideoWatermarkOverlay> createState() => _VideoWatermarkOverlayState();
}

class _VideoWatermarkOverlayState extends State<VideoWatermarkOverlay> {
  DateTime _currentTime = DateTime.now();
  int _frameCounter = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _currentTime = widget.initialTime;
    _startTimer();
    widget.controller?.addListener(_videoListener);
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (timer) {
      if (widget.controller != null && widget.controller!.value.isPlaying) {
        setState(() {
          // Update time based on video position
          _currentTime = widget.initialTime.add(widget.controller!.value.position);
          // Update frame counter (30 fps)
          _frameCounter = (widget.controller!.value.position.inMilliseconds / 33.33).round();
        });
      }
    });
  }

  void _videoListener() {
    if (widget.controller!.value.position == Duration.zero) {
      setState(() {
        _currentTime = widget.initialTime;
        _frameCounter = 0;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller?.removeListener(_videoListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Get screen size for responsive positioning
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final safeHeight = size.height - padding.top - padding.bottom;
    
    return Stack(
      children: [
        // Original video content
        widget.child,

        // Frame border
        if (widget.showFrame)
          Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: widget.frameColor,
                width: widget.frameWidth,
              ),
            ),
          ),

        // Top overlay with timestamp and frame counter
        Positioned(
          top: safeHeight * 0.02, // 2% from top
          left: size.width * 0.02, // 2% from left
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: size.width * 0.02,
              vertical: safeHeight * 0.01,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Date
                Text(
                  'Date: ${DateFormat('yyyy-MM-dd').format(_currentTime)}',
                  style: widget.timestampStyle ?? TextStyle(
                    color: Colors.white,
                    fontSize: size.width * 0.035,
                    fontWeight: FontWeight.w500,
                    shadows: const [
                      Shadow(
                        blurRadius: 2.0,
                        color: Colors.black,
                        offset: Offset(1.0, 1.0),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: safeHeight * 0.005),
                // Time
                Text(
                  'Time: ${DateFormat('HH:mm:ss.SSS').format(_currentTime)}',
                  style: widget.timestampStyle ?? TextStyle(
                    color: Colors.white,
                    fontSize: size.width * 0.035,
                    fontWeight: FontWeight.w500,
                    shadows: const [
                      Shadow(
                        blurRadius: 2.0,
                        color: Colors.black,
                        offset: Offset(1.0, 1.0),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Frame counter at top right
        Positioned(
          top: safeHeight * 0.02, // 2% from top
          right: size.width * 0.02, // 2% from right
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: size.width * 0.02,
              vertical: safeHeight * 0.01,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'Frame: ${_frameCounter.toString().padLeft(8, '0')}',
              style: widget.timestampStyle ?? TextStyle(
                color: Colors.white,
                fontSize: size.width * 0.035,
                fontWeight: FontWeight.w500,
                shadows: const [
                  Shadow(
                    blurRadius: 2.0,
                    color: Colors.black,
                    offset: Offset(1.0, 1.0),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Location overlay at bottom
        Positioned(
          bottom: safeHeight * 0.02, // 2% from bottom
          left: size.width * 0.02, // 2% from left
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: size.width * 0.02,
              vertical: safeHeight * 0.01,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.location_on,
                  color: Colors.white,
                  size: size.width * 0.04,
                ),
                SizedBox(width: size.width * 0.01),
                Text(
                  widget.location,
                  style: widget.locationStyle ?? TextStyle(
                    color: Colors.white,
                    fontSize: size.width * 0.035,
                    fontWeight: FontWeight.w500,
                    shadows: const [
                      Shadow(
                        blurRadius: 2.0,
                        color: Colors.black,
                        offset: Offset(1.0, 1.0),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// Extension for video player to add watermark
extension VideoPlayerWatermark on Widget {
  Widget addWatermark({
    required String location,
    required DateTime initialTime,
    required VideoPlayerController controller,
    bool showFrame = true,
    TextStyle? timestampStyle,
    TextStyle? locationStyle,
    Color frameColor = Colors.white,
    double frameWidth = 2.0,
  }) {
    return VideoWatermarkOverlay(
      location: location,
      initialTime: initialTime,
      controller: controller,
      showFrame: showFrame,
      timestampStyle: timestampStyle,
      locationStyle: locationStyle,
      frameColor: frameColor,
      frameWidth: frameWidth,
      child: this,
    );
  }
} 