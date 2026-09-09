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
            bridgService?.onStatusChanged = { _ -> runOnUiThread { updateUI() } }
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

    /** In-app counterpart to the share-sheet path: pick a file, send it. */
    private val filePickerLauncher = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.OpenMultipleDocuments()
    ) { uris -> sendUris(uris) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        // Content runs under the status bar; the root layout insets itself.
        androidx.core.view.WindowCompat.setDecorFitsSystemWindows(window, false)

        keyManager = KeyManager(this)
        requestPermissions()

        binding.rowNotificationAccess.setOnClickListener {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }

        binding.rowAccessibilityAccess.setOnClickListener {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }

        binding.btnPair.setOnClickListener {
            startActivity(Intent(this, PairingActivity::class.java))
        }

        binding.btnStartCapture.setOnClickListener {
            if (bridgService?.isConnected() != true) {
                Toast.makeText(this, getString(R.string.connect_first), Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            mediaProjectionLauncher.launch(manager.createScreenCaptureIntent())
        }

        binding.btnSendFile.setOnClickListener {
            if (bridgService?.isConnected() != true) {
                Toast.makeText(this, getString(R.string.connect_first), Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            filePickerLauncher.launch(arrayOf("*/*"))
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
     * ACTION_SEND from another app is one entry point; [btnSendFile]'s document
     * picker is the other, for a file the user wants to send starting from
     * inside Bridg itself.
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
        sendUris(uris)
    }

    private fun sendUris(uris: List<android.net.Uri>) {
        if (uris.isEmpty()) return

        if (bridgService?.isConnected() != true) {
            Toast.makeText(this, getString(R.string.connect_first), Toast.LENGTH_SHORT).show()
            return
        }

        for (uri in uris) {
            // Best-effort: hold the read grant past this call. BridgService
            // opens the Uri moments later on its own thread, and a transient
            // grant from some providers can already be gone by then.
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (e: SecurityException) {
                // Not every provider grants persistable access; the immediate
                // read in BridgService still works for those.
            }
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

        // Only matters below API 29: from Q on, an app writing its own files to
        // the public Downloads dir needs no permission at all (scoped storage),
        // and the manifest already caps this permission at maxSdkVersion 29.
        // Below that, receiving a file from the Mac needs it granted at runtime.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE)
            != PackageManager.PERMISSION_GRANTED) {
            permissions.add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
                permissions.add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        // Needed to answer/end calls from the Mac via TelecomManager; without it
        // BridgService falls back to the accessibility headset-hook key.
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ANSWER_PHONE_CALLS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            permissions.add(Manifest.permission.ANSWER_PHONE_CALLS)
        }

        // Detecting a ringing call directly — the Samsung dialer's own
        // notification is never delivered to NotificationListenerService.
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            permissions.add(Manifest.permission.READ_PHONE_STATE)
        }

        if (permissions.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, permissions.toTypedArray(), REQUEST_PERMISSIONS)
        }
    }

    private fun checkPermissions() {
        if (permissionsPrompted) return
        permissionsPrompted = true
        if (!isNotificationListenerEnabled()) {
            showPermissionDialog(
                "Notification Access",
                getString(R.string.notification_listener_description),
                Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            )
        } else if (!isAccessibilityEnabled()) {
            // Without this, InputEvents from the Mac reach BridgService and are
            // dropped — mirroring shows the screen but no tap does anything.
            showPermissionDialog(
                "Accessibility Access",
                getString(R.string.accessibility_service_description),
                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            )
        }
    }

    private fun isAccessibilityEnabled(): Boolean {
        val componentName = ComponentName(this, "com.bridg.input.BridgAccessibilityService")
        val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
        return enabled?.contains(componentName.flattenToString()) == true
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

        val paired = keyManager.getPairedDevices().size
        binding.pairedCountText.text = when (paired) {
            0 -> getString(R.string.paired_none)
            1 -> "1 Mac paired"
            else -> "$paired Macs paired"
        }

        bridgService?.let { binding.statusText.text = it.statusText }

        val connected = bridgService?.isConnected() == true
        binding.statusDot.backgroundTintList = ContextCompat.getColorStateList(
            this, if (connected) R.color.green else R.color.orange
        )
        binding.connectionLabel.setText(
            if (connected) R.string.state_connected else R.string.state_looking
        )

        renderAccess(binding.notificationAccessState, isNotificationListenerEnabled())
        renderAccess(binding.accessibilityAccessState, isAccessibilityEnabled())
    }

    private fun renderAccess(view: android.widget.TextView, enabled: Boolean) {
        view.setText(if (enabled) R.string.access_on else R.string.access_off)
        view.setTextColor(
            ContextCompat.getColor(this, if (enabled) R.color.label_secondary else R.color.orange)
        )
    }

    /** The settings dialogs interrupt once per launch; the Permissions rows show the rest. */
    private var permissionsPrompted = false

    companion object {
        private const val REQUEST_PERMISSIONS = 100
    }
}
