package com.bridg.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Base64
import android.util.Log
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import com.bridg.databinding.ActivityPairingBinding
import com.bridg.pairing.KeyManager
import com.bridg.pairing.PairingManager
import com.bridg.service.BridgService
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Scans the QR code displayed by the Mac and hands the result to BridgService.
 *
 * This screen previously only drew the pairing payload on a bitmap as plain
 * text, which no scanner could ever read, and the camera path was a stub.
 */
class PairingActivity : AppCompatActivity() {

    private lateinit var binding: ActivityPairingBinding
    private lateinit var pairingManager: PairingManager
    private lateinit var cameraExecutor: ExecutorService

    private val scanner = BarcodeScanning.getClient(
        BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
    )

    /** One successful scan finishes the screen; ignore frames still in flight. */
    @Volatile private var handled = false

    private val requestCamera = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) startCamera()
        else {
            binding.statusText.text = "Camera permission is required to scan the QR code"
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityPairingBinding.inflate(layoutInflater)
        setContentView(binding.root)

        pairingManager = PairingManager(KeyManager(this))
        cameraExecutor = Executors.newSingleThreadExecutor()

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            == PackageManager.PERMISSION_GRANTED
        ) {
            startCamera()
        } else {
            requestCamera.launch(Manifest.permission.CAMERA)
        }
    }

    override fun onDestroy() {
        cameraExecutor.shutdown()
        scanner.close()
        super.onDestroy()
    }

    private fun startCamera() {
        val providerFuture = ProcessCameraProvider.getInstance(this)
        providerFuture.addListener({
            val provider = providerFuture.get()

            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(binding.cameraPreview.surfaceProvider)
            }

            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { it.setAnalyzer(cameraExecutor, ::analyze) }

            try {
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (e: Exception) {
                Log.e(TAG, "Camera bind failed: ${e.message}")
                binding.statusText.text = "Could not open the camera"
            }
        }, ContextCompat.getMainExecutor(this))
    }

    @androidx.camera.core.ExperimentalGetImage
    private fun analyze(proxy: ImageProxy) {
        val mediaImage = proxy.image
        if (mediaImage == null || handled) {
            proxy.close()
            return
        }

        val image = InputImage.fromMediaImage(mediaImage, proxy.imageInfo.rotationDegrees)
        scanner.process(image)
            .addOnSuccessListener { barcodes ->
                barcodes.firstOrNull { it.rawValue != null }?.rawValue?.let(::onScanned)
            }
            .addOnCompleteListener { proxy.close() }
    }

    private fun onScanned(content: String) {
        if (handled) return

        val qrData = pairingManager.parseQrContent(content)
        if (qrData == null) {
            runOnUiThread { binding.statusText.text = "That is not a Bridg QR code" }
            return
        }
        handled = true

        startForegroundService(Intent(this, BridgService::class.java).apply {
            action = BridgService.ACTION_PAIR
            putExtra(BridgService.EXTRA_PEER_PUBKEY, Base64.encodeToString(qrData.publicKey, Base64.NO_WRAP))
            putExtra(BridgService.EXTRA_PEER_NAME, qrData.deviceName)
            putExtra(BridgService.EXTRA_PEER_HOST, qrData.host)
            putExtra(BridgService.EXTRA_PAIRING_TOKEN, qrData.token)
        })

        runOnUiThread {
            binding.statusText.text = "Pairing with ${qrData.deviceName}…"
            finish()
        }
    }

    companion object {
        private const val TAG = "PairingActivity"
    }
}
