package dev.tangent.tangent

import android.app.Activity
import android.content.Intent
import android.net.Uri

import android.provider.DocumentsContract
import android.view.WindowManager
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "dev.tangent.tangent/storage"
    private val requestTree = 7301
    private val preferencesName = "tangent_storage"
    private val treeUriKey = "recordings_tree_uri"
    private var pendingTreeResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasStorageAccess" -> result.success(hasStorageAccess())
                    "chooseStorageFolder" -> chooseStorageFolder(result)
                    "persistRecording" -> runIo(result) {
                        val id = requiredArgument(call.argument<String>("id"), "id")
                        val source = requiredArgument(call.argument<String>("sourcePath"), "sourcePath")
                        val metadata = requiredArgument(call.argument<String>("metadataJson"), "metadataJson")
                        persistRecording(id, source, metadata)
                    }
                    "writeMetadata" -> runIo(result) {
                        val id = requiredArgument(call.argument<String>("id"), "id")
                        val metadata = requiredArgument(call.argument<String>("metadataJson"), "metadataJson")
                        writeDocumentAtomically("$id.meta.json", "application/json", metadata.toByteArray())
                        null
                    }
                    "readAudio" -> runIo(result) {
                        val id = requiredArgument(call.argument<String>("id"), "id")
                        val document = tangentDirectory().findFile("$id.opus")
                            ?: throw IllegalStateException("Recording $id is missing")
                        contentResolver.openInputStream(document.uri)?.use { it.readBytes() }
                            ?: throw IllegalStateException("Could not read recording $id")
                    }
                    "listRecordings" -> runIo(result) { listRecordings() }
                    "deleteRecording" -> runIo(result) {
                        val id = requiredArgument(call.argument<String>("id"), "id")
                        tangentDirectory().findFile("$id.opus")?.delete()
                        tangentDirectory().findFile("$id.meta.json")?.delete()
                        null
                    }
                    "setKeepScreenAwake" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun chooseStorageFolder(result: MethodChannel.Result) {
        if (pendingTreeResult != null) {
            result.error("picker_active", "A recording-folder picker is already open", null)
            return
        }
        pendingTreeResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    Uri.parse("content://com.android.externalstorage.documents/document/primary%3ADocuments")
                )
            }
        }
        startActivityForResult(intent, requestTree)
    }

    @Deprecated("Deprecated in Android; FlutterActivity still dispatches this callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != requestTree) return
        val pending = pendingTreeResult ?: return
        pendingTreeResult = null
        val selected = data?.data
        if (resultCode != Activity.RESULT_OK || selected == null) {
            pending.success(false)
            return
        }
        try {
            val flags = data.flags and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(selected, flags)
            val selectedDoc = DocumentFile.fromTreeUri(this, selected)
                ?: throw IllegalStateException("Selected folder is unavailable")
            if (!selectedDoc.canRead() || !selectedDoc.canWrite()) {
                throw IllegalStateException("Selected folder is not writable")
            }
            if (!selectedDoc.name.equals("Documents", ignoreCase = true) &&
                !selectedDoc.name.equals("Tangent", ignoreCase = true)) {
                throw IllegalStateException("Choose Documents or the existing Tangent folder")
            }
            val tangent = if (selectedDoc.name.equals("Tangent", ignoreCase = true)) {
                selectedDoc
            } else {
                selectedDoc.findFile("Tangent")
                    ?: selectedDoc.createDirectory("Tangent")
                    ?: throw IllegalStateException("Could not create Tangent folder")
            }
            // Keep the actual tree URI returned by the picker. A child created with
            // createDirectory has a document URI whose tree id still points at its
            // parent, so persisting the child URI would reopen the wrong directory.
            getSharedPreferences(preferencesName, MODE_PRIVATE)
                .edit().putString(treeUriKey, selected.toString()).commit()
            // Verify now rather than accepting a grant that will fail at first recording.
            tangent.listFiles()
            pending.success(true)
        } catch (error: Exception) {
            pending.error("storage_permission", error.message, null)
        }
    }

    private fun hasStorageAccess(): Boolean {
        return try {
            val uri = configuredTreeUri() ?: return false
            val grant = contentResolver.persistedUriPermissions.any {
                (uri.toString().startsWith(it.uri.toString()) || it.uri.toString().startsWith(uri.toString())) &&
                    it.isReadPermission && it.isWritePermission
            }
            grant && tangentDirectory().canRead() && tangentDirectory().canWrite()
        } catch (_: Exception) {
            false
        }
    }

    private fun configuredTreeUri(): Uri? =
        getSharedPreferences(preferencesName, MODE_PRIVATE)
            .getString(treeUriKey, null)?.let(Uri::parse)

    private fun tangentDirectory(): DocumentFile {
        val uri = configuredTreeUri()
            ?: throw IllegalStateException("No durable recording folder is authorized")
        val selected = DocumentFile.fromTreeUri(this, uri)
            ?: throw IllegalStateException("The authorized recording folder is unavailable")
        if (selected.name.equals("Tangent", ignoreCase = true)) return selected
        return selected.findFile("Tangent")
            ?: throw IllegalStateException("Documents/Tangent is unavailable")
    }

    private fun persistRecording(id: String, sourcePath: String, metadataJson: String): Map<String, Any> {
        val source = File(sourcePath)
        if (!source.isFile || source.length() <= 0L) {
            throw IllegalStateException("Recorder output is missing or empty")
        }
        val audio = writeDocumentAtomically("$id.opus", "audio/ogg", FileInputStream(source))
        writeDocumentAtomically("$id.meta.json", "application/json", metadataJson.toByteArray())
        val confirmedSize = audio.length()
        if (confirmedSize <= 0L) throw IllegalStateException("Durable audio verification failed")
        return mapOf("uri" to audio.uri.toString(), "sizeBytes" to confirmedSize)
    }

    private fun writeDocumentAtomically(name: String, mime: String, bytes: ByteArray): DocumentFile =
        writeDocumentAtomically(name, mime, bytes.inputStream())

    private fun writeDocumentAtomically(name: String, mime: String, input: java.io.InputStream): DocumentFile {
        val directory = tangentDirectory()
        val tmpName = "$name.partial"
        directory.findFile(tmpName)?.delete()
        val tmp = directory.createFile(mime, tmpName)
            ?: throw IllegalStateException("Could not create $tmpName")
        try {
            contentResolver.openFileDescriptor(tmp.uri, "rwt")?.use { descriptor ->
                FileOutputStream(descriptor.fileDescriptor).use { output ->
                    input.use { it.copyTo(output) }
                    output.flush()
                    output.fd.sync()
                }
            } ?: throw IllegalStateException("Could not open $tmpName for writing")
            if (tmp.length() <= 0L) throw IllegalStateException("$tmpName was empty after writing")
            directory.findFile(name)?.delete()
            if (!tmp.renameTo(name)) throw IllegalStateException("Could not finalize $name")
            return directory.findFile(name)
                ?: throw IllegalStateException("Could not verify finalized $name")
        } catch (error: Exception) {
            tmp.delete()
            throw error
        }
    }

    private fun listRecordings(): List<Map<String, Any?>> {
        val directory = tangentDirectory()
        val files = directory.listFiles().associateBy { it.name }
        return files.values.filter { it.isFile && it.name?.endsWith(".opus") == true }.map { audio ->
            val name = audio.name!!
            val id = name.removeSuffix(".opus")
            val metadata = files["$id.meta.json"]?.let { meta ->
                contentResolver.openInputStream(meta.uri)?.bufferedReader()?.use { it.readText() }
            }
            mapOf(
                "id" to id,
                "uri" to audio.uri.toString(),
                "sizeBytes" to audio.length(),
                "lastModified" to audio.lastModified(),
                "metadataJson" to metadata,
            )
        }
    }

    private fun <T> requiredArgument(value: T?, name: String): T =
        value ?: throw IllegalArgumentException("Missing $name")

    private fun runIo(result: MethodChannel.Result, operation: () -> Any?) {
        Thread {
            try {
                val value = operation()
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread { result.error("storage_io", error.message, null) }
            }
        }.start()
    }

    override fun onDestroy() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        pendingTreeResult?.error("activity_destroyed", "Folder picker was interrupted", null)
        pendingTreeResult = null
        super.onDestroy()
    }
}
