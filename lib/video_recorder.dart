import 'dart:async';
import 'dart:io';
import 'package:video_player/video_player.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:video_compress/video_compress.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import './video_watermark_overlay.dart';

class VideoRecorder extends StatefulWidget {
  final String? videoPath;
  
  const VideoRecorder({Key? key, this.videoPath}) : super(key: key);

  @override
  State<VideoRecorder> createState() => _VideoRecorderState();
}

class _VideoRecorderState extends State<VideoRecorder> {
  CameraController? _controller;
  bool _isRecording = false;
  String? _currentVideoPath;
  double _trimStart = 0.0;
  double _trimEnd = 0.0;

  // Show/hide the trim UI
  bool _showTrimControls = false;

  // Full length of the recorded video
  double _videoDuration = 0.0;
  Timer? _hourlyTimer;
  Timer? _recordingTimer;
  Duration _recordingDuration = Duration.zero;
  VideoPlayerController? _videoPlayerController;
  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _showJumpToTime = false;
  double _startTrim = 0.0;
  double _endTrim = 1.0;
  bool _isTrimming = false;
  bool _isProcessing = false;
  TextEditingController _timeController = TextEditingController();
  String _location = "MAIN ENTRANCE";
  String _currentTime = '';
  Timer? _clockTimer;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    // Request permissions first, then initialize camera
    _requestPermissions().then((_) => _initializeCamera());
    
