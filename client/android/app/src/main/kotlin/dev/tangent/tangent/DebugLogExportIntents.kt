// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File

/**
 * Android email/share intents for the debug log export.
 *
 * The attachment is always a FileProvider content URI rooted in the app's
 * private cache. No file:// URI and no storage permission ever leaves Tangent.
 */
class DebugLogExportIntents(private val activity: Activity) {
    fun sendAttachedEmail(arguments: Any?): Boolean {
        val args = stringArguments(arguments) ?: return false
        val file = allowedLogFile(args["filePath"]) ?: return false
        val recipient = args["recipient"] ?: return false
        val subject = args["subject"] ?: return false
        val body = args["body"] ?: return false
        val uri = contentUri(file)

        // ACTION_SEND itself matches every share target. Probe ACTION_SENDTO
        // mailto: first, then constrain attachment intents to actual email apps
        // so the chooser normally lands in an addressed composer.
        val emailProbe = Intent(
            Intent.ACTION_SENDTO,
            Uri.Builder().scheme("mailto").opaquePart(recipient).build(),
        )
        val packages = activity.packageManager
            .queryIntentActivities(emailProbe, 0)
            .map { it.activityInfo.packageName }
            .distinct()
        val candidates = packages.mapNotNull { packageName ->
            attachedIntent(uri, recipient, subject, body).apply {
                setPackage(packageName)
            }.takeIf { it.resolveActivity(activity.packageManager) != null }
        }
        if (candidates.isEmpty()) return false

        val chooser = Intent.createChooser(candidates.first(), "Send Tangent debug logs")
        if (candidates.size > 1) {
            chooser.putExtra(
                Intent.EXTRA_INITIAL_INTENTS,
                candidates.drop(1).take(2).toTypedArray(),
            )
        }
        return start(chooser)
    }

    fun openMailto(arguments: Any?): Boolean {
        val value = stringArguments(arguments)?.get("uri") ?: return false
        val uri = runCatching { Uri.parse(value) }.getOrNull() ?: return false
        if (uri.scheme != "mailto") return false
        val intent = Intent(Intent.ACTION_SENDTO, uri)
        if (intent.resolveActivity(activity.packageManager) == null) return false
        return start(intent)
    }

    fun shareFile(arguments: Any?): Boolean {
        val args = stringArguments(arguments) ?: return false
        val file = allowedLogFile(args["filePath"]) ?: return false
        val uri = contentUri(file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newUri(activity.contentResolver, "Tangent debug logs", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (intent.resolveActivity(activity.packageManager) == null) return false
        return start(Intent.createChooser(intent, "Share Tangent debug logs"))
    }

    private fun attachedIntent(
        uri: Uri,
        recipient: String,
        subject: String,
        body: String,
    ) = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_EMAIL, arrayOf(recipient))
        putExtra(Intent.EXTRA_SUBJECT, subject)
        putExtra(Intent.EXTRA_TEXT, body)
        putExtra(Intent.EXTRA_STREAM, uri)
        clipData = ClipData.newUri(activity.contentResolver, "Tangent debug logs", uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    private fun allowedLogFile(path: String?): File? {
        if (path == null) return null
        val root = File(activity.cacheDir, "debug_logs").canonicalFile
        val candidate = runCatching { File(path).canonicalFile }.getOrNull() ?: return null
        val insideRoot = candidate.path.startsWith("${root.path}${File.separator}")
        return candidate.takeIf {
            insideRoot && it.isFile && it.extension.equals("txt", ignoreCase = true)
        }
    }

    private fun contentUri(file: File): Uri = FileProvider.getUriForFile(
        activity,
        "${activity.packageName}.debug_logs",
        file,
    )

    private fun start(intent: Intent): Boolean = try {
        activity.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }

    private fun stringArguments(arguments: Any?): Map<String, String>? {
        val raw = arguments as? Map<*, *> ?: return null
        return raw.entries.mapNotNull { (key, value) ->
            if (key is String && value is String) key to value else null
        }.toMap()
    }
}
