package com.example.onelasttry

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.Executors
import kotlin.concurrent.thread

class ScreenRecorderPlugin: FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.ActivityResultListener {
    private lateinit var channel : MethodChannel
    private var activity: Activity? = null
    private var mediaRecorder: MediaRecorder? = null
    private var outputFile: String? = null
    private var isRecording = false
    private val handler = Handler(Looper.getMainLooper())
    private var mediaProjectionManager: MediaProjectionManager? = null
    private var pendingResult: Result? = null
    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var screenWidth = 0
    private var screenHeight = 0
    private var screenDensity = 0
    private val executor = Executors.newSingleThreadExecutor()

    companion object {
        private const val SCREEN_CAPTURE_REQUEST_CODE = 1001
        private const val TAG = "ScreenRecorderPlugin"
    }

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "screen_recorder")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {
            "startRecording" -> {
                val path = call.argument<String>("path")
                if (path != null) {
                    startRecording(path, result)
                } else {
                    result.error("INVALID_ARGUMENT", "Path cannot be null", null)
                }
            }
            "stopRecording" -> {
                stopRecording(result)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun startRecording(path: String, result: Result) {
        executor.execute {
            try {
                if (isRecording) {
                    handler.post { result.error("ALREADY_RECORDING", "Recording is already in progress", null) }
                    return@execute
                }

                if (activity == null) {
                    handler.post { result.error("NO_ACTIVITY", "Activity is not available", null) }
                    return@execute
                }

                // Get screen dimensions on main thread
                handler.post {
                    val metrics = DisplayMetrics()
                    activity?.windowManager?.defaultDisplay?.getMetrics(metrics)
                    screenWidth = metrics.widthPixels
                    screenHeight = metrics.heightPixels
                    screenDensity = metrics.densityDpi

                    Log.d(TAG, "Screen dimensions: ${screenWidth}x${screenHeight}, density: $screenDensity")

                    // Initialize MediaProjectionManager
                    mediaProjectionManager = activity?.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                    
                    // Request screen capture permission
                    val intent = mediaProjectionManager?.createScreenCaptureIntent()
                    if (intent != null) {
                        pendingResult = result
                        outputFile = path
                        activity?.startActivityForResult(intent, SCREEN_CAPTURE_REQUEST_CODE)
                    } else {
                        result.error("SCREEN_CAPTURE_ERROR", "Failed to create screen capture intent", null)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error starting recording", e)
                handler.post {
                    cleanup()
                    result.error("RECORDING_ERROR", e.message, null)
                }
            }
        }
    }

    private fun startScreenRecording(data: Intent?) {
        try {
            if (data == null) {
                pendingResult?.error("RECORDING_ERROR", "No permission data received", null)
                cleanup()
                return
            }

            val filePath = outputFile ?: ""
            if (!ensureStorageAccess(filePath)) {
                pendingResult?.error("STORAGE_ERROR", "Failed to access storage", null)
                cleanup()
                return
            }

            mediaProjection = mediaProjectionManager?.getMediaProjection(Activity.RESULT_OK, data)
            if (mediaProjection == null) {
                pendingResult?.error("RECORDING_ERROR", "Failed to get media projection", null)
                cleanup()
                return
            }

            mediaRecorder = MediaRecorder().apply {
                setVideoSource(MediaRecorder.VideoSource.SURFACE)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                setVideoEncodingBitRate(12 * 1024 * 1024)
                setVideoFrameRate(30)
                setOutputFile(filePath)
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioEncodingBitRate(128000)
                setAudioSamplingRate(44100)
                try {
                    prepare()
                } catch (e: IOException) {
                    pendingResult?.error("RECORDING_ERROR", "Failed to prepare MediaRecorder: ${e.message}", null)
                    cleanup()
                    return
                }
            }

            virtualDisplay = mediaProjection?.createVirtualDisplay(
                "ScreenRecording",
                screenWidth, screenHeight, screenDensity,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR or DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC,
                mediaRecorder?.surface, null, null
            )

            mediaRecorder?.start()
            isRecording = true
            pendingResult?.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "Error starting screen recording", e)
            pendingResult?.error("RECORDING_ERROR", "Failed to start recording: ${e.message}", null)
            cleanup()
        }
    }

    private fun stopRecording(result: Result) {
        if (!isRecording) {
            result.error("NOT_RECORDING", "No recording in progress", null)
            return
        }

        executor.execute {
            try {
                Log.d(TAG, "Stopping screen recording...")
                
                // First stop the virtual display
                virtualDisplay?.release()
                virtualDisplay = null
                
                // Then stop the media recorder
                mediaRecorder?.apply {
                    try {
                        stop()
                        Log.d(TAG, "MediaRecorder stopped successfully")
                    } catch (e: Exception) {
                        Log.e(TAG, "Error stopping MediaRecorder", e)
                        try {
                            release()
                        } catch (e2: Exception) {
                            Log.e(TAG, "Error releasing MediaRecorder", e2)
                        }
                        throw e
                    }
                    release()
                }
                
                // Stop the media projection
                mediaProjection?.stop()
                mediaProjection = null
                
                // Verify the file exists and has content
                val file = File(outputFile)
                if (!file.exists() || file.length() == 0L) {
                    throw Exception("Recorded file is empty or does not exist")
                }
                
                Log.d(TAG, "Screen recording stopped successfully")
                handler.post {
                    cleanup()
                    result.success(outputFile)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error in stopRecording thread", e)
                handler.post {
                    cleanup()
                    result.error("STOP_ERROR", e.message, null)
                }
            }
        }
    }

    private fun cleanup() {
        try {
            virtualDisplay?.release()
            virtualDisplay = null
            mediaProjection?.stop()
            mediaProjection = null
            mediaRecorder?.apply {
                try {
                    stop()
                } catch (e: Exception) {
                    Log.w(TAG, "Error stopping mediaRecorder", e)
                }
                reset()
                release()
            }
            mediaRecorder = null
            pendingResult = null
        } catch (e: Exception) {
            Log.e(TAG, "Error during cleanup", e)
        }
    }

    private fun ensureStorageAccess(path: String): Boolean {
        try {
            val file = File(path)
            file.parentFile?.mkdirs()
            if (!file.exists()) {
                file.createNewFile()
            }
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Error ensuring storage access", e)
            return false
        }
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        cleanup()
        executor.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
        cleanup()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == SCREEN_CAPTURE_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                startScreenRecording(data)
            } else {
                pendingResult?.error("PERMISSION_DENIED", "Screen capture permission denied", null)
            }
            pendingResult = null
            return true
        }
        return false
    }
} 