    // Start clock timer to update timestamp
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _currentTime = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
        });
      }
    });
    
    // Set initial time
    _currentTime = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
  }

  Future<void> _requestPermissions() async {
    // Determine which storage permissions to request based on SDK version
    List<Permission> permissionsToRequest = [
      Permission.camera,
      Permission.microphone,
    ];
    
    // For Android, add all possible storage permissions
    if (Platform.isAndroid) {
      // Add all storage-related permissions
      permissionsToRequest.add(Permission.storage);
      
      // For Android 11+ (API level 30+), we need to handle MANAGE_EXTERNAL_STORAGE separately
      // as it requires a special flow to settings
      bool needsManageExternalStorage = false;
      try {
        // Check Android version
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        if (androidInfo.version.sdkInt >= 30) { // Android 11+
          needsManageExternalStorage = true;
        }
      } catch (e) {
        debugPrint('Error checking Android version: $e');
      }
      
      // Add newer media permissions if available
      try {
        permissionsToRequest.add(Permission.photos);
        permissionsToRequest.add(Permission.videos);
        permissionsToRequest.add(Permission.audio);
        
        if (needsManageExternalStorage) {
          permissionsToRequest.add(Permission.manageExternalStorage);
        }
      } catch (e) {
        debugPrint('Some media permissions might not be available: $e');
      }
    } else {
      // For iOS or other platforms
      permissionsToRequest.add(Permission.storage);
    }
    
    // Request all needed permissions
    Map<Permission, PermissionStatus> statuses = await permissionsToRequest.request();
    
    // For Android 11+, check if we need to direct to settings for MANAGE_EXTERNAL_STORAGE
    if (Platform.isAndroid) {
      try {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        if (androidInfo.version.sdkInt >= 30) { // Android 11+
          // Check for manage external storage permission
          final hasManageStorage = await Permission.manageExternalStorage.isGranted;
          if (!hasManageStorage && mounted) {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Additional permission required'),
                content: const Text(
                    'To save videos to Downloads folder, please enable "Allow management of all files" in the next screen.'),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      Permission.manageExternalStorage.request();
                    },
                    child: const Text('Continue'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            );
          }
        }
      } catch (e) {
        debugPrint('Error checking for MANAGE_EXTERNAL_STORAGE: $e');
      }
    }
    
    // Check if essential permissions were granted
    if (statuses[Permission.camera] != PermissionStatus.granted ||
        statuses[Permission.microphone] != PermissionStatus.granted) {
      // Show dialog if essential permissions are denied
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Permissions required'),
            content: const Text(
                'Camera and microphone permissions are required for this app to function properly.'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  openAppSettings();
                },
                child: const Text('Open Settings'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _initializeCamera() async {
    try {
      // Check essential permissions - camera and microphone
      bool hasCameraPermission = await Permission.camera.isGranted;
      bool hasMicrophonePermission = await Permission.microphone.isGranted;
      bool hasStoragePermission = await Permission.storage.isGranted;
      
      bool hasMediaPermissions = hasStoragePermission;
      // For newer Android versions, also check granular media permissions
      if (Platform.isAndroid) {
        try {
          hasMediaPermissions = hasStoragePermission || 
                               await Permission.photos.isGranted || 
                               await Permission.videos.isGranted;
        } catch (e) {
          // Fallback to storage permission if media permissions aren't available
          debugPrint('Error checking media permissions: $e');
        }
      }
      
      if (hasCameraPermission && hasMicrophonePermission && hasMediaPermissions) {
        debugPrint('All permissions granted, initializing camera');
        final cameras = await availableCameras();
        if (cameras.isEmpty) {
          debugPrint('No cameras available');
          return;
        }

        _controller = CameraController(
          cameras[0],
          ResolutionPreset.high,
          enableAudio: true,
        );

        await _controller!.initialize();
        if (mounted) setState(() {});
      } else {
        debugPrint('Permission check results: Camera=$hasCameraPermission, Mic=$hasMicrophonePermission, Storage=$hasStoragePermission');
        await _requestPermissions();
      }
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }
  }

  Future<String> _getVideoPath() async {
    try {
      // For Android, try to save in the Downloads folder
      if (Platform.isAndroid) {
        // Get the Downloads directory path
        Directory? downloadsDir;
        try {
          // Use getExternalStorageDirectory and navigate to Downloads
          Directory? extDir = await getExternalStorageDirectory();
          if (extDir != null) {
            String androidDownloadsPath = extDir.path.split('/Android')[0] + '/Download';
            downloadsDir = Directory(androidDownloadsPath);
          }
        } catch (e) {
          debugPrint('Error accessing Downloads directory: $e');
        }

        if (downloadsDir != null && await downloadsDir.exists()) {
          final videosDir = Directory('${downloadsDir.path}/XoW_Videos');
          if (!await videosDir.exists()) {
            await videosDir.create(recursive: true);
          }

          final now = DateTime.now();
          final dateDir = Directory('${videosDir.path}/${DateFormat('yyyy-MM-dd').format(now)}');
          if (!await dateDir.exists()) {
            await dateDir.create();
          }

          return '${dateDir.path}/${DateFormat('HH-mm-ss').format(now)}.mp4';
        }
      }
      
      // Fallback to app storage if Downloads is not accessible or not Android
      Directory? directory = await getExternalStorageDirectory();
      if (directory == null) {
        directory = await getApplicationDocumentsDirectory();
        debugPrint('Using application documents directory: ${directory.path}');
      }
      
      final videosDir = Directory('${directory.path}/XoW_Videos');
      if (!await videosDir.exists()) {
        await videosDir.create(recursive: true);
      }

      final now = DateTime.now();
      final dateDir = Directory('${videosDir.path}/${DateFormat('yyyy-MM-dd').format(now)}');
      if (!await dateDir.exists()) {
        await dateDir.create();
      }

      return '${dateDir.path}/${DateFormat('HH-mm-ss').format(now)}.mp4';
    } catch (e) {
      debugPrint('Error getting video path: $e');
      // Fallback to temp directory if all else fails
      final tempDir = await getTemporaryDirectory();
      final now = DateTime.now();
      return '${tempDir.path}/XoW_${DateFormat('yyyy-MM-dd_HH-mm-ss').format(now)}.mp4';
    }
  }

  Future<void> _startRecording() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      final videoPath = await _getVideoPath();
      await _controller!.startVideoRecording();
      setState(() {
        _isRecording = true;
        _currentVideoPath = videoPath;
        _recordingDuration = Duration.zero;
      });

      // Start recording timer for UI
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _recordingDuration += const Duration(seconds: 1);
        });
      });

      // Start hourly timer
      _hourlyTimer = Timer.periodic(const Duration(hours: 1), (timer) {
        if (_isRecording) {
          _stopRecording();
          _startRecording();
        }
      });
    } catch (e) {
      debugPrint('Error starting video recording: $e');
    }
  }

  Future<void> _stopRecording() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      // Cancel timers first
      _hourlyTimer?.cancel();
      _recordingTimer?.cancel();
      
      // Show a loading indicator while stopping
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Stopping recording...')),
        );
      }
      
      debugPrint('Stopping video recording...');
      final XFile videoFile = await _controller!.stopVideoRecording();
      debugPrint('Video recorded to: ${videoFile.path}');
      
      // Check if file exists and has content
      final File file = File(videoFile.path);
      if (!await file.exists()) {
        debugPrint('ERROR: Recorded video file does not exist!');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Error: Recorded file not found')),
          );
        }
        setState(() {
          _isRecording = false;
        });
        return;
      }
      
      final int fileSize = await file.length();
      debugPrint('Recorded file size: $fileSize bytes');
      
      if (fileSize <= 0) {
        debugPrint('ERROR: Recorded video file is empty!');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Error: Recorded file is empty')),
          );
        }
        setState(() {
          _isRecording = false;
        });
        return;
      }

      // Create destination directory
      final String destinationPath = await _getVideoPath();
      debugPrint('Destination path: $destinationPath');
      final Directory destinationDir = Directory(path.dirname(destinationPath));
      if (!await destinationDir.exists()) {
        await destinationDir.create(recursive: true);
        debugPrint('Created directory: ${destinationDir.path}');
      }
      
      // Copy file to destination
      final File destinationFile = File(destinationPath);
      try {
        await file.copy(destinationPath);
        debugPrint('Copied video to: $destinationPath');
        
        // Verify the copy worked
        if (await destinationFile.exists()) {
          debugPrint('Destination file exists, size: ${await destinationFile.length()} bytes');
        } else {
          debugPrint('ERROR: Failed to copy video file!');
        }
      } catch (e) {
        debugPrint('Error copying video file: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error saving video: $e')),
          );
        }
      }

      setState(() {
        _isRecording = false;
      });

      // Process the video with timestamp overlay
      try {
        await _processVideo(destinationPath);
        
        // Provide feedback on success
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Video saved to: ${path.basename(destinationPath)}'),
              duration: const Duration(seconds: 3),
              action: SnackBarAction(
                label: 'VIEW',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const RecordedVideosList(),
                    ),
                  );
                },
              ),
            ),
          );
        }
      } catch (e) {
        debugPrint('Error processing video: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error processing video: $e')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error stopping video recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error stopping recording: $e')),
        );
      }
      setState(() {
        _isRecording = false;
      });
    }
  }

  Future<void> _processVideo(String videoPath) async {
    try {
      debugPrint('Processing video: $videoPath');
      
      final File videoFile = File(videoPath);
      if (!await videoFile.exists()) {
        throw Exception('Video file not found: $videoPath');
      }

      final directory = path.dirname(videoPath);
      final filename = path.basename(videoPath);
      final timestamp = DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now());
      final tempPath = '$directory/temp_$timestamp$filename';

      // Show processing indicator
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Processing video...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      
      // Step 1: Try to copy the video stream first (fastest)
      String command = '-y -i "$videoPath" -c copy "$tempPath"';
      
      debugPrint('Attempting fast copy: $command');
      final copySession = await FFmpegKit.execute(command);
      final copyReturnCode = await copySession.getReturnCode();

      if (!ReturnCode.isSuccess(copyReturnCode)) {
        // Step 2: If copy fails, try basic re-encoding
        debugPrint('Copy failed, trying re-encode...');
        command = '-y -i "$videoPath" -c:v libx264 -preset ultrafast -c:a aac "$tempPath"';
        
        final encodeSession = await FFmpegKit.execute(command);
        final encodeReturnCode = await encodeSession.getReturnCode();
        
        if (!ReturnCode.isSuccess(encodeReturnCode)) {
          // Step 3: If that fails too, try with lower quality
          debugPrint('Re-encode failed, trying with lower quality...');
          command = '-y -i "$videoPath" -c:v libx264 -preset ultrafast -crf 28 -c:a aac -strict experimental "$tempPath"';
          
          final lastSession = await FFmpegKit.execute(command);
          final lastReturnCode = await lastSession.getReturnCode();
          
          if (!ReturnCode.isSuccess(lastReturnCode)) {
            throw Exception('All video processing attempts failed');
          }
        }
      }

      // Verify the temp file
      final tempFile = File(tempPath);
      if (!await tempFile.exists() || await tempFile.length() == 0) {
        throw Exception('Failed to create processed video file');
      }

      // Now try to add text overlay in a separate pass
      final outputPath = '$directory/processed_$timestamp$filename';
      final dateStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
      
      command = '-y -i "$tempPath" -vf "drawtext=text=\'$dateStr\':fontcolor=white:fontsize=24:x=10:y=10" '
          '-c:v libx264 -preset ultrafast -c:a copy "$outputPath"';

      debugPrint('Attempting to add text: $command');
      final textSession = await FFmpegKit.execute(command);
      final textReturnCode = await textSession.getReturnCode();

      if (ReturnCode.isSuccess(textReturnCode) && 
          await File(outputPath).exists() && 
          await File(outputPath).length() > 0) {
        // Text overlay succeeded
        await tempFile.delete();
        final processedFile = File(outputPath);
        await videoFile.delete();
        await processedFile.rename(videoPath);
          } else {
        // If text overlay failed, just use the temp file
        debugPrint('Text overlay failed, using basic processed file');
        await videoFile.delete();
        await tempFile.rename(videoPath);
      }

            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Video processed successfully'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error processing video: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error processing video: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      rethrow;
    }
  }

  Future<String> _getOutputPath(String filename) async {
    try {
      Directory? directory = await getExternalStorageDirectory();
      if (directory == null) {
        directory = await getApplicationDocumentsDirectory();
      }
      
      final videosDir = Directory('${directory.path}/XoW_Videos');
      if (!await videosDir.exists()) {
        await videosDir.create(recursive: true);
      }

      final now = DateTime.now();
      final dateDir = Directory('${videosDir.path}/${DateFormat('yyyy-MM-dd').format(now)}');
      if (!await dateDir.exists()) {
        await dateDir.create();
      }

      return '${dateDir.path}/$filename';
        } catch (e) {
      debugPrint('Error getting output path: $e');
      final tempDir = await getTemporaryDirectory();
      return '${tempDir.path}/$filename';
    }
  }

  Future<void> _trimVideo() async {
    if (_currentVideoPath == null || _isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      final videoFile = File(_currentVideoPath!);
      if (!await videoFile.exists()) {
        throw Exception('Video file not found');
      }

      // Get video duration
      final duration = await _getVideoDuration(videoFile);
      if (duration <= 0) {
        throw Exception('Invalid video duration');
      }

      // Calculate trim points in seconds
      final startTime = (duration * _startTrim).round();
      final endTime = (duration * _endTrim).round();
      
      if (startTime >= endTime) {
        throw Exception('Invalid trim range');
      }

      // Create output path
      final directory = path.dirname(_currentVideoPath!);
      final filename = path.basename(_currentVideoPath!);
      final outputPath = path.join(
        directory,
        'trimmed_${DateTime.now().millisecondsSinceEpoch}_$filename',
      );

      // Show progress indicator
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Trimming video...'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      // First attempt: Fast trim using stream copy
      String ffmpegCommand = '-y -i "${videoFile.path}" -ss $startTime -t ${endTime - startTime} '
          '-c:v copy -c:a copy -avoid_negative_ts make_zero '
          '"$outputPath"';

      debugPrint('Attempting fast trim with command: $ffmpegCommand');
      
      final session = await FFmpegKit.execute(ffmpegCommand);
      final returnCode = await session.getReturnCode();
      
      // If fast trim fails, try with re-encoding
      if (!ReturnCode.isSuccess(returnCode)) {
        debugPrint('Fast trim failed, attempting with re-encoding...');
        
        ffmpegCommand = '-y -i "${videoFile.path}" -ss $startTime -t ${endTime - startTime} '
            '-c:v libx264 -preset ultrafast -c:a aac '
            '-avoid_negative_ts make_zero "$outputPath"';
            
        final reencodeSession = await FFmpegKit.execute(ffmpegCommand);
        final reencodeReturnCode = await reencodeSession.getReturnCode();
        final reencodeLogs = await reencodeSession.getOutput();
        
        debugPrint('Re-encode FFmpeg logs: $reencodeLogs');
        
        if (!ReturnCode.isSuccess(reencodeReturnCode)) {
          throw Exception('Failed to trim video: $reencodeLogs');
        }
      }

      // Verify the output file
      final outputFile = File(outputPath);
      if (!await outputFile.exists()) {
        throw Exception('Output file was not created');
      }

      final outputSize = await outputFile.length();
      if (outputSize == 0) {
        await outputFile.delete();
        throw Exception('Output file is empty');
      }

      // Update current video path and reset trim state
      setState(() {
        _currentVideoPath = outputPath;
        _startTrim = 0.0;
        _endTrim = 1.0;
        _isTrimming = false;
      });

      // Show success message
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Video trimmed successfully'),
            action: SnackBarAction(
              label: 'VIEW',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => VideoPlayerScreen(videoPath: outputPath),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error trimming video: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<int> _getVideoDuration(File videoFile) async {
    try {
      final result = await FFmpegKit.execute(
        '-i ${videoFile.path} -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1'
      );
      final returnCode = await result.getReturnCode();
      if (ReturnCode.isSuccess(returnCode)) {
        final output = await result.getOutput();
        return double.parse(output ?? '0').round();
      }
      throw Exception('Failed to get video duration');
    } catch (e) {
      debugPrint('Error getting video duration: $e');
      return 0;
    }
  }

  Future<void> _showSaveOptions() async {
    if (_currentVideoPath == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Options'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.save),
              title: const Text('Save'),
              onTap: () {
                Navigator.pop(context);
                _saveVideo(false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Save as Copy'),
              onTap: () {
                Navigator.pop(context);
                _saveVideo(true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveVideo(bool saveAsCopy) async {
    if (_currentVideoPath == null) return;

    setState(() {
      _isSaving = true;
    });

    try {
      final sourceFile = File(_currentVideoPath!);
      if (!await sourceFile.exists()) {
        throw Exception('Video file not found');
      }

      final outputPath = await _getOutputPath(
        '${saveAsCopy ? 'copy_' : ''}${DateTime.now().millisecondsSinceEpoch}.mp4'
      );

      if (saveAsCopy) {
        await sourceFile.copy(outputPath);
      } else {
        await sourceFile.rename(outputPath);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Video ${saveAsCopy ? 'saved as copy' : 'saved'} successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving video: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _videoPlayerController?.dispose();
    _hourlyTimer?.cancel();
    _recordingTimer?.cancel();
    _clockTimer?.cancel();
    _timeController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return "$hours:$minutes:$seconds";
  }

  Widget _buildTrimControls() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Trim Video',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          RangeSlider(
            values: RangeValues(_trimStart, _trimEnd),
            min: 0,
            max: _videoDuration > 0 ? _videoDuration : 1.0,
            divisions: _videoDuration > 0 ? _videoDuration.toInt() : 10,
            labels: RangeLabels(
              '${_trimStart.toStringAsFixed(1)}s',
              '${_trimEnd.toStringAsFixed(1)}s',
            ),
            onChanged: (values) {
              setState(() {
                _trimStart = values.start;
                _trimEnd = values.end;
                // Update video position while sliding
                if (_videoPlayerController != null) {
                  _videoPlayerController!.seekTo(Duration(milliseconds: (_trimStart * 1000).toInt()));
                }
              });
            },
            onChangeStart: (values) {
              // Pause video when starting to slide
              if (_videoPlayerController != null) {
                _videoPlayerController!.pause();
              }
            },
            onChangeEnd: (values) {
              // Resume video when done sliding
              if (_videoPlayerController != null) {
                _videoPlayerController!.play();
              }
            },
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_trimStart.toStringAsFixed(1)}s',
                style: TextStyle(color: Colors.white),
              ),
              Text(
                '${_trimEnd.toStringAsFixed(1)}s',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _showTrimControls = false;
                    _trimStart = 0;
                    _trimEnd = _videoDuration;
                  });
                },
                child: Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  _showSaveOptions();
                },
                child: Text('Trim'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/camera_loading.png',
                width: 100,
                height: 100,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.camera_alt,
                  size: 80,
                  color: Color(0xFF2F80ED),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Initializing camera...',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              const SizedBox(
                width: 200,
                child: LinearProgressIndicator(
                  backgroundColor: Color(0xFF2A2A2A),
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2F80ED)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          'XoW',
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
                letterSpacing: 2.0,
                fontWeight: FontWeight.w600,
              ),
        ),
        backgroundColor: Colors.black.withOpacity(0.5),
        elevation: 0,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: IconButton(
              icon: const Icon(Icons.folder_outlined),
              color: Colors.white,
              onPressed: () async {
                // Navigate to recorded videos list
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const RecordedVideosList(),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera preview with full screen
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(0),
              child: AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: CameraPreview(_controller!),
              ),
            ),
          ),
          
          // Subtle scanline overlay effect
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(0.5),
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withOpacity(0.5),
                    ],
                    stops: const [0.0, 0.15, 0.85, 1.0],
                  ),
                ),
                child: ShaderMask(
                  shaderCallback: (rect) {
                    return LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black.withOpacity(0.1), Colors.black.withOpacity(0.1)],
                      stops: const [0.5, 0.5],
                      tileMode: TileMode.repeated,
                    ).createShader(rect);
                  },
                  blendMode: BlendMode.dstOut,
                  child: Container(
                    color: Colors.transparent,
                  ),
                ),
              ),
            ),
          ),
                    
          // Grid overlay (rule of thirds)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _isRecording ? Colors.red.withOpacity(0.7) : Colors.transparent,
                    width: 2.0,
                  ),
                ),
                child: CustomPaint(
                  painter: GridPainter(
                    color: Colors.white.withOpacity(0.3),
                  ),
                ),
              ),
            ),
          ),
          
          // Top status bar with timestamp
          Positioned(
            top: 90,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Date and time with modern styling
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white24, width: 1),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.access_time,
                          size: 14,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _currentTime,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            fontFamily: 'monospace',
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  // Camera ID with modern badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white24, width: 1),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isRecording ? Colors.red : const Color(0xFF36B37E),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          '',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            fontFamily: 'monospace',
                            letterSpacing: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Recording duration timer
          if (_isRecording)
            Positioned(
              top: 140,
              left: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatDuration(_recordingDuration),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ),
                    
          // Location badge at bottom
          Positioned(
            bottom: 100,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white24, width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.location_on,
                    size: 16,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _location,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Bottom controls container
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 30),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withOpacity(0.8),
                  ],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!_isRecording)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        shape: BoxShape.circle,
                      ),
                      margin: const EdgeInsets.only(right: 24),
                      child: IconButton(
                        icon: const Icon(Icons.settings_outlined),
                        color: Colors.white,
                        onPressed: () {
                          // Show settings dialog
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: const Color(0xFF1E1E1E),
                              title: Text('Camera Settings', style: Theme.of(context).textTheme.titleLarge),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.location_on_outlined),
                                    title: Text('Location', style: Theme.of(context).textTheme.bodyLarge),
                                    subtitle: Text(_location),
                                    onTap: () {
                                      Navigator.pop(context);
                                      // Show location edit dialog
                                      showDialog(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          backgroundColor: const Color(0xFF1E1E1E),
                                          title: Text('Edit Location', style: Theme.of(context).textTheme.titleLarge),
                                          content: TextField(
                                            decoration: const InputDecoration(
                                              hintText: 'Enter location name',
                                              border: OutlineInputBorder(),
                                            ),
                                            onChanged: (value) {
                                              setState(() {
                                                _location = value.toUpperCase();
                                              });
                                            },
                                            controller: TextEditingController(text: _location),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(context),
                                              child: const Text('Cancel'),
                                            ),
                                            ElevatedButton(
                                              onPressed: () => Navigator.pop(context),
                                              child: const Text('Save'),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                  const Divider(),
                                  ListTile(
                                    leading: const Icon(Icons.camera_alt_outlined),
                                    title: Text('Camera Settings', style: Theme.of(context).textTheme.bodyLarge),
                                    subtitle: const Text('Resolution and quality'),
                                    onTap: () {
                                      // Handle camera settings
                                      Navigator.pop(context);
                                    },
                                  ),
                                ],
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('Close'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  // Record button
                  GestureDetector(
                    onTap: _isRecording ? _stopRecording : _startRecording,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: _isRecording ? 80 : 70,
                      height: _isRecording ? 80 : 70,
                      decoration: BoxDecoration(
                        color: _isRecording ? Colors.red : Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _isRecording 
                                ? Colors.red.withOpacity(0.5) 
                                : Colors.white.withOpacity(0.3),
                            blurRadius: 15,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Center(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: _isRecording ? 30 : 30,
                          height: _isRecording ? 30 : 50,
                          decoration: BoxDecoration(
                            color: _isRecording ? Colors.white : Colors.red,
                            borderRadius: BorderRadius.circular(_isRecording ? 5 : 25),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!_isRecording)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        shape: BoxShape.circle,
                      ),
                      margin: const EdgeInsets.only(left: 24),
                      child: IconButton(
                        icon: const Icon(Icons.photo_library_outlined),
                        color: Colors.white,
                        onPressed: () {
                          // Navigate to recorded videos
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const RecordedVideosList(),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_isSaving)
            const Center(
              child: CircularProgressIndicator(),
            ),

        ],
      ),
    );
  }
}

// Add a custom painter for grid lines (rule of thirds)
class GridPainter extends CustomPainter {
  final Color color;
  
  GridPainter({required this.color});
  
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.8;
    
    // Vertical lines
    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      paint,
    );
    
    canvas.drawLine(
      Offset((size.width / 3) * 2, 0),
      Offset((size.width / 3) * 2, size.height),
      paint,
    );
    
    // Horizontal lines
    canvas.drawLine(
      Offset(0, size.height / 3),
      Offset(size.width, size.height / 3),
      paint,
    );
    
    canvas.drawLine(
      Offset(0, (size.height / 3) * 2),
      Offset(size.width, (size.height / 3) * 2),
      paint,
    );
  }
  
  @override
  bool shouldRepaint(GridPainter oldDelegate) => false;
}

