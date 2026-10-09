package com.bridg.service

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.util.Base64
import android.util.Log
import com.bridg.BridgApplication
import com.bridg.R
import com.bridg.capture.AudioCapture
import com.bridg.capture.ScreenCapture
import com.bridg.clipboard.BridgClipboardManager
import com.bridg.files.FileTransferManager
import com.bridg.notify.BridgNotificationListenerService
import com.bridg.media.MediaControl
import com.bridg.pairing.KeyManager
import com.bridg.pairing.PairingManager
import com.bridg.pairing.SessionKdf
import com.bridg.remote.RemoteActionHandler
import com.bridg.status.BatteryMonitor
import com.bridg.proto.*
import com.google.protobuf.ByteString
import com.bridg.transport.BridgSocket
import com.bridg.transport.ServiceDiscovery
import com.bridg.ui.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Foreground service that owns the links to every paired computer (Mac,
 * Windows, Linux) and every feature that rides on them: pairing, clipboard,
 * notifications, file transfer, screen capture.
 */
class BridgService : Service() {

    private val binder = LocalBinder()
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private lateinit var keyManager: KeyManager
    private lateinit var pairingManager: PairingManager
    private lateinit var serviceDiscovery: ServiceDiscovery

    /** One link per paired (or pairing) computer, keyed by [KeyManager.hubTag]. */
    private val links = java.util.concurrent.ConcurrentHashMap<String, HubLink>()

    private lateinit var screenCapture: ScreenCapture
    private lateinit var audioCapture: AudioCapture
    private lateinit var mediaControl: MediaControl
    private lateinit var clipboardManager: BridgClipboardManager
    private lateinit var fileTransferManager: FileTransferManager
    private lateinit var batteryMonitor: BatteryMonitor
    private lateinit var remoteActions: RemoteActionHandler

    private var mediaProjection: MediaProjection? = null
    private var isServiceRunning = false

    /** Last reported send percentage, so progress doesn't respam the notification. */
    @Volatile private var lastSendPercent = -1

    private var telephonyCallback: Any? = null
    @Volatile private var callRinging = false

    /** Observed by MainActivity for the status line. */
    @Volatile var statusText: String = "Searching…"
        private set
    var onStatusChanged: ((String) -> Unit)? = null

