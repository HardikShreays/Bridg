package com.bridg.input

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.os.Build
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo
import com.bridg.proto.InputEvent

/**
 * AccessibilityService that receives input events from Mac and injects them
 * into the Android UI via gesture dispatch and global actions.
 *
 * The user must manually enable this in Settings > Accessibility > Bridg.
 */
class BridgAccessibilityService : AccessibilityService() {

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Not used — we only need this service for gesture dispatch
    }

    override fun onInterrupt() {
        Log.i(TAG, "Accessibility service interrupted")
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "Accessibility service connected")
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
        Log.i(TAG, "Accessibility service destroyed")
    }

    /**
     * Dispatch an input event received from the Mac.
     */
    fun dispatchInputEvent(event: InputEvent) {
        when (event.type) {
            InputEvent.EventType.TAP -> dispatchTap(event.x, event.y)
            InputEvent.EventType.DOUBLE_TAP -> {
                dispatchTap(event.x, event.y)
                dispatchTap(event.x, event.y)
            }
            InputEvent.EventType.LONG_PRESS -> dispatchLongPress(event.x, event.y)
            InputEvent.EventType.SWIPE -> dispatchSwipe(event.x, event.y, event.x2, event.y2)
            InputEvent.EventType.KEY_DOWN, InputEvent.EventType.KEY_UP -> {
                // Handled via performGlobalAction or node manipulation
            }
            InputEvent.EventType.TEXT_INPUT -> dispatchTextInput(event.text)
            InputEvent.EventType.BACK -> performGlobalAction(GLOBAL_ACTION_BACK)
            InputEvent.EventType.HOME -> performGlobalAction(GLOBAL_ACTION_HOME)
            InputEvent.EventType.RECENTS -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            InputEvent.EventType.VOLUME_UP -> {
                val intent = Intent("android.intent.action.MEDIA_BUTTON")
                // Volume key events handled via shell command fallback
            }
            InputEvent.EventType.VOLUME_DOWN -> {
                // Same as above
            }
            else -> Log.w(TAG, "Unhandled event type: ${event.type}")
        }
    }

    /**
     * Press the headset-hook key: answers a ringing call, or hangs up an
     * active one — the fallback used when Bridg lacks the ANSWER_PHONE_CALLS
     * runtime permission. Requires API 30+.
     */
    fun pressHeadsetHook() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            performGlobalAction(GLOBAL_ACTION_KEYCODE_HEADSETHOOK)
        } else {
            Log.w(TAG, "Headset-hook global action needs API 30+")
        }
    }

    private fun dispatchTap(normalizedX: Float, normalizedY: Float) {
        val (x, y) = screenCoords(normalizedX, normalizedY)
        val path = android.graphics.Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, TAP_DURATION_MS))
            .build()
        dispatchGesture(gesture, null, null)
    }

    private fun dispatchLongPress(normalizedX: Float, normalizedY: Float) {
        val (x, y) = screenCoords(normalizedX, normalizedY)
        val path = android.graphics.Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, LONG_PRESS_DURATION_MS))
            .build()
        dispatchGesture(gesture, null, null)
    }

    private fun dispatchSwipe(
        startX: Float, startY: Float,
        endX: Float, endY: Float
    ) {
        val (sx, sy) = screenCoords(startX, startY)
        val (ex, ey) = screenCoords(endX, endY)
        val path = android.graphics.Path().apply {
            moveTo(sx, sy)
            lineTo(ex, ey)
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, SWIPE_DURATION_MS))
            .build()
        dispatchGesture(gesture, null, null)
    }

    private fun dispatchTextInput(text: String) {
        // Try to set text on the currently focused node
        val focusedNode = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (focusedNode != null && focusedNode.isEditable) {
            val args = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            }
            focusedNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        } else {
            // Fallback: use clipboard to paste text
            val clipboard = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
            val clip = android.content.ClipData.newPlainText("bridg_input", text)
            clipboard.setPrimaryClip(clip)
            performGlobalAction(17 /* GLOBAL_ACTION_PASTE, API 33+ */)
        }
    }

    /**
     * Map a 0..1 coordinate from the Mac onto real screen pixels.
     *
     * `resources.displayMetrics` reports the app-usable area, which on most
     * OEM builds excludes the navigation bar / gesture pill — so y=1.0 landed
     * above the bottom of the screen and the lowest row (nav pill, keyboard
     * bottom row, pull-up handles) was unreachable from the mirror. The real
     * display bounds include the system bars.
     */
    private fun screenCoords(normalizedX: Float, normalizedY: Float): Pair<Float, Float> {
        val (w, h) = realDisplaySize()
        // A point exactly on the far edge (normalized 1.0) is off-screen and
        // dispatchGesture() rejects the whole stroke — keep it just inside.
        val x = (normalizedX * w).coerceIn(0f, w - 1f)
        val y = (normalizedY * h).coerceIn(0f, h - 1f)
        return Pair(x, y)
    }

    private fun realDisplaySize(): Pair<Int, Int> {
        val wm = getSystemService(WINDOW_SERVICE) as android.view.WindowManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = wm.currentWindowMetrics.bounds
            Pair(b.width(), b.height())
        } else {
            val p = android.graphics.Point()
            @Suppress("DEPRECATION") wm.defaultDisplay.getRealSize(p)
            Pair(p.x, p.y)
        }
    }

    companion object {
        private const val TAG = "BridgAccessibility"
        private const val TAP_DURATION_MS = 50L
        private const val LONG_PRESS_DURATION_MS = 1000L
        private const val SWIPE_DURATION_MS = 300L

        var instance: BridgAccessibilityService? = null
            private set

        fun isRunning(): Boolean = instance != null
    }
}
