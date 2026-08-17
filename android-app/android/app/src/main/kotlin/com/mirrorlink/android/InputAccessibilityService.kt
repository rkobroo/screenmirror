package com.mirrorlink.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Path
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.KeyEvent
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject

/**
 * Injects remote input received over the WebRTC `control` channel into the
 * Android UI. Requires the user to enable the service in
 * Settings → Accessibility.
 *
 * Handles: tap / swipe / scroll / key events / text / back-home-recents /
 * volume / media keys (docs/PROTOCOL.md §6).
 */
class InputAccessibilityService : AccessibilityService() {

    companion object {
        /** Current service instance while enabled, else null. */
        var instance: InputAccessibilityService? = null
            private set

        /** Whether the service is enabled (readable without an instance). */
        fun isEnabled(context: Context): Boolean {
            val expected = "com.mirrorlink.android/.InputAccessibilityService"
            val value = android.provider.Settings.Secure.getString(
                context.contentResolver,
                android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: return false
            return value.split(':').any { it.equals(expected, ignoreCase = true) }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onServiceConnected() {
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    /**
     * Dispatch a single inbound control message. Coordinates are normalized
     * 0..1 (landscape-relative) per the protocol.
     */
    fun handle(json: JSONObject) {
        when (json.optString("kind")) {
            "touch" -> injectTouch(
                json.optDouble("x", 0.5).toFloat(),
                json.optDouble("y", 0.5).toFloat(),
                json.optInt("action", 0),
            )
            "swipe" -> injectSwipe(json)
            "scroll" -> injectScroll(
                json.optDouble("dx", 0.0).toFloat(),
                json.optDouble("dy", -120.0).toFloat(),
            )
            "key" -> injectKey(json.optInt("code", 0), json.optInt("action", 0))
            "text" -> injectText(json.optString("value"))
            "sys" -> performGlobalAction(
                when (json.optString("button")) {
                    "home" -> GLOBAL_ACTION_HOME
                    "back" -> GLOBAL_ACTION_BACK
                    "recents" -> GLOBAL_ACTION_RECENTS
                    else -> return
                },
            )
            "volume" -> injectVolume(
                when (json.optString("dir")) {
                    "up" -> KeyEvent.KEYCODE_VOLUME_UP
                    "down" -> KeyEvent.KEYCODE_VOLUME_DOWN
                    else -> KeyEvent.KEYCODE_VOLUME_MUTE
                },
            )
            "media" -> injectMedia(json.optString("action"))
        }
    }

    private fun toPixels(nx: Double, ny: Double): Pair<Int, Int> {
        val metrics = DisplayMetrics()
        (getSystemService(WINDOW_SERVICE) as WindowManager)
            .defaultDisplay.getRealMetrics(metrics)
        val x = (normalizedX(nx, metrics) * metrics.widthPixels).toInt()
        val y = (normalizedY(ny, metrics) * metrics.heightPixels).toInt()
        return x to y
    }

    private fun normalizedX(v: Double, metrics: DisplayMetrics): Double {
        // Normalized coords are expressed against a portrait-ish phone space;
        // map the smaller display dimension onto the normalized x axis.
        return if (metrics.widthPixels <= metrics.heightPixels) {
            v
        } else {
            v * metrics.widthPixels.toDouble() / metrics.heightPixels.toDouble()
        }
    }

    private fun normalizedY(v: Double, metrics: DisplayMetrics): Double {
        return if (metrics.widthPixels <= metrics.heightPixels) {
            v
        } else {
            v * metrics.heightPixels.toDouble() / metrics.widthPixels.toDouble()
        }
    }

    private fun injectTouch(x: Float, y: Float, action: Int) {
        val (px, py) = toPixels(x.toDouble(), y.toDouble())

        val path = Path()
        path.moveTo(px.toFloat(), py.toFloat())

        val description = GestureDescription.Builder()
            .addStroke(
                GestureDescription.StrokeDescription(path, 0, if (action == 2) 50 else 1),
            )
            .build()
        dispatchGesture(description, null, mainHandler)
    }

    private fun injectSwipe(json: JSONObject) {
        val points = json.optJSONArray("points") ?: return
        if (points.length() < 2) return
        val duration = json.optLong("duration", 150)

        val path = Path()
        val first = points.optJSONObject(0) ?: return
        val (sx, sy) = toPixels(first.optDouble("x"), first.optDouble("y"))
        path.moveTo(sx.toFloat(), sy.toFloat())
        for (i in 1 until points.length()) {
            val p = points.optJSONObject(i) ?: continue
            val (x, y) = toPixels(p.optDouble("x"), p.optDouble("y"))
            path.lineTo(x.toFloat(), y.toFloat())
        }

        val description = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
            .build()
        dispatchGesture(description, null, mainHandler)
    }

    private fun injectScroll(dx: Float, dy: Float) {
        // AccessibilityService has no direct scroll event; emulate a two-finger
        // drag which most apps interpret as a scroll.
        val metrics = DisplayMetrics()
        (getSystemService(WINDOW_SERVICE) as WindowManager)
            .defaultDisplay.getRealMetrics(metrics)

        val cx = metrics.widthPixels / 2f
        val cy = metrics.heightPixels / 2f
        val dxPx = dx
        val dyPx = dy

        val path = Path()
        path.moveTo(cx - dxPx, cy - dyPx)
        path.lineTo(cx + dxPx, cy + dyPx)

        val description = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 120))
            .build()
        dispatchGesture(description, null, mainHandler)
    }

    private fun injectKey(code: Int, action: Int) {
        if (action != KeyEvent.ACTION_DOWN) return
        when (code) {
            KeyEvent.KEYCODE_BACK -> performGlobalAction(GLOBAL_ACTION_BACK)
            KeyEvent.KEYCODE_HOME -> performGlobalAction(GLOBAL_ACTION_HOME)
            KeyEvent.KEYCODE_APP_SWITCH -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN, KeyEvent.KEYCODE_VOLUME_MUTE ->
                injectVolume(code)
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            -> dispatchMediaKey(code, action)
            // Keys that AccessibilityService can't inject as key events —
            // fall back to text injection via clipboard+paste.
            KeyEvent.KEYCODE_SPACE -> injectText(" ")
            KeyEvent.KEYCODE_ENTER -> injectText("\n")
            KeyEvent.KEYCODE_TAB -> injectText("\t")
            KeyEvent.KEYCODE_DEL -> performGlobalAction(GLOBAL_ACTION_BACK)
            else -> {
                // For letter/digit keys, the PC sends them as text already.
                // This path is reached only for unmapped key codes.
            }
        }
    }

    private fun injectVolume(code: Int) {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val direction = when (code) {
            KeyEvent.KEYCODE_VOLUME_UP -> AudioManager.ADJUST_RAISE
            KeyEvent.KEYCODE_VOLUME_DOWN -> AudioManager.ADJUST_LOWER
            else -> AudioManager.ADJUST_MUTE
        }
        audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, 0)
    }

    private fun injectMedia(action: String) {
        val code = when (action) {
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "prev" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            else -> return
        }
        dispatchMediaKey(code, KeyEvent.ACTION_DOWN)
        dispatchMediaKey(code, KeyEvent.ACTION_UP)
    }

    private fun dispatchMediaKey(code: Int, action: Int) {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audio.dispatchMediaKeyEvent(KeyEvent(action, code))
    }

    /** Type arbitrary text using clipboard + paste, which handles any charset. */
    private fun injectText(value: String) {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("mirrorlink-typed", value))

        val root = rootInActiveWindow ?: return
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: root
        // Place a cursor at the end of the target field, then paste.
        val end = focused.textSelectionEnd
        if (end >= 0) {
            val args = android.os.Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, end)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
            }
            focused.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
        }
        focused.performAction(AccessibilityNodeInfo.ACTION_PASTE)
    }
}
