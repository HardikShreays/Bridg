package com.bridg.ui

import android.app.Activity
import android.os.Bundle
import android.util.Log
import com.bridg.service.BridgService

/**
 * Invisible, no-UI activity whose only job is to briefly hold window focus.
 *
 * Since Android 10 an app can only read the clipboard while it owns the
 * foreground window, so the background service's change listener always got
 * `null` and the phone→Mac direction never synced. Launched from the ongoing
 * notification's "Send clipboard" action, this activity comes up transparent,
 * reads the clipboard the moment it gains focus, and finishes immediately —
 * the user sees nothing.
 */
class ClipboardBridgeActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            Log.i("ClipboardBridge", "Focus gained — pushing clipboard to Mac")
            BridgService.instance?.syncClipboardNow()
            finish()
            overridePendingTransition(0, 0)
        }
    }
}