    override fun onCreate() {
        super.onCreate()
        instance = this

        keyManager = KeyManager(this)
        pairingManager = PairingManager(keyManager)
        serviceDiscovery = ServiceDiscovery(this)
        screenCapture = ScreenCapture(this)
        audioCapture = AudioCapture()
        mediaControl = MediaControl(this)
        clipboardManager = BridgClipboardManager(this)
        fileTransferManager = FileTransferManager(this)
        batteryMonitor = BatteryMonitor(this)
        remoteActions = RemoteActionHandler(this)

        for ((id, device) in keyManager.getPairedDevices()) {
            val link = HubLink(java.util.Base64.getDecoder().decode(device.publicKey), device.name.ifEmpty { "computer" }, id)
            links[link.tag] = link
        }
        statusText = connectionSummary()

        // Nothing ever set a listener, so every transfer outcome — finished,
        // failed, rejected by the Mac — went nowhere and the status line sat on
        // "Sending …" forever, even for transfers that had completed fine.
        fileTransferManager.setTransferListener(object : FileTransferManager.TransferListener {
            override fun onTransferStarted(transferId: String, filename: String, totalSize: Long) {
                updateStatus("Receiving $filename…")
            }

            override fun onChunkSent(transferId: String, offset: Long, totalSize: Long) {
                // Fires per 64 KB chunk; rebuilding the notification that often
                // is pure churn, so only speak up when the number changes.
                val percent = if (totalSize > 0) (offset * 100 / totalSize).toInt() else 0
                if (percent == lastSendPercent) return
                lastSendPercent = percent
                updateStatus("Sending… $percent%")
            }

            override fun onTransferCompleted(transferId: String) {
                lastSendPercent = -1
                updateStatus(if (isConnected()) connectionSummary() else "Transfer complete")
            }

            override fun onTransferError(transferId: String, error: String) {
                lastSendPercent = -1
                updateStatus("Transfer failed: $error")
            }

            override fun onTransferCancelled(transferId: String, reason: String) {
                lastSendPercent = -1
                updateStatus("Transfer cancelled")
            }
        })
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground must happen fast on every start path or Android kills us.
        if (!isServiceRunning) startService()

        when (intent?.action) {
            ACTION_STOP -> stopService()
            ACTION_PAIR -> {
                val key = intent.getStringExtra(EXTRA_PEER_PUBKEY)
                val token = intent.getStringExtra(EXTRA_PAIRING_TOKEN)
                val name = intent.getStringExtra(EXTRA_PEER_NAME) ?: "Mac"
                val host = intent.getStringExtra(EXTRA_PEER_HOST).orEmpty()
                if (key != null && token != null) {
                    val qr = PairingManager.QRData(Base64.decode(key, Base64.NO_WRAP), token, host, name)
                    // Re-scanning a computer we already know replaces its link so
                    // the handshake runs from a clean socket; the others stay up.
                    val tag = KeyManager.hubTag(qr.publicKey)
                    val old = links.remove(tag)
                    old?.close()
                    val link = HubLink(qr.publicKey, name, old?.deviceId, pairing = qr)
                    links[tag] = link
                    updateStatus("Pairing with $name…")
                    link.dial()
                }
            }
            ACTION_START_CAPTURE -> {
                val resultData = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(EXTRA_MEDIA_PROJECTION, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableExtra(EXTRA_MEDIA_PROJECTION)
                }
                // A MediaProjection is not Parcelable; only the consent Intent is.
                // The old code asked for a MediaProjection extra and always got null,
                // so screen capture never started.
                if (resultData != null) startScreenCapture(resultData)
            }
            ACTION_SEND_FILE -> {
                val uri = intent.getStringExtra(EXTRA_FILE_URI)
                if (uri != null) queueOrSend(android.net.Uri.parse(uri), intent.getStringExtra(EXTRA_HUB_ID))
                else intent.getStringExtra(EXTRA_FILE_PATH)?.let { sendFile(it) }
            }
            ACTION_DISCONNECT -> links.values.forEach { it.socket.disconnect() }
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent): IBinder = binder

    override fun onDestroy() {
        stopService()
        if (instance === this) instance = null
        super.onDestroy()
    }

    /** True when at least one computer has a live, encrypted session. */
    fun isConnected(): Boolean = links.values.any { it.ready }

    fun pairedDeviceCount(): Int = keyManager.getPairedDevices().size

    fun deviceName(): String = keyManager.getDeviceName()

    private fun startService() {
        isServiceRunning = true
        // Start as connectedDevice only. The manifest also declares
        // mediaProjection, and from Android 14 on, going foreground with that
        // type before the user has granted projection consent is a SecurityException
        // that kills the process — which is what happened on every launch.
        startForegroundWithTypes(ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        startDiscovery()
        startClipboardMonitoring()
        startNotificationForwarding()
        startCallStateMonitoring()
        startBatteryMonitoring()
        Log.i(TAG, "Bridg service started")
    }

    private fun stopService() {
        if (!isServiceRunning) return
        isServiceRunning = false

        screenCapture.stopCapture()
        audioCapture.stop()
        mediaControl.stop()
        clipboardManager.stopMonitoring()
        stopCallStateMonitoring()
        batteryMonitor.stop()
        remoteActions.stopRing()
        serviceDiscovery.stopDiscovery()
        links.values.forEach { it.close() }

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        Log.i(TAG, "Bridg service stopped")
    }

    private fun startDiscovery() {
        // Known-host dials and discovery race; whichever lands first wins and
        // the other is a no-op (BridgSocket.connect refuses a second dial).
        links.values.forEach { it.dial() }

        serviceDiscovery.startDiscovery(
            onFound = { serviceInfo ->
                if (links.values.all { it.connected }) return@startDiscovery
                serviceDiscovery.resolveService(serviceInfo,
                    onResolved = { host, port, tag ->
                        val link = linkFor(tag) ?: return@resolveService
                        val address = host.hostAddress ?: return@resolveService
                        if (link.connected) return@resolveService
                        link.deviceId?.let { keyManager.setHost(it, address) }
                        link.dial(address, port)
                    },
                    onFailed = { error -> Log.e(TAG, "Failed to resolve service: $error") }
                )
            },
            onLost = { Log.d(TAG, "Computer lost: ${it.serviceName}") }
        )
    }

    /** Rebuild the browse so a fresh resolve fires and lost links dial back in. */
    private fun restartDiscovery() {
        serviceDiscovery.stopDiscovery()
        startDiscovery()
    }

    /**
     * The link a discovered service belongs to. Hubs advertise their
     * [KeyManager.hubTag] in TXT `id`; Mac builds from before multi-hub don't,
     * and are only safe to guess at when a single computer is known. Anything
     * else on the LAN advertising _bridg._tcp is not ours and is never dialled.
     */
    private fun linkFor(tag: String?): HubLink? =
        if (tag != null) links[tag] else links.values.singleOrNull()

    /** "Connected to MacBook, DESKTOP-1", for the status line. */
    private fun connectionSummary(): String {
        if (links.isEmpty()) return "Not paired — scan the QR code on your computer"
        val ready = links.values.filter { it.ready }.map { it.name }
        return if (ready.isNotEmpty()) "Connected to ${ready.joinToString()}"
        else "Searching for ${links.values.joinToString { it.name }}…"
    }

    /** Send to every computer whose session is up. */
    private fun broadcast(envelope: Envelope) = links.values.forEach { if (it.ready) it.send(envelope) }

    /**
     * Push the phone's current clipboard to every connected computer.
     *
     * Called by [MainActivity] when it comes to the foreground: since Android 10
     * a background app gets `null` from `getPrimaryClip()`, so the change
     * listener alone could never send anything and the sync was Mac→phone only.
     * While an activity of ours holds focus the read is permitted.
     */
    fun syncClipboardNow() = clipboardManager.syncCurrentClip()

    private fun startBatteryMonitoring() {
        batteryMonitor.start { status ->
            broadcast(Envelope.newBuilder().setDeviceStatus(status).build())
        }
    }

    private fun startClipboardMonitoring() {
        clipboardManager.startMonitoring(object : BridgClipboardManager.ClipboardForwarder {
            override fun onClipboardChanged(update: ClipboardUpdate) {
                broadcast(Envelope.newBuilder().setClipboard(update).build())
            }
        })
    }

    /**
     * Called by [BridgNotificationListenerService] once it connects.
     *
     * `NotificationListenerService` is bound by the system on its own schedule,
     * independent of this service's lifecycle — it can (and in testing,
     * regularly did) connect *after* both `startService()` and `onConnected()`
     * already tried to wire it up. Neither of those call sites retried, so the
     * forwarder was silently never set and notifications never left the phone.
     * Wiring from this direction too means whichever side comes up last
     * completes the connection.
     */
    fun onNotificationListenerReady() {
        startNotificationForwarding()
    }

    /** Hook the notification listener up to the wire. */
    private fun startNotificationForwarding() {
        BridgNotificationListenerService.instance?.setEventForwarder(
            object : BridgNotificationListenerService.NotificationEventForwarder {
                override fun onNotificationPosted(event: NotificationEvent) {
                    broadcast(Envelope.newBuilder().setNotification(event).build())
                }

                override fun onNotificationDismissed(event: NotificationEvent) {
                    broadcast(
                        Envelope.newBuilder().setNotifDismiss(
                            NotificationDismiss.newBuilder()
                                .setId(event.id)
                                .setPackageName(event.packageName)
                                .build()
                        ).build()
                    )
                }
            }
        )
        // Media sessions need the same notification-listener grant, so this is
        // the first moment they can be read.
        mediaControl.stop()
        mediaControl.start { state ->
            broadcast(Envelope.newBuilder().setMediaState(state).build())
        }

        // A call notification posts once. If it landed while the link was down,
        // re-send whatever calls are still ringing now that we're back.
        BridgNotificationListenerService.instance?.forwardActiveCalls()
        if (callRinging) sendCallEvent(ringing = true)
    }

    private val CALL_EVENT_ID = "bridg:incoming-call"

    /**
     * Watch the phone's call state directly. The Samsung dialer's incoming-call
     * notification is never delivered to NotificationListenerService, so that
     * path alone misses every call — this is what actually makes calls show up
     * on the Mac.
     */
    private fun startCallStateMonitoring() {
        if (checkSelfPermission(android.Manifest.permission.READ_PHONE_STATE) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "READ_PHONE_STATE not granted — call detection disabled")
            return
        }
        val tm = getSystemService(TELEPHONY_SERVICE) as android.telephony.TelephonyManager
        val onState: (Int) -> Unit = { state ->
            val ringing = state == android.telephony.TelephonyManager.CALL_STATE_RINGING
            if (ringing != callRinging) {
                callRinging = ringing
                sendCallEvent(ringing)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val cb = object : android.telephony.TelephonyCallback(),
                android.telephony.TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) = onState(state)
            }
            telephonyCallback = cb
            tm.registerTelephonyCallback(mainExecutor, cb)
        } else {
            @Suppress("DEPRECATION")
            val listener = object : android.telephony.PhoneStateListener() {
                override fun onCallStateChanged(state: Int, phoneNumber: String?) = onState(state)
            }
            telephonyCallback = listener
            @Suppress("DEPRECATION")
            tm.listen(listener, android.telephony.PhoneStateListener.LISTEN_CALL_STATE)
        }
    }

