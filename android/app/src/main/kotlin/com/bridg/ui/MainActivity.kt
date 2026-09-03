package com.bridg.ui

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.bridg.R
import com.bridg.databinding.ActivityMainBinding
import com.bridg.pairing.KeyManager
import com.bridg.service.BridgService

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var keyManager: KeyManager

    private var bridgService: BridgService? = null
    private var isBound = false

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            bridgService = (binder as BridgService.LocalBinder).getService()
            isBound = true
            // Push status straight into the UI instead of the old TODO comments.
            bridgService?.onStatusChanged = { text -> runOnUiThread { binding.statusText.text = text } }
            updateUI()
            // The bind can land after onResume; sync once we actually have the service.
            bridgService?.syncClipboardNow()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            bridgService = null
            isBound = false
        }
    }

    private val mediaProjectionLauncher = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            startForegroundService(Intent(this, BridgService::class.java).apply {
                action = BridgService.ACTION_START_CAPTURE
                // The consent Intent is what is Parcelable, not the projection.
                putExtra(BridgService.EXTRA_MEDIA_PROJECTION, result.data)
            })
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        keyManager = KeyManager(this)
        requestPermissions()

        binding.btnPair.setOnClickListener {
            startActivity(Intent(this, PairingActivity::class.java))
        }

        binding.btnStartCapture.setOnClickListener {
            if (bridgService?.isConnected() != true) {
                Toast.makeText(this, "Connect to your Mac first", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            mediaProjectionLauncher.launch(manager.createScreenCaptureIntent())
        }

        val serviceIntent = Intent(this, BridgService::class.java).apply {
            action = BridgService.ACTION_START
        }
        startForegroundService(serviceIntent)
        bindService(serviceIntent, serviceConnection, Context.BIND_AUTO_CREATE)

        handleShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShare(intent)
    }

    /**
     * Take files handed to us by the system share sheet and push them to the Mac.
     *
     * This is the only way to send a file *from* the phone: the app had no
     * send UI at all, and ACTION_SEND is the idiomatic Android entry point
     * rather than a bespoke file browser.
     */
    private fun handleShare(intent: Intent?) {
        val uris: List<android.net.Uri> = when (intent?.action) {
            Intent.ACTION_SEND ->
                listOfNotNull(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(Intent.EXTRA_STREAM, android.net.Uri::class.java)
                    } else {
                        @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
                    }
                )
            Intent.ACTION_SEND_MULTIPLE ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, android.net.Uri::class.java).orEmpty()
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra<android.net.Uri>(Intent.EXTRA_STREAM).orEmpty()
                }
            else -> emptyList()
        }
        if (uris.isEmpty()) return

        for (uri in uris) {
            startForegroundService(Intent(this, BridgService::class.java).apply {
                action = BridgService.ACTION_SEND_FILE
                putExtra(BridgService.EXTRA_FILE_URI, uri.toString())
            })
        }
        Toast.makeText(this, "Sending ${uris.size} file(s) to your Mac", Toast.LENGTH_SHORT).show()
    }

    override fun onDestroy() {
        bridgService?.onStatusChanged = null
        if (isBound) {
            unbindService(serviceConnection)
            isBound = false
        }
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        checkPermissions()
        updateUI()
        // Android 10+ only lets a focused app read the clipboard, so this is the
        // one moment phone→Mac clipboard sync can actually happen.
        bridgService?.syncClipboardNow()
    }

    private fun requestPermissions() {
        val permissions = mutableListOf<String>()

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) {
            permissions.add(Manifest.permission.CAMERA)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
                permissions.add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        if (permissions.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, permissions.toTypedArray(), REQUEST_PERMISSIONS)
        }
    }

    private fun checkPermissions() {
        if (!isNotificationListenerEnabled()) {
            showPermissionDialog(
                "Notification Access",
                getString(R.string.notification_listener_description),
                Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            )
        }
    }

    private fun isNotificationListenerEnabled(): Boolean {
        val componentName = ComponentName(this, "com.bridg.notify.BridgNotificationListenerService")
        val enabled = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        return enabled?.contains(componentName.flattenToString()) == true
    }

    private fun showPermissionDialog(title: String, message: String, settingsIntent: Intent) {
        AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(message)
            .setPositiveButton("Open Settings") { _, _ -> startActivity(settingsIntent) }
            .setNegativeButton("Later", null)
            .show()
    }

    private fun updateUI() {
        binding.deviceNameText.text = keyManager.getDeviceName()
        binding.pairedCountText.text = "${keyManager.getPairedDevices().size} paired device(s)"
        bridgService?.let { binding.statusText.text = it.statusText }
    }

    companion object {
        private const val REQUEST_PERMISSIONS = 100
    }
}