class RecordedVideosList extends StatefulWidget {
  const RecordedVideosList({Key? key}) : super(key: key);

  @override
  State<RecordedVideosList> createState() => _RecordedVideosListState();
}

class _RecordedVideosListState extends State<RecordedVideosList> {
  Map<String, List<FileSystemEntity>> _videosByDate = {};
  String _currentPath = "";
  bool _isLoading = true;
  String _selectedFilter = "All";
  String? _selectedDate;
  String _sortBy = "Date";
  bool _sortAscending = false;
  String _selectedCategory = "All";
  bool _showFolders = true; // New flag to control folder view

  // Sorting options
  final List<String> _sortOptions = [
    "Date",
    "Name",
    "Size",
    "Duration"
  ];

  // Category options
  final List<String> _categoryOptions = [
    "All",
    "Normal",
    "Trimmed"
  ];

  @override
  void initState() {
    super.initState();
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    setState(() => _isLoading = true);
    try {
      Map<String, List<FileSystemEntity>> videosByDate = {};
      
      // First try to find videos in the Downloads directory (for Android)
      if (Platform.isAndroid) {
        try {
          Directory? extDir = await getExternalStorageDirectory();
          if (extDir != null) {
            String androidDownloadsPath = extDir.path.split('/Android')[0] + '/Download';
            Directory downloadsDir = Directory(androidDownloadsPath);
            
            if (await downloadsDir.exists()) {
              final videosDir = Directory('${downloadsDir.path}/XoW_Videos');
              if (await videosDir.exists()) {
                _currentPath = videosDir.path;
                await _processDirectory(videosDir, videosByDate);
              }
            }
          }
        } catch (e) {
          debugPrint('Error checking Downloads directory: $e');
        }
      }
      
      // Also check app-specific storage as fallback
      try {
        Directory? directory = await getExternalStorageDirectory();
        if (directory == null) {
          directory = await getApplicationDocumentsDirectory();
        }
        
        final videosDir = Directory('${directory.path}/XoW_Videos');
        if (videosByDate.isEmpty) {
          _currentPath = videosDir.path;
        }
        
        if (await videosDir.exists()) {
          await _processDirectory(videosDir, videosByDate);
        }
      } catch (e) {
        debugPrint('Error checking app storage: $e');
      }
      
      // Sort videos within each date based on selected criteria
      for (var date in videosByDate.keys) {
        videosByDate[date]!.sort((a, b) {
          switch (_sortBy) {
            case "Date":
              return _sortAscending
                  ? File(a.path).lastModifiedSync().compareTo(File(b.path).lastModifiedSync())
                  : File(b.path).lastModifiedSync().compareTo(File(a.path).lastModifiedSync());
            case "Name":
              return _sortAscending
                  ? path.basename(a.path).compareTo(path.basename(b.path))
                  : path.basename(b.path).compareTo(path.basename(a.path));
            case "Size":
              return _sortAscending
                  ? File(a.path).lengthSync().compareTo(File(b.path).lengthSync())
                  : File(b.path).lengthSync().compareTo(File(a.path).lengthSync());
            case "Duration":
              return _sortAscending
                  ? File(a.path).lastModifiedSync().compareTo(File(b.path).lastModifiedSync())
                  : File(b.path).lastModifiedSync().compareTo(File(a.path).lastModifiedSync());
            default:
              return File(b.path).lastModifiedSync().compareTo(File(a.path).lastModifiedSync());
          }
        });
      }
      
      setState(() {
        _videosByDate = videosByDate;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading videos: $e');
      setState(() => _isLoading = false);
    }
  }

  bool _isTrimmedVideo(String filePath) {
    final fileName = path.basename(filePath).toLowerCase();
    return fileName.contains('trimmed_') || fileName.contains('_trimmed');
  }

  List<FileSystemEntity> _filterVideosByCategory(List<FileSystemEntity> videos) {
    if (_selectedCategory == "All") return videos;
    return videos.where((video) {
      final isTrimmed = _isTrimmedVideo(video.path);
      return (_selectedCategory == "Trimmed" && isTrimmed) ||
             (_selectedCategory == "Normal" && !isTrimmed);
    }).toList();
  }

  Future<void> _processDirectory(Directory dir, Map<String, List<FileSystemEntity>> videosByDate) async {
    final entities = await dir.list(recursive: true).toList();
    
    for (var entity in entities) {
      if (entity is File && entity.path.toLowerCase().endsWith('.mp4')) {
        final date = _getDateFromFile(entity);
        if (!videosByDate.containsKey(date)) {
          videosByDate[date] = [];
        }
        videosByDate[date]!.add(entity);
      }
    }
  }

  String _getDateFromFile(FileSystemEntity file) {
    final date = File(file.path).lastModifiedSync();
    return DateFormat('yyyy-MM-dd').format(date);
  }

  String _formatDate(String dateString) {
    final date = DateTime.parse(dateString);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final videoDate = DateTime(date.year, date.month, date.day);
    
    if (videoDate == today) {
      return 'Today';
    } else if (videoDate == yesterday) {
      return 'Yesterday';
    } else {
      return DateFormat('MMM d, y').format(date);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: Text(
          'Gallery',
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
                letterSpacing: 1.0,
              ),
        ),
        backgroundColor: const Color(0xFF1E1E1E),
        elevation: 0,
        actions: [
          // View toggle button
          IconButton(
            icon: Icon(_showFolders ? Icons.folder : Icons.folder_open),
            onPressed: () {
              setState(() {
                _showFolders = !_showFolders;
              });
            },
            tooltip: _showFolders ? 'Show Videos' : 'Show Folders',
          ),
          // Sort button
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            onSelected: (value) {
              setState(() {
                if (value == "Ascending" || value == "Descending") {
                  _sortAscending = value == "Ascending";
                } else {
                  _sortBy = value;
                }
                _loadVideos();
              });
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem<String>(
                value: "Date",
                child: Text('Sort by Date'),
              ),
              const PopupMenuItem<String>(
                value: "Name",
                child: Text('Sort by Name'),
              ),
              const PopupMenuItem<String>(
                value: "Size",
                child: Text('Sort by Size'),
              ),
              const PopupMenuItem<String>(
                value: "Duration",
                child: Text('Sort by Duration'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: "Ascending",
                child: Text('Ascending Order'),
              ),
              const PopupMenuItem<String>(
                value: "Descending",
                child: Text('Descending Order'),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadVideos,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _videosByDate.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E1E),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(
                          Icons.videocam_off_outlined,
                          size: 60,
                          color: Color(0xFF2F80ED),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'No videos found',
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Looking in: $_currentPath',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontSize: 12,
                            ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _loadVideos,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Date selector and sort info
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        children: [
                          // Category selector
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: _categoryOptions.map((category) => 
                                Padding(
                                  padding: const EdgeInsets.only(right: 8.0),
                                  child: FilterChip(
                                    label: Text(category),
                                    selected: _selectedCategory == category,
                                    showCheckmark: false,
                                    backgroundColor: const Color(0xFF2A2A2A),
                                    selectedColor: const Color(0xFF2F80ED),
                                    onSelected: (selected) {
                                      setState(() {
                                        _selectedCategory = selected ? category : "All";
                                      });
                                    },
                                    labelStyle: TextStyle(
                                      color: _selectedCategory == category ? Colors.white : Colors.white70,
                                      fontWeight: _selectedCategory == category ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              ).toList(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Date selector
                          SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                            child: Row(
                        children: [
                                _buildDateChip('All'),
                                ..._videosByDate.keys.map((date) => _buildDateChip(date)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Sort info
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Sorted by: $_sortBy ${_sortAscending ? '(Ascending)' : '(Descending)'}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                'Total Videos: ${_getTotalVideosCount()}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    
                    // Folders or Videos grid
                    Expanded(
                      child: _showFolders
                          ? ListView.builder(
                              itemCount: _videosByDate.length,
                              itemBuilder: (context, index) {
                                final date = _videosByDate.keys.elementAt(index);
                                final videos = _filterVideosByCategory(_videosByDate[date]!);
                                if (videos.isEmpty) return const SizedBox.shrink();
                                
                                return Card(
                                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  color: const Color(0xFF1E1E1E),
                                  child: ListTile(
                                    leading: Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF2F80ED).withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Icon(
                                        Icons.folder,
                                        color: Color(0xFF2F80ED),
                                      ),
                                    ),
                                    title: Text(
                                      _formatDate(date),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${videos.length} videos',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                      ),
                                    ),
                                    trailing: const Icon(
                                      Icons.chevron_right,
                                      color: Colors.white70,
                                    ),
                                    onTap: () {
                                      setState(() {
                                        _selectedDate = date;
                                        _showFolders = false;
                                      });
                                    },
                                  ),
                                );
                              },
                            )
                          : _selectedDate == null || _selectedDate == 'All'
                              ? ListView.builder(
                                  itemCount: _videosByDate.length,
                                  itemBuilder: (context, index) {
                                    final date = _videosByDate.keys.elementAt(index);
                                    final videos = _filterVideosByCategory(_videosByDate[date]!);
                                    if (videos.isEmpty) return const SizedBox.shrink();
                                    
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(16.0),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            _formatDate(date),
                                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                          ),
                                          Text(
                                            '${videos.length} videos',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    GridView.builder(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 2,
                                        childAspectRatio: 0.8,
                                        crossAxisSpacing: 10,
                                        mainAxisSpacing: 10,
                                      ),
                                      itemCount: videos.length,
                                      itemBuilder: (context, videoIndex) {
                                        return _buildVideoCard(videos[videoIndex]);
                                      },
                                    ),
                                  ],
                                );
                              },
                            )
                          : GridView.builder(
                        padding: const EdgeInsets.all(8.0),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            childAspectRatio: 0.8,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                          ),
                                  itemCount: _filterVideosByCategory(_videosByDate[_selectedDate]!).length,
                          itemBuilder: (context, index) {
                                    final filteredVideos = _filterVideosByCategory(_videosByDate[_selectedDate]!);
                                    return _buildVideoCard(filteredVideos[index]);
                              },
                            ),
                    ),
                  ],
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.pop(context);
        },
        backgroundColor: const Color(0xFF2F80ED),
        child: const Icon(Icons.camera_alt),
      ),
    );
  }

  int _getTotalVideosCount() {
    if (_selectedDate == null || _selectedDate == 'All') {
      return _videosByDate.values.fold(0, (sum, list) => sum + list.length);
    } else {
      return _videosByDate[_selectedDate]?.length ?? 0;
    }
  }
  
  Widget _buildDateChip(String date) {
    final isSelected = _selectedDate == date;
    
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: FilterChip(
        label: Text(date == 'All' ? 'All' : _formatDate(date)),
        selected: isSelected,
        showCheckmark: false,
        backgroundColor: const Color(0xFF2A2A2A),
        selectedColor: const Color(0xFF2F80ED),
        onSelected: (selected) {
          setState(() {
            _selectedDate = selected ? date : null;
          });
        },
        labelStyle: TextStyle(
          color: isSelected ? Colors.white : Colors.white70,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
      ),
    );
  }

  Widget _buildVideoCard(FileSystemEntity video) {
                            final fileName = path.basename(video.path);
                            final fileSize = File(video.path).lengthSync();
                            final fileSizeInMb = (fileSize / (1024 * 1024)).toStringAsFixed(2);
                            final lastModified = File(video.path).lastModifiedSync();
                            
                            return GestureDetector(
                              onTap: () => _playVideo(video.path),
                              child: Card(
                                elevation: 4,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                color: const Color(0xFF1E1E1E),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Stack(
                                      children: [
                                        ClipRRect(
                                          borderRadius: const BorderRadius.only(
                                            topLeft: Radius.circular(12),
                                            topRight: Radius.circular(12),
                                          ),
                                          child: Container(
                                            height: 120,
                                            width: double.infinity,
                                            color: Colors.black,
                                            child: const Icon(
                                              Icons.video_file,
                                              size: 50,
                                              color: Colors.white54,
                                            ),
                                          ),
                                        ),
                                        Positioned.fill(
                                          child: Center(
                                            child: Container(
                                              width: 40,
                                              height: 40,
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF2F80ED),
                                                shape: BoxShape.circle,
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.black.withOpacity(0.3),
                                                    blurRadius: 8,
                                                    offset: const Offset(0, 2),
                                                  ),
                                                ],
                                              ),
                                              child: const Icon(
                                                Icons.play_arrow,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          top: 8,
                                          right: 8,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withOpacity(0.7),
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              '$fileSizeInMb MB',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.all(12.0),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            fileName.length > 20 
                                                ? '${fileName.substring(0, 20)}...'
                                                : fileName,
                                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
                                                ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                    DateFormat('HH:mm:ss').format(lastModified),
                                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                  fontSize: 11,
                                                ),
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.end,
                                            children: [
                                              Material(
                                                color: Colors.transparent,
                                                child: InkWell(
                                                  onTap: () => _deleteVideo(video.path),
                                                  borderRadius: BorderRadius.circular(4),
                                                  child: const Padding(
                                                    padding: EdgeInsets.all(4.0),
                                                    child: Icon(
                                                      Icons.delete_outline,
                                                      size: 20,
                                                      color: Colors.white70,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
  }

  Future<void> _playVideo(String videoPath) async {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoPlayerScreen(videoPath: videoPath),
      ),
    );
  }

  Future<void> _deleteVideo(String videoPath) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text('Delete Video', style: Theme.of(context).textTheme.titleLarge),
        content: Text(
          'Are you sure you want to delete this video?',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
          Navigator.pop(context);
              // Show loading indicator
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Deleting video...'),
                  duration: Duration(seconds: 1),
                ),
              );
              
              try {
                final file = File(videoPath);
                await file.delete();
                _loadVideos();
                
                // Show success message
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Video deleted successfully'),
                      backgroundColor: Color(0xFF36B37E),
                    ),
                  );
                }
              } catch (e) {
                debugPrint('Error deleting video: $e');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error deleting video: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class VideoPlayerScreen extends StatefulWidget {
  final String videoPath;

  const VideoPlayerScreen({Key? key, required this.videoPath}) : super(key: key);

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _videoPlayerController;
  bool _isInitialized = false;
  bool _isPlaying = false;
  double _volume = 1.0;
  Timer? _hideControlsTimer;
  bool _showControls = true;
  double _startTrim = 0.0;
  double _endTrim = 1.0;
  bool _isTrimming = false;
  bool _isProcessing = false;
  double _videoDuration = 0.0;
  TextEditingController _timeController = TextEditingController();
  bool _isFullScreen = false;
  bool _showTrimControls = false;
  bool _showJumpToTime = false;
  double _trimStart = 0.0;
  double _trimEnd = 1.0;

  Future<int> _getVideoDuration(File videoFile) async {
    try {
      final result = await FFmpegKit.execute(
        '-i ${videoFile.path} -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1'
      );
      final returnCode = await result.getReturnCode();
      if (ReturnCode.isSuccess(returnCode)) {
        final output = await result.getOutput();
        return double.parse(output ?? '0').round();
      }
      throw Exception('Failed to get video duration');
    } catch (e) {
      debugPrint('Error getting video duration: $e');
      return 0;
    }
  }

  @override
  void initState() {
    super.initState();
    _initializeVideoPlayer();
  }
  
  Future<void> _initializeVideoPlayer() async {
    try {
      _videoPlayerController = VideoPlayerController.file(File(widget.videoPath));
      await _videoPlayerController.initialize();
      
      // Get video duration
      final duration = await _getVideoDuration(File(widget.videoPath));
      
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _videoDuration = duration.toDouble();
          // Initialize trim values to full video length
          _trimStart = 0.0;
          _trimEnd = _videoDuration;
          _startTrim = 0.0;
          _endTrim = 1.0;
          _videoPlayerController.play();
          _isPlaying = true;
          _startHideControlsTimer();
        });
      }
      
      _videoPlayerController.addListener(_videoListener);
    } catch (e) {
      debugPrint('Error initializing video player: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading video: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _videoListener() {
    if (_videoPlayerController.value.isPlaying != _isPlaying) {
            setState(() {
        _isPlaying = _videoPlayerController.value.isPlaying;
            });
          }
  }

  void _togglePlayPause() {
    if (!_isInitialized) return;
    
    setState(() {
      if (_videoPlayerController.value.isPlaying) {
        _videoPlayerController.pause();
      } else {
        _videoPlayerController.play();
        _startHideControlsTimer();
      }
      _isPlaying = !_isPlaying;
    });
  }
  
  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isPlaying) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }
  
  void _showControlsTemporarily() {
    setState(() {
      _showControls = true;
    });
    _startHideControlsTimer();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return duration.inHours > 0 ? "$hours:$minutes:$seconds" : "$minutes:$seconds";
  }

  Future<void> _jumpToTime(String? timeString) async {
    if (!_isInitialized || timeString == null || timeString.isEmpty) return;

    try {
      // Parse the time string (hh:mm:ss a format)
      final timeParts = timeString.split(':');
      if (timeParts.length != 3) {
        throw Exception('Invalid time format');
      }

      // Get hours, minutes, seconds and AM/PM
      final hours = int.parse(timeParts[0]);
      final minutes = int.parse(timeParts[1]);
      final secondsAndPeriod = timeParts[2].split(' ');
      final seconds = int.parse(secondsAndPeriod[0]);
      final isPM = secondsAndPeriod[1].toUpperCase() == 'PM';

      // Get the video file's creation time
      final videoFile = File(widget.videoPath);
      final creationTime = videoFile.lastModifiedSync();
      
      // Parse the creation time
      final creationHours = creationTime.hour;
      final creationMinutes = creationTime.minute;
      final creationSeconds = creationTime.second;
      
      // Calculate total seconds for selected time
      int selectedTotalSeconds = seconds + (minutes * 60) + (hours * 3600);
      if (isPM && hours != 12) selectedTotalSeconds += 12 * 3600;
      if (!isPM && hours == 12) selectedTotalSeconds -= 12 * 3600;
      
      // Calculate total seconds for creation time
      int creationTotalSeconds = creationSeconds + (creationMinutes * 60) + (creationHours * 3600);
      
      // Calculate the difference in seconds
      int totalSeconds = selectedTotalSeconds - creationTotalSeconds;
      
      // If the difference is negative, it means we're trying to jump to a time before the video started
      // In this case, we should just use the seconds part of the selected time
      if (totalSeconds < 0) {
        totalSeconds = seconds + (minutes * 60);
      }

      final videoDuration = _videoPlayerController.value.duration.inSeconds;
      
      debugPrint('Selected time: $timeString');
      debugPrint('Total seconds: $totalSeconds');
      debugPrint('Video duration: $videoDuration');
      
      // Validate that the target time is within the video duration
      if (totalSeconds >= 0 && totalSeconds <= videoDuration) {
        // Seek to the position
        await _videoPlayerController.seekTo(Duration(seconds: totalSeconds));
        
      if (!_isPlaying) {
          await _videoPlayerController.play();
        setState(() {
          _isPlaying = true;
        });
      }
        
      setState(() {
        _showJumpToTime = false;
      });
      } else {
        throw Exception('Selected time is not within video duration');
      }
    } catch (e) {
      debugPrint('Error jumping to time: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _performTrim(bool replaceOriginal) async {
    if (_isProcessing || !_isInitialized || _videoPlayerController == null) return;
    
    setState(() {
      _isProcessing = true;
    });

    try {
      final duration = _videoPlayerController!.value.duration;
      final startTime = duration * _trimStart;
      final endTime = duration * _trimEnd;
      
      if (startTime >= endTime) {
        throw Exception('Invalid trim range: Start time must be before end time');
      }
      
      final directory = path.dirname(widget.videoPath);
      final filename = path.basename(widget.videoPath);
      final timestamp = DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now());
      final outputPath = replaceOriginal 
          ? widget.videoPath 
          : '$directory/trimmed_$timestamp$filename';

      // Show processing indicator
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Processing video...'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      // First try with copy codec
      String ffmpegCommand = '-y -i "${widget.videoPath}" '
          '-ss ${startTime.inSeconds} -t ${(endTime - startTime).inSeconds} '
          '-c:v copy -c:a copy '
          '"$outputPath"';

      debugPrint('Running FFmpeg command: $ffmpegCommand');
      
      final session = await FFmpegKit.execute(ffmpegCommand);
      final returnCode = await session.getReturnCode();
      final logs = await session.getOutput();
      
      debugPrint('FFmpeg logs: $logs');
      
      if (!ReturnCode.isSuccess(returnCode)) {
        // If copy codec fails, try with re-encoding
        debugPrint('Copy codec failed, trying with re-encoding...');
        ffmpegCommand = '-y -i "${widget.videoPath}" '
            '-ss ${startTime.inSeconds} -t ${(endTime - startTime).inSeconds} '
            '-c:v libx264 -preset ultrafast -c:a aac '
            '"$outputPath"';
            
        final reencodeSession = await FFmpegKit.execute(ffmpegCommand);
        final reencodeReturnCode = await reencodeSession.getReturnCode();
        final reencodeLogs = await reencodeSession.getOutput();
        
        debugPrint('Re-encode FFmpeg logs: $reencodeLogs');
        
        if (!ReturnCode.isSuccess(reencodeReturnCode)) {
          throw Exception('Failed to trim video: $reencodeLogs');
        }
      }

      // Verify the trimmed file exists and has content
      final trimmedFile = File(outputPath);
      if (!await trimmedFile.exists()) {
        throw Exception('Trimmed file was not created');
      }
      
      final fileSize = await trimmedFile.length();
      if (fileSize == 0) {
        throw Exception('Trimmed file is empty');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(replaceOriginal 
                ? 'Video trimmed successfully' 
                : 'Trimmed video saved as copy'),
            backgroundColor: Colors.green,
          ),
        );
      }
      
      if (!replaceOriginal) {
        Navigator.pop(context);
      } else {
        // Reload the video if we replaced the original
        await _videoPlayerController!.dispose();
        _videoPlayerController = VideoPlayerController.file(File(outputPath));
        await _videoPlayerController.initialize();
        if (mounted) {
          setState(() {
            _isInitialized = true;
            _videoPlayerController.play();
            _isPlaying = true;
          });
        }
      }
    } catch (e) {
      debugPrint('Error trimming video: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error trimming video: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isProcessing = false;
        _isTrimming = false;
        _showTrimControls = false;
      });
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _videoPlayerController.removeListener(_videoListener);
    _videoPlayerController.dispose();
    _timeController.dispose();
    super.dispose();
  }

  Widget _buildTrimControls() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Trim Video',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          RangeSlider(
            values: RangeValues(_trimStart, _trimEnd),
            min: 0,
            max: _videoDuration > 0 ? _videoDuration : 1.0,
            divisions: _videoDuration > 0 ? _videoDuration.toInt() : 10,
            labels: RangeLabels(
              '${_trimStart.toStringAsFixed(1)}s',
              '${_trimEnd.toStringAsFixed(1)}s',
            ),
            onChanged: (values) {
              setState(() {
                _trimStart = values.start;
                _trimEnd = values.end;
                // Update video position while sliding
                if (_videoPlayerController != null) {
                  _videoPlayerController!.seekTo(Duration(milliseconds: (_trimStart * 1000).toInt()));
                }
              });
            },
            onChangeStart: (values) {
              // Pause video when starting to slide
              if (_videoPlayerController != null) {
                _videoPlayerController!.pause();
              }
            },
            onChangeEnd: (values) {
              // Resume video when done sliding
              if (_videoPlayerController != null) {
                _videoPlayerController!.play();
              }
            },
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_trimStart.toStringAsFixed(1)}s',
                style: TextStyle(color: Colors.white),
              ),
              Text(
                '${_trimEnd.toStringAsFixed(1)}s',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _showTrimControls = false;
                    _trimStart = 0;
                    _trimEnd = _videoDuration;
                  });
                },
                child: Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  _showSaveOptions();
                },
                child: Text('Trim'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showSaveOptions() async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Options'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.save),
              title: const Text('Save'),
              onTap: () {
                Navigator.pop(context);
                _trimAndSave(false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Save as Copy'),
              onTap: () {
                Navigator.pop(context);
                _trimAndSave(true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _trimAndSave(bool saveAsCopy) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      final duration = _videoPlayerController.value.duration;
      final startTime = duration * _trimStart;
      final endTime = duration * _trimEnd;
      
      if (startTime >= endTime) {
        throw Exception('Invalid trim range: Start time must be before end time');
      }
      
      final directory = path.dirname(widget.videoPath);
      final filename = path.basename(widget.videoPath);
      final timestamp = DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now());
      
      // Create a temporary file for the trimmed video
      final tempPath = '$directory/temp_trimmed_$timestamp$filename';
      final outputPath = saveAsCopy 
          ? '$directory/trimmed_$timestamp$filename'
          : widget.videoPath;

      // Show processing indicator
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Processing video...'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      // First try with copy codec
      String ffmpegCommand = '-y -i "${widget.videoPath}" '
          '-ss ${startTime.inSeconds} -t ${(endTime - startTime).inSeconds} '
          '-c:v copy -c:a copy '
          '"$tempPath"';

      debugPrint('Running FFmpeg command: $ffmpegCommand');
      
      final session = await FFmpegKit.execute(ffmpegCommand);
      final returnCode = await session.getReturnCode();
      final logs = await session.getOutput();
      
      debugPrint('FFmpeg logs: $logs');
      
      if (!ReturnCode.isSuccess(returnCode)) {
        // If copy codec fails, try with re-encoding
        debugPrint('Copy codec failed, trying with re-encoding...');
        ffmpegCommand = '-y -i "${widget.videoPath}" '
            '-ss ${startTime.inSeconds} -t ${(endTime - startTime).inSeconds} '
            '-c:v libx264 -preset ultrafast -c:a aac '
            '"$tempPath"';
            
        final reencodeSession = await FFmpegKit.execute(ffmpegCommand);
        final reencodeReturnCode = await reencodeSession.getReturnCode();
        final reencodeLogs = await reencodeSession.getOutput();
        
        debugPrint('Re-encode FFmpeg logs: $reencodeLogs');
        
        if (!ReturnCode.isSuccess(reencodeReturnCode)) {
          throw Exception('Failed to trim video: $reencodeLogs');
        }
      }

      // Verify the trimmed file exists and has content
      final tempFile = File(tempPath);
      if (!await tempFile.exists()) {
        throw Exception('Trimmed file was not created');
      }
      
      final fileSize = await tempFile.length();
      if (fileSize == 0) {
        throw Exception('Trimmed file is empty');
      }

      // Handle the final file operations
      if (saveAsCopy) {
        // For save as copy, just rename the temp file to the final name
        await tempFile.rename(outputPath);
      } else {
        // For save (overwrite), we need to:
        // 1. Delete the original file
        // 2. Rename the temp file to the original name
        final originalFile = File(widget.videoPath);
        if (await originalFile.exists()) {
          await originalFile.delete();
        }
        await tempFile.rename(outputPath);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(saveAsCopy 
                ? 'Trimmed video saved as copy' 
                : 'Video trimmed successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
      
      if (saveAsCopy) {
        Navigator.pop(context);
      } else {
        // Reload the video if we replaced the original
        await _videoPlayerController.dispose();
        _videoPlayerController = VideoPlayerController.file(File(outputPath));
        await _videoPlayerController.initialize();
        if (mounted) {
          setState(() {
            _isInitialized = true;
            _videoPlayerController.play();
            _isPlaying = true;
            _showTrimControls = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error trimming video: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error trimming video: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isProcessing = false;
        _isTrimming = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _isFullScreen ? null : AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          path.basename(widget.videoPath),
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.content_cut),
            onPressed: () {
              setState(() {
                _showTrimControls = true;
              });
            },
            tooltip: 'Trim Video',
          ),
          IconButton(
            icon: const Icon(Icons.access_time),
            onPressed: () {
              setState(() {
                _showJumpToTime = true;
                _showTrimControls = false;
              });
            },
            tooltip: 'Jump to Time',
          ),
          IconButton(
            icon: const Icon(Icons.fullscreen),
            onPressed: () {
              setState(() {
                _isFullScreen = !_isFullScreen;
              });
            },
            tooltip: 'Toggle Fullscreen',
          ),
        ],
      ),
      body: _isInitialized
          ? Stack(
                children: [
                  // Video player with watermark
                GestureDetector(
                  onTap: _showControlsTemporarily,
                  child: Center(
                    child: AspectRatio(
                        aspectRatio: _videoPlayerController.value.aspectRatio,
                        child: VideoWatermarkOverlay(
                          location: "MAIN ENTRANCE",
                          initialTime: File(widget.videoPath).lastModifiedSync(),
                          controller: _videoPlayerController,
                          showFrame: true,
                          timestampStyle: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            shadows: [
                              Shadow(
                                blurRadius: 2.0,
                                color: Colors.black,
                                offset: Offset(1.0, 1.0),
                              ),
                            ],
                          ),
                          locationStyle: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            shadows: [
                              Shadow(
                                blurRadius: 2.0,
                                color: Colors.black,
                                offset: Offset(1.0, 1.0),
                              ),
                            ],
                          ),
                          frameColor: Colors.white.withOpacity(0.7),
                          frameWidth: 2.0,
                          child: VideoPlayer(_videoPlayerController),
                        ),
                      ),
                    ),
                  ),
                  
                  // Overlay controls (conditionally visible)
                  if (_showControls)
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withOpacity(0.0),
                            Colors.black.withOpacity(0.5),
                          ],
                          stops: const [0.7, 1.0],
                        ),
                      ),
                    ),
                    
                  // Play/Pause button (always visible on tap)
                  if (_showControls)
                  Center(
                    child: IconButton(
                      icon: Icon(
                        _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                        size: 60,
                        color: Colors.white,
                      ),
                      onPressed: _togglePlayPause,
                    ),
                    ),
                  
                  // Bottom controls
                  if (_showControls)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.7),
                          ],
                        ),
                      ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Progress bar
                            VideoProgressIndicator(
                            _videoPlayerController,
                              allowScrubbing: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                              colors: VideoProgressColors(
                                playedColor: const Color(0xFF2F80ED),
                                bufferedColor: Colors.white.withOpacity(0.2),
                                backgroundColor: Colors.white.withOpacity(0.1),
                              ),
                            ),
                          
                          const SizedBox(height: 8),
                            
                            // Time and controls row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // Current position / total duration
                                Text(
                                '${_formatDuration(_videoPlayerController.value.position)} / ${_formatDuration(_videoPlayerController.value.duration)}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                                
                                // Control buttons
                                Row(
                                mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Rewind 10s
                                    IconButton(
                                      icon: const Icon(Icons.replay_10, color: Colors.white),
                                      onPressed: () {
                                      final newPosition = _videoPlayerController.value.position - const Duration(seconds: 10);
                                      _videoPlayerController.seekTo(newPosition);
                                      },
                                    ),
                                    
                                    // Play/Pause
                                    IconButton(
                                      icon: Icon(
                                        _isPlaying ? Icons.pause : Icons.play_arrow,
                                        color: Colors.white,
                                      ),
                                      onPressed: _togglePlayPause,
                                    ),
                                    
                                    // Forward 10s
                                    IconButton(
                                      icon: const Icon(Icons.forward_10, color: Colors.white),
                                      onPressed: () {
                                      final newPosition = _videoPlayerController.value.position + const Duration(seconds: 10);
                                      _videoPlayerController.seekTo(newPosition);
                                      },
                                    ),
                                  ],
                                ),
                                
                                // Volume button
                                IconButton(
                                  icon: Icon(
                                    _volume > 0 ? Icons.volume_up : Icons.volume_off,
                                    color: Colors.white,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _volume = _volume > 0 ? 0 : 1.0;
                                    _videoPlayerController.setVolume(_volume);
                                    });
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ),

                // Trim controls
                if (_showTrimControls)
                  Positioned(
                    bottom: 100,
                    left: 0,
                    right: 0,
                    child: _buildTrimControls(),
                  ),

                // Processing indicator
                if (_isProcessing)
                  const Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2F80ED)),
                    ),
                  ),

                // Jump to time input
                if (_showJumpToTime)
                  Positioned(
                    bottom: 100,
                    left: 0,
                    right: 0,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20),
                      padding: const EdgeInsets.all(16),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width - 40,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Jump to Time',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          
                          // Time scroller
                          Container(
                            height: 100,
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: ListWheelScrollView(
                              controller: FixedExtentScrollController(
                                initialItem: _videoPlayerController.value.position.inSeconds,
                              ),
                              itemExtent: 40,
                              physics: const FixedExtentScrollPhysics(),
                              children: List.generate(
                                _videoPlayerController.value.duration.inSeconds + 1,
                                (index) {
                                  // Get the video file's creation time
                                  final videoFile = File(widget.videoPath);
                                  final creationTime = videoFile.lastModifiedSync();
                                  
                                  // Calculate the timestamp for this index
                                  final timestamp = creationTime.add(Duration(seconds: index));
                                  
                                  // Format the time with AM/PM for display
                                  final timeString = DateFormat('hh:mm:ss a').format(timestamp);
                                  
                                  return Center(
                                    child: Text(
                                      timeString,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  );
                                },
                              ),
                              onSelectedItemChanged: (index) {
                                // Get the video file's creation time
                                final videoFile = File(widget.videoPath);
                                final creationTime = videoFile.lastModifiedSync();
                                
                                // Calculate the timestamp for this index
                                final timestamp = creationTime.add(Duration(seconds: index));
                                  
                                // Format the time with AM/PM for display
                                final timeString = DateFormat('hh:mm:ss a').format(timestamp);
                                
                                debugPrint('Selected index: $index');
                                debugPrint('Selected time: $timeString');
                                
                                _timeController.text = timeString;
                              },
                            ),
                          ),
                          
                          const SizedBox(height: 16),
                          
                          // Selected time display
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Selected Time: ${_timeController.text}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          
                          const SizedBox(height: 16),
                          
                          // Action buttons
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _showJumpToTime = false;
                                  });
                                },
                                child: const Text('Cancel'),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _isProcessing ? null : () {
                                  final timeText = _timeController.text;
                                  if (timeText.isNotEmpty) {
                                    _jumpToTime(timeText);
                                  }
                                },
                                child: const Text('Jump'),
                    ),
                ],
              ),
                        ],
                      ),
                    ),
                  ),
              ],
            )
          : const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2F80ED)),
              ),
            ),
    );
  }
} 