    private fun stopCallStateMonitoring() {
        val cb = telephonyCallback ?: return
        val tm = getSystemService(TELEPHONY_SERVICE) as android.telephony.TelephonyManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            tm.unregisterTelephonyCallback(cb as android.telephony.TelephonyCallback)
        } else {
            @Suppress("DEPRECATION")
            tm.listen(cb as android.telephony.PhoneStateListener,
                android.telephony.PhoneStateListener.LISTEN_NONE)
        }
        telephonyCallback = null
    }

    /** Tell the Mac a call started ringing (Answer/Decline) or stopped (clear it). */
    private fun sendCallEvent(ringing: Boolean) {
        // The dialer's own CATEGORY_CALL notification carries the caller name and
        // is forwarded on its own — only fall back to this bare event when that
        // notification isn't reaching the listener.
        val haveCallNotification = BridgNotificationListenerService.instance
            ?.activeNotifications?.any {
                it.notification?.category == android.app.Notification.CATEGORY_CALL
            } == true
        if (ringing) {
            if (haveCallNotification) return
            broadcast(
                Envelope.newBuilder().setNotification(
                    NotificationEvent.newBuilder()
                        .setId(CALL_EVENT_ID)
                        .setPackageName("com.android.phone")
                        .setAppLabel("Phone")
                        .setTitle("Incoming call")
                        .setText("Incoming call")
                        .setTimestamp(System.currentTimeMillis())
                        .setIsCall(true)
                ).build()
            )
        } else {
            broadcast(
                Envelope.newBuilder().setNotifDismiss(
                    NotificationDismiss.newBuilder().setId(CALL_EVENT_ID).setPackageName("com.android.phone")
                ).build()
            )
        }
    }

    /**
     * @param consent the Intent returned by the system consent dialog.
     *
     * The MediaProjection is minted *here*, not by the caller: from Android 14
     * on, `getMediaProjection()` requires the service to already be foreground
     * with `FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION`. The old code evaluated
     * `getMediaProjection()` as an argument to this function, i.e. before the
     * `startForegroundWithTypes` call below, and took a SecurityException that
     * killed the process every time mirroring was started.
     */
    private fun startScreenCapture(consent: Intent) {
        // Consent is in hand, so the mediaProjection type is now legal to claim.
        // MICROPHONE is for the playback capture that rides along with the
        // video — Android 14 treats any AudioRecord as microphone use and kills
        // a service that records without declaring it.
        startForegroundWithTypes(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        )

        val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = try {
            manager.getMediaProjection(android.app.Activity.RESULT_OK, consent)
        } catch (e: Exception) {
            Log.e(TAG, "Screen capture consent rejected: ${e.message}")
            startForegroundWithTypes(ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            updateStatus("Screen mirroring unavailable")
            return
        }

        mediaProjection = projection

        // MediaCodec/VirtualDisplay setup is device-dependent and can throw
        // (an unsupported size, a codec the device doesn't have). Uncaught,
        // that used to kill the whole foreground service — and with it the
        // Mac connection — over a phone-specific quirk that has nothing to do
        // with pairing or transport.
        try {
            screenCapture.startCapture(projection, object : ScreenCapture.FrameCallback {
                override fun onConfigFrame(spsPps: ByteArray) {
                    broadcast(
                        Envelope.newBuilder().setVideoStreamStart(
                            VideoStreamStart.newBuilder()
                                .setStreamType(VideoStreamStart.StreamType.SCREEN)
                                // Must match what the encoder was actually configured
                                // with, not the raw panel size.
                                .setWidth(screenCapture.width)
                                .setHeight(screenCapture.height)
                                .setFps(30)
                                .setSpsPps(com.google.protobuf.ByteString.copyFrom(spsPps))
                                .build()
                        ).build()
                    )
                }

                override fun onVideoFrame(nalUnits: ByteArray, pts: Long, isKeyframe: Boolean) {
                    val envelope = Envelope.newBuilder().setVideoFrame(
                        VideoFrame.newBuilder()
                            .setStreamId("screen")
                            .setNalUnits(com.google.protobuf.ByteString.copyFrom(nalUnits))
                            .setPts(pts)
                            .setIsKeyframe(isKeyframe)
                            .build()
                    ).build()

                    // Frames a socket had to drop leave that computer's decoder
                    // referencing pictures it never got; without this it stays
                    // broken until the next scheduled I-frame, two seconds out.
                    //
                    // ponytail: the mirror goes to every connected computer,
                    // N× the bandwidth. Add a target picker if two at once hurts.
                    var needKeyframe = false
                    for (link in links.values) {
                        if (link.ready && link.socket.sendVideoFrame(envelope, isKeyframe)) needKeyframe = true
                    }
                    if (needKeyframe) screenCapture.requestKeyframe()
                }
            })

            // Same projection, so the Mac hears what it sees. Best-effort:
            // a device or app that refuses playback capture just stays silent.
            audioCapture.start(projection) { pcm, sampleRate, channels ->
                broadcast(
                    Envelope.newBuilder().setAudioFrame(
                        AudioFrame.newBuilder()
                            .setPcm(com.google.protobuf.ByteString.copyFrom(pcm))
                            .setSampleRate(sampleRate)
                            .setChannels(channels)
                            .build()
                    ).build()
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start screen capture: ${e.message}")
            audioCapture.stop()
            this.mediaProjection = null
            startForegroundWithTypes(ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            updateStatus("Screen mirroring unavailable on this device")
        }
    }

    /**
     * Send a file the user picked through the system share sheet.
     *
     * A share sheet hands over a content:// Uri, not a path — nothing outside
     * the app's own storage can be opened as a raw `File` under scoped storage,
     * so [sendFile] could never have served the share path.
     */
    private fun queueOrSend(uri: android.net.Uri, deviceId: String?) {
        // The share screen asks which computer when there is more than one;
        // without a choice, take one that is up now.
        val link = links.values.firstOrNull { it.deviceId != null && it.deviceId == deviceId }
            ?: links.values.firstOrNull { it.ready } ?: links.values.firstOrNull()
        if (link == null) {
            updateStatus("Pair a computer first")
            return
        }
        if (link.ready) return sendUri(link, uri)
        link.pendingShares.add(uri)
        updateStatus("${link.pendingShares.size} file(s) waiting for ${link.name}…")
    }

    private fun sendUri(link: HubLink, uri: android.net.Uri) {
        var name = uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        var size = 0L

        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    .takeIf { it >= 0 && !cursor.isNull(it) }
                    ?.let { name = cursor.getString(it) }
                cursor.getColumnIndex(android.provider.OpenableColumns.SIZE)
                    .takeIf { it >= 0 && !cursor.isNull(it) }
                    ?.let { size = cursor.getLong(it) }
            }
        }

        val stream = try {
            contentResolver.openInputStream(uri)
        } catch (e: Exception) {
            Log.e(TAG, "Cannot read $uri: ${e.message}")
            null
        }
        if (stream == null) {
            updateStatus("Could not read the shared file")
            return
        }
        if (size <= 0L) {
            // A provider is allowed to report no size; without one the receiver
            // never sees the transfer finish, so refuse rather than hang.
            Log.e(TAG, "Provider reported no size for $uri")
            stream.close()
            updateStatus("Shared file has no readable size")
            return
        }

        updateStatus("Sending $name to ${link.name}…")
        // Blocking enqueue so a fast disk read can't outrun the socket and get
        // chunks dropped — that was the "file transfer works sometimes" bug.
        fileTransferManager.startSend(
            stream, name, size,
            contentResolver.getType(uri) ?: "application/octet-stream"
        ) { link.socket.sendBlocking(it) }
    }

    private fun sendFile(filePath: String) {
        val link = links.values.firstOrNull { it.ready } ?: return
        val file = java.io.File(filePath)
        // A raw File path outside the app's own storage can pass exists() (a
        // stat()) and still fail to open under scoped storage — this used to
        // throw uncaught out of onStartCommand and crash the whole service,
        // taking the phone-Mac connection down with it over one bad file path.
        val stream = try {
            if (!file.exists()) throw java.io.FileNotFoundException("$filePath does not exist")
            file.inputStream()
        } catch (e: Exception) {
            Log.e(TAG, "Cannot read $filePath: ${e.message}")
            return
        }
        fileTransferManager.startSend(stream, file.name, file.length(), "application/octet-stream") {
            link.socket.sendBlocking(it)
        }
    }

    /**
     * Act on a call-control command from the Mac.
     *
     * Answer/end go through TelecomManager when ANSWER_PHONE_CALLS is granted;
     * otherwise we fall back to the accessibility service's headset-hook key,
     * which toggles answer/hang-up the same way a wired headset button does.
     * Mute and speaker are plain AudioManager calls (MODIFY_AUDIO_SETTINGS).
     */
    private fun handleCallControl(action: CallControl.Action) {
        val audio = getSystemService(AUDIO_SERVICE) as android.media.AudioManager
        when (action) {
            CallControl.Action.ANSWER, CallControl.Action.END, CallControl.Action.REJECT -> {
                // App-VoIP calls (WhatsApp, Telegram…) have no telephony call
                // behind them, so acceptRingingCall()/headset-hook do nothing —
                // fire the notification's own action instead. Only reach for
                // TelecomManager when a real cellular call is actually ringing.
                if (!callRinging &&
                    BridgNotificationListenerService.instance
                        ?.fireCallAction(answer = action == CallControl.Action.ANSWER) == true
                ) {
                    return
                }

                val telecom = getSystemService(TELECOM_SERVICE) as android.telecom.TelecomManager
                val granted = checkSelfPermission(android.Manifest.permission.ANSWER_PHONE_CALLS) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
                try {
                    if (granted && action == CallControl.Action.ANSWER &&
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                    ) {
                        telecom.acceptRingingCall()
                    } else if (granted && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        @Suppress("MissingPermission") telecom.endCall()
                    } else {
                        com.bridg.input.BridgAccessibilityService.instance?.pressHeadsetHook()
                    }
                } catch (e: SecurityException) {
                    Log.w(TAG, "Call control denied, trying accessibility: ${e.message}")
                    com.bridg.input.BridgAccessibilityService.instance?.pressHeadsetHook()
                }
            }
            CallControl.Action.MUTE -> audio.isMicrophoneMute = true
            CallControl.Action.UNMUTE -> audio.isMicrophoneMute = false
            CallControl.Action.SPEAKER_ON -> audio.isSpeakerphoneOn = true
            CallControl.Action.SPEAKER_OFF -> audio.isSpeakerphoneOn = false
            else -> Log.w(TAG, "Unhandled call action: $action")
        }
    }

    /** Everything after the handshake, from [from]. Replies go back on the same link. */
    private fun handleIncomingEnvelope(from: HubLink, envelope: Envelope) {
        when (envelope.payloadCase) {
            Envelope.PayloadCase.REMOTE_ACTION -> remoteActions.handle(envelope.remoteAction)

            Envelope.PayloadCase.CLIPBOARD -> {
                clipboardManager.handleRemoteClipboard(envelope.clipboard)
                // Pass it on: copy on the Mac, paste on the PC. origin_id rides
                // along unchanged, so the computer it came from ignores it.
                links.values.forEach { if (it !== from && it.ready) it.send(envelope) }
            }

            Envelope.PayloadCase.NOTIF_ACTION -> {
                BridgNotificationListenerService.instance?.handleReplyAction(
                    envelope.notifAction.actionId,
                    envelope.notifAction.label
                )
            }

            Envelope.PayloadCase.FILE_START -> {
                // Opening the destination can fail (storage full, provider says
                // no). It runs on the socket read thread, so an escape here
                // takes down the whole link.
                try {
                    val outputStream = fileTransferManager.createReceiveFile(envelope.fileStart.filename)
                    fileTransferManager.handleTransferStart(envelope.fileStart, outputStream)
                } catch (e: Exception) {
                    Log.e(TAG, "Cannot receive ${envelope.fileStart.filename}: ${e.message}")
                    from.send(
                        Envelope.newBuilder().setFileAck(
                            FileTransferAck.newBuilder()
                                .setTransferId(envelope.fileStart.transferId)
                                .setError(e.message ?: "Cannot open destination")
                                .build()
                        ).build()
                    )
                }
            }

            Envelope.PayloadCase.FILE_CHUNK -> {
                from.send(
                    Envelope.newBuilder()
                        .setFileAck(fileTransferManager.handleFileChunk(envelope.fileChunk))
                        .build()
                )
            }

            Envelope.PayloadCase.FILE_ACK -> fileTransferManager.handleAck(envelope.fileAck)

            Envelope.PayloadCase.INPUT_EVENT -> {
                com.bridg.input.BridgAccessibilityService.instance?.dispatchInputEvent(envelope.inputEvent)
            }

            Envelope.PayloadCase.CALL_CONTROL -> handleCallControl(envelope.callControl.action)

            // The Mac deleting a notification clears it on the phone too.
            Envelope.PayloadCase.NOTIF_DISMISS -> {
                BridgNotificationListenerService.instance?.dismissFromRemote(envelope.notifDismiss.id)
            }

            Envelope.PayloadCase.MEDIA_COMMAND -> mediaControl.handleCommand(envelope.mediaCommand.action)

            Envelope.PayloadCase.PING -> {
                from.send(
                    Envelope.newBuilder().setPong(
                        Pong.newBuilder()
                            .setTimestamp(System.currentTimeMillis())
                            .setPingTimestamp(envelope.ping.timestamp)
                            .build()
                    ).build()
                )
            }

            Envelope.PayloadCase.PONG -> Unit

            else -> Log.d(TAG, "Unhandled envelope type: ${envelope.payloadCase}")
        }
    }

    private fun startForegroundWithTypes(types: Int) {
        val notification = createNotification(statusText)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, types)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotification(contentText: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )

        // Reading the clipboard needs foreground focus on Android 10+, so this
        // routes through a transparent activity that grabs focus and finishes.
        val clipboardIntent = PendingIntent.getActivity(
            this, 1,
            Intent(this, com.bridg.ui.ClipboardBridgeActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
            PendingIntent.FLAG_IMMUTABLE
        )

        return Notification.Builder(this, BridgApplication.CHANNEL_SERVICE)
            .setContentTitle("Bridg")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_stat_bridg)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_stat_bridg),
                    "Send clipboard",
                    clipboardIntent
                ).build()
            )
            .build()
    }

    /**
     * The connection to one computer. Each has its own socket, salt, session
     * key and retry timer, so one going away never touches the others.
     */
    private inner class HubLink(
        val peerKey: ByteArray,
        @Volatile var name: String,
        /** Null until pairing completes. */
        @Volatile var deviceId: String?,
        /** Set while pairing from a fresh QR scan; null for a resume. */
        @Volatile var pairing: PairingManager.QRData? = null,
    ) : BridgSocket.ConnectionListener {
        val tag = KeyManager.hubTag(peerKey)
        val socket = BridgSocket().also {
            it.setConnectionListener(this)
            it.setReceiveListener { envelope -> onEnvelope(envelope) }
        }

        @Volatile var connected = false

        /** True once the session key is set; before that BridgSocket drops everything. */
        @Volatile var ready = false

        /**
         * Our fresh salt for the connection currently handshaking. The
         * computer's half arrives in its reply, and the session key needs both
         * — see [com.bridg.pairing.SessionKdf.deriveSessionKey].
         */
        @Volatile private var sessionSalt: ByteArray? = null

        /** The one pending redial after a failed connect; see [scheduleRetry]. */
        private var retryJob: Job? = null

        /** Files shared to this computer before its session was up; flushed by [onReady]. */
        val pendingShares: MutableList<android.net.Uri> =
            java.util.Collections.synchronizedList(mutableListOf())

        fun send(envelope: Envelope) = socket.send(envelope)

        /**
         * Dial [host], by default the last address we saw this computer at.
         *
         * mDNS is link-local multicast: on a segmented network (campus, office,
         * guest Wi-Fi) the phone and computer can route to each other fine while
         * discovery finds nothing at all. The QR code carries the address for
         * exactly this reason, and we keep using it on later reconnects.
         */
        fun dial(host: String? = pairing?.host?.ifEmpty { null } ?: deviceId?.let { keyManager.getHost(it) },
                 port: Int = DEFAULT_PORT) {
            if (connected || host == null) return
            scope.launch {
                if (!connected) {
                    Log.i(TAG, "Dialling $name at $host:$port")
                    socket.connect(host, port)
                }
            }
        }

        fun close() {
            retryJob?.cancel()
            socket.disconnect()
        }

        /**
         * Announce ourselves as soon as the socket is up: a fresh pairing if the
         * user just scanned a QR, otherwise a resume against the key we hold.
         * Encryption cannot start until the computer sends its salt half back,
         * so this frame goes out in the clear.
         */
        private fun startHandshake() {
            val salt = SessionKdf.randomSalt()
            sessionSalt = salt
            val qr = pairing
            send(
                if (qr != null) Envelope.newBuilder().setPairRequest(pairingManager.createPairRequest(qr.token, salt)).build()
                else Envelope.newBuilder().setPairResume(pairingManager.createPairResume(salt)).build()
            )
        }

        private fun onEnvelope(envelope: Envelope) {
            when (envelope.payloadCase) {
                Envelope.PayloadCase.PAIR_RESPONSE -> {
                    val qr = pairing ?: return
                    val key = pairingManager.verifyPairResponse(envelope.pairResponse, qr.publicKey)
                    if (key == null) {
                        // A computer we were already paired with falls back to
                        // resuming; a new one is forgotten, or it redials forever
                        // and the status line keeps "searching" for it.
                        pairing = null
                        if (deviceId == null) {
                            if (links.remove(tag, this)) close()
                        } else {
                            socket.disconnect()
                            scheduleRetry()
                        }
                        updateStatus("Pairing with $name failed")
                        return
                    }
                    val sessionKey = sessionKeyFor(envelope.pairResponse.sessionSalt) ?: return
                    name = envelope.pairResponse.deviceName.ifEmpty { name }
                    val id = pairingManager.completePairing(key, name)
                    deviceId = id
                    qr.host.ifEmpty { null }?.let { keyManager.setHost(id, it) }
                    pairing = null
                    onReady(sessionKey)
                }

                Envelope.PayloadCase.PAIR_RESUME_ACK -> {
                    // The ack is the computer's last plaintext frame; it carries
                    // the salt half we need before either side can seal anything.
                    if (!envelope.pairResumeAck.accepted) {
                        updateStatus("$name rejected the connection — re-pair")
                        return
                    }
                    val sessionKey = sessionKeyFor(envelope.pairResumeAck.sessionSalt) ?: return
                    onReady(sessionKey)
                }

                else -> handleIncomingEnvelope(this, envelope)
            }
        }

        /**
         * Session key for this connection, from the computer's salt and ours.
         * Null if it sent none — an old build whose key would repeat on every
         * reconnect, which is exactly what the salts prevent.
         */
        private fun sessionKeyFor(theirSalt: ByteString): ByteArray? {
            val ourSalt = sessionSalt
            if (ourSalt == null || theirSalt.size() != SessionKdf.SALT_LENGTH) {
                Log.e(TAG, "Handshake carried no session salt — refusing to connect")
                updateStatus("Bridg on $name is out of date — update it")
                socket.disconnect()
                return null
            }
            sessionSalt = null
            return keyManager.deriveSharedSecret(
                peerKey,
                SessionKdf.connectionInfo(initiatorSalt = ourSalt, responderSalt = theirSalt.toByteArray())
            )
        }

        /**
         * The session key is set: sealed frames can flow. Sends anything shared
         * while we were still connecting — off the receive thread, because the
         * file sender's blocking enqueue must not stall the socket reader.
         *
         * ponytail: the share's read grant can lapse if the user leaves the share
         * target long before the computer shows up; copy to cacheDir if that bites.
         */
        private fun onReady(sessionKey: ByteArray) {
            socket.setEncryptionKey(sessionKey)
            ready = true
            updateStatus(connectionSummary())
            val queued = synchronized(pendingShares) { pendingShares.toList().also { pendingShares.clear() } }
            if (queued.isNotEmpty()) scope.launch { queued.forEach { sendUri(this@HubLink, it) } }
            batteryMonitor.resend()
            // The listener may have bound after the service started; this also
            // re-sends ringing calls and media state, now sealed.
            startNotificationForwarding()
        }

        private fun reset() {
            connected = false
            ready = false
            sessionSalt = null
            socket.clearEncryption()
        }

        override fun onConnected() {
            connected = true
            startHandshake()
            // Notification forwarding (and its catch-up sends) starts once the
            // session key is set — see [onReady]. Anything sent before that is
            // dropped by BridgSocket rather than leaked in plaintext.
        }

        override fun onDisconnected() {
            reset()
            updateStatus(connectionSummary())
        }

        override fun onConnectionFailed(error: Exception) {
            connected = false
            Log.e(TAG, "Dialling $name failed: ${error.message}")
            scheduleRetry()
        }

        override fun onConnectionLost(error: Exception) {
            reset()
            Log.e(TAG, "Lost $name: ${error.message}")
            updateStatus(connectionSummary())
            restartDiscovery()
        }

        /**
         * Redial the known host after a failed connect.
         *
         * A refused dial — the computer's app quitting or relaunching, the
         * computer waking up — was otherwise the end of it: Bonjour does not
         * report a service it has already found. Known-host and discovery dials
         * often fail together; cancelling first keeps it to one pending retry.
         *
         * ponytail: fixed delay, no backoff. With a computer off this network
         * that is a dial every ~15 s (10 s connect timeout + delay) per computer;
         * add backoff if it shows up in battery use.
         */
        private fun scheduleRetry() {
            retryJob?.cancel()
            retryJob = scope.launch {
                delay(RETRY_DELAY_MS)
                if (isServiceRunning && !connected) dial()
            }
        }
    }

    private fun updateStatus(text: String) {
        statusText = text
        onStatusChanged?.invoke(text)
        if (!isServiceRunning) return
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        manager.notify(NOTIFICATION_ID, createNotification(text))
    }

    inner class LocalBinder : Binder() {
        fun getService(): BridgService = this@BridgService
    }

    companion object {
        private const val TAG = "BridgService"
        private const val NOTIFICATION_ID = 1
        private const val RETRY_DELAY_MS = 5_000L

        /** Same pattern as [BridgNotificationListenerService.instance]: lets an
         *  independently-lifecycled system service find us without a bind. */
        var instance: BridgService? = null
            private set

        const val ACTION_START = "com.bridg.action.START"
        const val ACTION_STOP = "com.bridg.action.STOP"
        const val ACTION_PAIR = "com.bridg.action.PAIR"
        const val ACTION_START_CAPTURE = "com.bridg.action.START_CAPTURE"
        const val ACTION_SEND_FILE = "com.bridg.action.SEND_FILE"
        const val ACTION_DISCONNECT = "com.bridg.action.DISCONNECT"

        const val EXTRA_MEDIA_PROJECTION = "media_projection"
        const val EXTRA_FILE_PATH = "file_path"
        const val EXTRA_FILE_URI = "file_uri"
        const val EXTRA_PEER_PUBKEY = "peer_pubkey"
        const val EXTRA_PEER_NAME = "peer_name"
        const val EXTRA_PEER_HOST = "peer_host"
        const val DEFAULT_PORT = 18920
        const val EXTRA_PAIRING_TOKEN = "pairing_token"
        /** Paired device id of the computer a shared file goes to. */
        const val EXTRA_HUB_ID = "hub_id"
    }
}
