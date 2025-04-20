<!--
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/tools/pub/writing-package-pages).

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/to/develop-packages).
-->

# Video Timestamp

A Flutter package for adding timestamp watermarks to videos.

## Features

- Add timestamp watermarks to videos
- Customize timestamp format, font size, color, and position
- Simple and easy to use API
- Built on top of FFmpeg for reliable video processing

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  video_timestamp: ^1.0.0
```

## Usage

```dart
import 'package:video_timestamp/video_timestamp.dart';

// Add timestamp to a video
final outputPath = await VideoTimestamp.addTimestamp(
  inputPath: '/path/to/input/video.mp4',
  outputPath: '/path/to/output/video.mp4', // Optional
  fontSize: 24, // Optional, default is 24
  fontColor: 'white', // Optional, default is 'white'
  position: 'bottom-right', // Optional, default is 'bottom-right'
);
```

### Parameters

- `inputPath`: Path to the input video file
- `outputPath`: Path to save the output video file (optional)
- `fontSize`: Font size of the timestamp (optional, default: 24)
- `fontColor`: Color of the timestamp (optional, default: 'white')
- `position`: Position of the timestamp (optional, default: 'bottom-right')
  - Available positions: 'top-left', 'top-right', 'bottom-left', 'bottom-right'

## License

MIT
