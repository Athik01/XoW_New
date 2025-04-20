import 'dart:io';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:intl/intl.dart';

/// A Calculator.
class Calculator {
  /// Returns [value] plus 1.
  int addOne(int value) => value + 1;
}

class VideoTimestamp {
  /// Adds a timestamp watermark to a video file
  /// 
  /// [inputPath] - Path to the input video file
  /// [outputPath] - Optional path for the output file. If not provided, will be generated
  /// [fontSize] - Font size for the timestamp (default: 24)
  /// [fontColor] - Color of the timestamp text (default: white)
  /// [position] - Position of the timestamp ('top-left', 'top-right', 'bottom-left', 'bottom-right')
  static Future<String> addTimestamp({
    required String inputPath,
    String? outputPath,
    int fontSize = 24,
    String fontColor = 'white',
    String position = 'top-left',
  }) async {
    // Generate output path if not provided
    if (outputPath == null) {
      final directory = await getTemporaryDirectory();
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      outputPath = '${directory.path}/watermarked_$timestamp.mp4';
    }

    // Get current timestamp
    final now = DateTime.now();
    final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(now);

    // Determine position coordinates
    String x, y;
    switch (position) {
      case 'top-left':
        x = '10';
        y = '10';
        break;
      case 'top-right':
        x = '(w-text_w-10)';
        y = '10';
        break;
      case 'bottom-left':
        x = '10';
        y = '(h-text_h-10)';
        break;
      case 'bottom-right':
        x = '(w-text_w-10)';
        y = '(h-text_h-10)';
        break;
      default:
        x = '10';
        y = '10';
    }

    // Build FFmpeg command
    final command = '-y -i "$inputPath" '
        '-vf "drawtext=text=\'$timestamp\':fontcolor=$fontColor:fontsize=$fontSize:x=$x:y=$y:box=1:boxcolor=black@0.5" '
        '-c:v libx264 -preset ultrafast -c:a copy '
        '"$outputPath"';

    // Execute FFmpeg command
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      return outputPath;
    } else {
      // Try a simpler command if the first one fails
      final fallbackCommand = '-y -i "$inputPath" '
          '-vf "drawtext=text=\'$timestamp\':fontcolor=$fontColor:fontsize=$fontSize:x=$x:y=$y" '
          '-c:v libx264 -preset ultrafast -c:a copy '
          '"$outputPath"';

      final fallbackSession = await FFmpegKit.execute(fallbackCommand);
      final fallbackReturnCode = await fallbackSession.getReturnCode();

      if (ReturnCode.isSuccess(fallbackReturnCode)) {
        return outputPath;
      } else {
        throw Exception('Failed to add timestamp watermark to video');
      }
    }
  }
}
