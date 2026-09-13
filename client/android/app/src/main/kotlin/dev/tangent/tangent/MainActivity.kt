package dev.tangent.tangent

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val channelName = "dev.tangent.tangent/storage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasManageAllFiles" -> result.success(hasManageAllFiles())
                    "openManageAllFilesSettings" -> {
                        openManageAllFilesSettings()
                        result.success(null)
                    }
                    "getPublicDocumentsPath" -> {
                        // /storage/emulated/0/Documents is the public Documents folder.
                        // Path: Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
                        // but we want a raw path string for Dart's File.
                        val docs = Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_DOCUMENTS
                        )
                        result.success(docs?.absolutePath)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasManageAllFiles(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            // On Android 10 and below, WRITE_EXTERNAL_STORAGE is granted at install.
            // We can't query it directly from Dart so just return true; the probe
            // will fail in Dart if it's actually missing.
            true
        }
    }

    private fun openManageAllFilesSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                intent.data = Uri.parse("package:$packageName")
                startActivity(intent)
            } catch (_: Exception) {
                // Some OEMs have a different path; fall back to generic storage settings.
                try {
                    startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                } catch (_: Exception) {
                    // Last resort: general app settings
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                    })
                }
            }
        }
    }
}
