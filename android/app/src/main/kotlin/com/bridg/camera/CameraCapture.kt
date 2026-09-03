package com.bridg.camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * Captures frames from the device camera using Camera2 API.
 * Encodes frames as H.264 NAL units for the virtual webcam pipeline.
 *
 * This shares the video encoding pipeline with ScreenCapture.
 */
class CameraCapture(private val context: Context) {

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null

    private val cameraOpenLock = Semaphore(1)
    private var isCapturing = false
    private var frameCallback: FrameCallback? = null

    private var targetWidth = DEFAULT_WIDTH
    private var targetHeight = DEFAULT_HEIGHT

    /**
     * Open the camera and start capturing frames.
     */
    @SuppressLint("MissingPermission")
    fun startCapture(callback: FrameCallback) {
        if (isCapturing) return
        frameCallback = callback

        cameraThread = HandlerThread("CameraCapture").apply { start() }
        cameraHandler = Handler(cameraThread!!.looper)

        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

        try {
            // Use the back camera by default
            val cameraId = findCamera(manager) ?: run {
                Log.e(TAG, "No suitable camera found")
                return
            }

            if (!cameraOpenLock.tryAcquire(2500, TimeUnit.MILLISECONDS)) {
                throw RuntimeException("Camera open timeout")
            }

            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraOpenLock.release()
                    cameraDevice = camera
                    createCaptureSession(camera)
                    isCapturing = true
                    Log.i(TAG, "Camera opened: $cameraId")
                }

                override fun onDisconnected(camera: CameraDevice) {
                    cameraOpenLock.release()
                    camera.close()
                    cameraDevice = null
                    isCapturing = false
                    Log.w(TAG, "Camera disconnected")
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    cameraOpenLock.release()
                    camera.close()
                    cameraDevice = null
                    isCapturing = false
                    Log.e(TAG, "Camera error: $error")
                }
            }, cameraHandler)
        } catch (e: CameraAccessException) {
            Log.e(TAG, "Camera access error: ${e.message}")
        }
    }

    /**
     * Stop camera capture and release resources.
     */
    fun stopCapture() {
        if (!isCapturing) return
        isCapturing = false

        try {
            captureSession?.close()
            captureSession = null
        } catch (e: Exception) {
            Log.w(TAG, "Error closing capture session: ${e.message}")
        }

        try {
            cameraDevice?.close()
            cameraDevice = null
        } catch (e: Exception) {
            Log.w(TAG, "Error closing camera: ${e.message}")
        }

        imageReader?.close()
        imageReader = null

        cameraThread?.quitSafely()
        cameraThread = null
        cameraHandler = null
        frameCallback = null

        Log.i(TAG, "Camera capture stopped")
    }

    private fun findCamera(manager: CameraManager): String? {
        for (id in manager.cameraIdList) {
            val characteristics = manager.getCameraCharacteristics(id)
            val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
            if (facing == CameraCharacteristics.LENS_FACING_BACK) {
                val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                val sizes = map?.getOutputSizes(ImageFormat.YUV_420_888)
                // Find a size close to our target
                val bestSize = sizes?.minByOrNull {
                    Math.abs(it.width - targetWidth) + Math.abs(it.height - targetHeight)
                }
                if (bestSize != null) {
                    targetWidth = bestSize.width
                    targetHeight = bestSize.height
                }
                return id
            }
        }
        return manager.cameraIdList.firstOrNull()
    }

    private fun createCaptureSession(camera: CameraDevice) {
        imageReader = ImageReader.newInstance(
            targetWidth, targetHeight,
            ImageFormat.YUV_420_888,
            2 // maxImages
        ).apply {
            setOnImageAvailableListener({ reader ->
                val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    // Convert YUV to NV12 for encoding
                    val nv12 = yuvToNv12(image)
                    frameCallback?.onCameraFrame(nv12, targetWidth, targetHeight)
                } finally {
                    image.close()
                }
            }, cameraHandler)
        }

        val surface = imageReader!!.surface

        try {
            camera.createCaptureSession(
                listOf(surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        startRepeatingRequest(camera, session, surface)
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e(TAG, "Capture session config failed")
                    }
                },
                cameraHandler
            )
        } catch (e: CameraAccessException) {
            Log.e(TAG, "Error creating capture session: ${e.message}")
        }
    }

    private fun startRepeatingRequest(
        camera: CameraDevice,
        session: CameraCaptureSession,
        surface: android.view.Surface
    ) {
        try {
            val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                addTarget(surface)
                set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            }

            session.setRepeatingRequest(request.build(), null, cameraHandler)
        } catch (e: CameraAccessException) {
            Log.e(TAG, "Error starting repeating request: ${e.message}")
        }
    }

    /**
     * Convert YUV_420_888 Image to NV12 byte array for H.264 encoding.
     */
    private fun yuvToNv12(image: android.media.Image): ByteArray {
        val width = image.width
        val height = image.height
        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]

        val yBuffer = yPlane.buffer
        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer

        val nv12 = ByteArray(width * height * 3 / 2)

        // Copy Y plane
        val yRowStride = yPlane.rowStride
        val yPixelStride = yPlane.pixelStride
        var pos = 0
        for (row in 0 until height) {
            for (col in 0 until width) {
                nv12[pos++] = yBuffer.get(row * yRowStride + col * yPixelStride)
            }
        }

        // Interleave U and V planes
        val uvRowStride = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride
        for (row in 0 until height / 2) {
            for (col in 0 until width / 2) {
                nv12[pos++] = uBuffer.get(row * uvRowStride + col * uvPixelStride)
                nv12[pos++] = vBuffer.get(row * uvRowStride + col * uvPixelStride)
            }
        }

        return nv12
    }

    interface FrameCallback {
        fun onCameraFrame(frameData: ByteArray, width: Int, height: Int)
    }

    companion object {
        private const val TAG = "CameraCapture"
        private const val DEFAULT_WIDTH = 1280
        private const val DEFAULT_HEIGHT = 720
    }
}
