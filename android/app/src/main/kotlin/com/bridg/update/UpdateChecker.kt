package com.bridg.update

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.net.URL

/**
 * "Check for updates": asks GitHub for the latest release, downloads its APK
 * and hands it to the system installer.
 *
 * The installer only accepts an APK signed with the same key as the installed
 * app, so a debug build can't update itself to a release build (or back).
 */
object UpdateChecker {

    private const val LATEST = "https://api.github.com/repos/HardikShreays/Bridg/releases/latest"

    fun check(activity: Activity) {
        Toast.makeText(activity, "Checking for updates…", Toast.LENGTH_SHORT).show()
        Thread {
            val result = runCatching {
                val json = JSONObject(URL(LATEST).readText())
                val tag = json.getString("tag_name").removePrefix("v")
                val assets = json.getJSONArray("assets")
                val apk = (0 until assets.length()).map { assets.getJSONObject(it) }
                    .firstOrNull { it.getString("name").endsWith(".apk") }
                    ?.getString("browser_download_url")
                tag to apk
            }
            activity.runOnUiThread {
                if (activity.isFinishing) return@runOnUiThread
                val (tag, apk) = result.getOrElse {
                    Toast.makeText(activity, "Couldn't check for updates", Toast.LENGTH_SHORT).show()
                    return@runOnUiThread
                }
                val current = activity.packageManager.getPackageInfo(activity.packageName, 0).versionName ?: "0"
                if (apk == null || !isNewer(tag, current)) {
                    Toast.makeText(activity, "Bridg $current is up to date", Toast.LENGTH_SHORT).show()
                    return@runOnUiThread
                }
                AlertDialog.Builder(activity)
                    .setTitle("Bridg $tag is available")
                    .setMessage("You have $current. Download and install the update?")
                    .setPositiveButton("Update") { _, _ -> download(activity, apk) }
                    .setNegativeButton("Later", null)
                    .show()
            }
        }.start()
    }

    private fun download(activity: Activity, url: String) {
        // Android 8+ asks per app; send the user to the toggle and let them retry.
        if (!activity.packageManager.canRequestPackageInstalls()) {
            Toast.makeText(activity, "Allow Bridg to install updates, then try again", Toast.LENGTH_LONG).show()
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
            )
            return
        }
        Toast.makeText(activity, "Downloading update…", Toast.LENGTH_SHORT).show()
        Thread {
            val file = File(activity.cacheDir, "shared/update.apk")
            val ok = runCatching {
                file.parentFile?.mkdirs()
                URL(url).openStream().use { input -> file.outputStream().use { input.copyTo(it) } }
            }.isSuccess
            activity.runOnUiThread {
                if (!ok) {
                    Toast.makeText(activity, "Update download failed", Toast.LENGTH_SHORT).show()
                    return@runOnUiThread
                }
                val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", file)
                activity.startActivity(
                    Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
        }.start()
    }

    /** "0.10.0" > "0.9.3": compare numerically, part by part; missing parts count as 0. */
    fun isNewer(latest: String, current: String): Boolean {
        val a = latest.split('.').map { it.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }
        val b = current.split('.').map { it.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(a.size, b.size)) {
            val d = a.getOrElse(i) { 0 } - b.getOrElse(i) { 0 }
            if (d != 0) return d > 0
        }
        return false
    }
}
