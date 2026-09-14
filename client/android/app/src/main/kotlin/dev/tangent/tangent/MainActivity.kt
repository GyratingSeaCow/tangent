package dev.tangent.tangent

import android.app.Activity
import android.content.Intent
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
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
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets

class MainActivity : FlutterActivity() {
    private val channelName = "dev.tangent.tangent/storage"
    private val audioChannelName = "dev.tangent.tangent/audio"
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, audioChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "decodeOpusToWav" -> runIo(result, "audio_decode") {
                        val inputPath = requiredArgument(
                            call.argument<String>("inputPath"),
                            "inputPath",
                        )
                        val outputPath = requiredArgument(
                            call.argument<String>("outputPath"),
                            "outputPath",
                        )
                        decodeOpusToWav(inputPath, outputPath)
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

    private fun decodeOpusToWav(inputPath: String, outputPath: String): Map<String, Any> {
        val input = File(inputPath)
        val output = File(outputPath)
        if (!input.isFile || input.length() <= 0L) {
            throw IllegalStateException("Opus input is missing or empty")
        }
        output.parentFile?.mkdirs()
        output.delete()

        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var codecStarted = false
        var wav: RandomAccessFile? = null
        var completed = false
        try {
            extractor.setDataSource(input.absolutePath)
            var trackIndex = -1
            var inputFormat: MediaFormat? = null
            for (index in 0 until extractor.trackCount) {
                val candidate = extractor.getTrackFormat(index)
                val mime = candidate.getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith("audio/") == true) {
                    trackIndex = index
                    inputFormat = candidate
                    break
                }
            }
            if (trackIndex < 0 || inputFormat == null) {
                throw IllegalStateException("Recording contains no decodable audio track")
            }
            val mime = inputFormat.getString(MediaFormat.KEY_MIME)
                ?: throw IllegalStateException("Recording audio MIME type is missing")
            extractor.selectTrack(trackIndex)
            inputFormat.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(inputFormat, null, null, 0)
            codec.start()
            codecStarted = true

            wav = RandomAccessFile(output, "rw")
            wav.setLength(0)
            wav.write(ByteArray(44))

            var sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT
            var pcmBytes = 0L
            var inputEnded = false
            var outputEnded = false
            val info = MediaCodec.BufferInfo()
            var lastProgress = android.os.SystemClock.elapsedRealtime()

            while (!outputEnded) {
                if (!inputEnded) {
                    val inputIndex = codec.dequeueInputBuffer(10_000)
                    if (inputIndex >= 0) {
                        val buffer = codec.getInputBuffer(inputIndex)
                            ?: throw IllegalStateException("Decoder input buffer was unavailable")
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputEnded = true
                        } else {
                            codec.queueInputBuffer(
                                inputIndex,
                                0,
                                size,
                                extractor.sampleTime,
                                0,
                            )
                            extractor.advance()
                        }
                        lastProgress = android.os.SystemClock.elapsedRealtime()
                    }
                }

                when (val outputIndex = codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val decodedFormat = codec.outputFormat
                        sampleRate = decodedFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = decodedFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        if (decodedFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                            pcmEncoding = decodedFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        }
                        if (pcmEncoding != AudioFormat.ENCODING_PCM_16BIT) {
                            throw IllegalStateException(
                                "Android decoder returned unsupported PCM encoding $pcmEncoding",
                            )
                        }
                        lastProgress = android.os.SystemClock.elapsedRealtime()
                    }
                    MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (android.os.SystemClock.elapsedRealtime() - lastProgress > 30_000L) {
                            throw IllegalStateException("Android audio decoder made no progress for 30 seconds")
                        }
                    }
                    else -> if (outputIndex >= 0) {
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            val buffer = codec.getOutputBuffer(outputIndex)
                                ?: throw IllegalStateException("Decoder output buffer was unavailable")
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            val chunk = ByteArray(info.size)
                            buffer.get(chunk)
                            wav.write(chunk)
                            pcmBytes += chunk.size
                        }
                        outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        codec.releaseOutputBuffer(outputIndex, false)
                        lastProgress = android.os.SystemClock.elapsedRealtime()
                    }
                }
            }

            if (sampleRate <= 0 || channels <= 0 || pcmBytes <= 0L) {
                throw IllegalStateException("Android decoder produced no PCM audio")
            }
            wav.seek(0)
            wav.write(wavHeader(pcmBytes, sampleRate, channels))
            wav.fd.sync()
            completed = true
            return mapOf(
                "sampleRate" to sampleRate,
                "channels" to channels,
                "pcmBytes" to pcmBytes,
            )
        } finally {
            try {
                wav?.close()
            } finally {
                if (codecStarted) {
                    try {
                        codec?.stop()
                    } catch (_: Exception) {
                        // Release below even if the codec has already stopped itself.
                    }
                }
                codec?.release()
                extractor.release()
                if (!completed) output.delete()
            }
        }
    }

    private fun wavHeader(dataBytes: Long, sampleRate: Int, channels: Int): ByteArray {
        if (dataBytes > 0xffffffffL - 36L) {
            throw IllegalStateException("Decoded WAV exceeds the RIFF 4 GiB limit")
        }
        val byteRate = sampleRate * channels * 2
        return ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray(StandardCharsets.US_ASCII))
            putInt((36L + dataBytes).toInt())
            put("WAVE".toByteArray(StandardCharsets.US_ASCII))
            put("fmt ".toByteArray(StandardCharsets.US_ASCII))
            putInt(16)
            putShort(1.toShort())
            putShort(channels.toShort())
            putInt(sampleRate)
            putInt(byteRate)
            putShort((channels * 2).toShort())
            putShort(16.toShort())
            put("data".toByteArray(StandardCharsets.US_ASCII))
            putInt(dataBytes.toInt())
        }.array()
    }

    private fun <T> requiredArgument(value: T?, name: String): T =
        value ?: throw IllegalArgumentException("Missing $name")

    private fun runIo(
        result: MethodChannel.Result,
        errorCode: String = "storage_io",
        operation: () -> Any?,
    ) {
        Thread {
            try {
                val value = operation()
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread { result.error(errorCode, error.message, null) }
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
