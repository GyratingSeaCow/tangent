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

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import dev.tangent.tangent.storage.AndroidDocumentsPort
import dev.tangent.tangent.storage.NativeIoSupervisor
import dev.tangent.tangent.storage.NativeStorageException
import dev.tangent.tangent.audio.AndroidCommunicationDevices
import dev.tangent.tangent.audio.CommunicationRouting
import dev.tangent.tangent.storage.StorageChannel
import dev.tangent.tangent.storage.CandidatePicker
import dev.tangent.tangent.storage.StorageMethodRouter
import dev.tangent.tangent.storage.StorageReply
import dev.tangent.tangent.widget.WidgetLaunchIntents

class MainActivity : FlutterActivity() {
    private val channelName = "dev.tangent.tangent/storage"
    private val audioChannelName = "dev.tangent.tangent/audio"
    private val launchChannelName = "dev.tangent.tangent/launch"

    /** Widget-tap notebook waiting for the Dart side to ask (cold start),
     *  and the channel to push through when the app is already alive. */
    private var pendingLaunchNotebook: String? = null
    private var launchChannel: MethodChannel? = null
    private val requestTree = 7301
    private val requestAudioFile = 7302
    private val requestImageFile = 7303
    private val requestAudioFiles = 7304

    /** Pending reply for the multi-select audio picker (bulk import). */
    private var pendingAudioFilesResult: MethodChannel.Result? = null
    private var storageOwner: StorageChannel? = null
    private val communicationRouting by lazy {
        CommunicationRouting(AndroidCommunicationDevices(this))
    }
    private val documentsPort by lazy { AndroidDocumentsPort(applicationContext) }
    private val candidatePicker by lazy {
        CandidatePicker<Uri>(
            launch = ::pickDirectory,
            takeGrant = { selected, flags -> contentResolver.takePersistableUriPermission(selected, flags) },
            candidate = { selected -> documentsPort.picked(selected) },
            grantMask = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
    }
    /// Picks one audio file and copies it into app-private cache.
    ///
    /// The import copies from cache rather than reading the content:// URI
    /// directly, so the file is fully ours before anything is catalogued and
    /// a transient permission grant cannot vanish mid-import.
    private val audioFilePicker by lazy {
        CandidatePicker<Uri>(
            launch = ::pickAudioFile,
            takeGrant = { _, _ -> },
            candidate = { selected -> copyIntoCache(selected) },
            grantMask = Intent.FLAG_GRANT_READ_URI_PERMISSION,
        )
    }
    /// Picks one image and returns its bytes plus intrinsic size.
    ///
    /// The bytes come back over the channel directly (no cache file): the
    /// notebook stores images inline, so a path would only add a second
    /// copy to clean up. Oversized images are downscaled to keep one photo
    /// from ballooning the notebook document.
    private val imageFilePicker by lazy {
        CandidatePicker<Uri>(
            launch = ::pickImageFile,
            takeGrant = { _, _ -> },
            candidate = { selected -> readImageBytes(selected) },
            grantMask = Intent.FLAG_GRANT_READ_URI_PERMISSION,
        )
    }
    private val storageRouter by lazy {
        StorageMethodRouter(candidatePicker::start, { enabled ->
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }) { method, args ->
            // Resolve the live owner on every call, including after engine replacement.
            val owner = storageOwner ?: throw NativeStorageException("unavailable", "Storage channel detached")
            owner.handle(method, args)
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // A widget tap that cold-starts the app: the id waits here until
        // Dart calls takeLaunchNotebook (the engine isn't up yet).
        pendingLaunchNotebook =
            WidgetLaunchIntents.notebookId(intent?.action, intent?.dataString)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Warm tap: the activity is singleTop, so the running instance
        // gets the intent; push straight to Dart.
        val id = WidgetLaunchIntents.notebookId(intent.action, intent.dataString)
        if (id != null) {
            val channel = launchChannel
            if (channel != null) {
                channel.invokeMethod("openNotebook", id)
            } else {
                pendingLaunchNotebook = id
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        launchChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, launchChannelName)
                .also { channel ->
                    channel.setMethodCallHandler { call, result ->
                        when (call.method) {
                            "takeLaunchNotebook" -> {
                                // Read-once: a hot restart must not reopen it.
                                result.success(pendingLaunchNotebook)
                                pendingLaunchNotebook = null
                            }
                            else -> result.notImplemented()
                        }
                    }
                }
        storageOwner?.detach()
        storageOwner = StorageChannel(NativeIoSupervisor.process, documentsPort::execute)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                storageRouter.handle(call.method, call.arguments, object : StorageReply {
                    override fun success(value: Any?) = result.success(value)
                    override fun error(code: String, message: String?) = result.error(code, message, null)
                    override fun notImplemented() = result.notImplemented()
                })
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, audioChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickAudioFiles" -> {
                        if (pendingAudioFilesResult != null) {
                            result.error("picker_active", "A file picker is already open", null)
                        } else {
                            pendingAudioFilesResult = result
                            pickAudioFiles()
                        }
                    }
                    "pickAudioFile" -> audioFilePicker.start(object : StorageReply {
                        override fun success(value: Any?) = result.success(value)
                        override fun error(code: String, message: String?) = result.error(code, message, null)
                        override fun notImplemented() = result.notImplemented()
                    })
                    "pickImageFile" -> imageFilePicker.start(object : StorageReply {
                        override fun success(value: Any?) = result.success(value)
                        override fun error(code: String, message: String?) = result.error(code, message, null)
                        override fun notImplemented() = result.notImplemented()
                    })
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
                    // Route capture to a Bluetooth headset mic. The `record`
                    // plugin drives the deprecated startBluetoothSco() pair,
                    // which does not bring SCO up on this hardware, so the
                    // modern setCommunicationDevice() path lives here.
                    //
                    // Never throws to Dart: a headset that is off or refused
                    // must not block a recording. The state string tells the
                    // caller what happened so it can report honestly.
                    "routeCommunicationDevice" -> {
                        val deviceId = call.argument<Int>("deviceId")
                        if (deviceId == null) {
                            result.success(mapOf("state" to "notApplicable"))
                        } else {
                            val outcome = communicationRouting.route(deviceId)
                            result.success(
                                mapOf(
                                    "state" to outcome.state.name.lowercase(),
                                    "label" to outcome.device?.label,
                                ),
                            )
                        }
                    }
                    "routeCommunicationDeviceAuto" -> {
                        val outcome = communicationRouting.routeAuto()
                        result.success(
                            mapOf(
                                "state" to outcome.state.name.lowercase(),
                                "label" to outcome.device?.label,
                            ),
                        )
                    }
                    "clearCommunicationDevice" -> {
                        communicationRouting.clear()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickAudioFile() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "audio/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("audio/*", "video/mp4", "application/ogg"),
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, requestAudioFile)
    }

    /** Multi-select variant for the Settings bulk import. */
    private fun pickAudioFiles() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "audio/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("audio/*", "video/mp4", "application/ogg"),
            )
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, requestAudioFiles)
    }

    /** Copies every selected document into cache, skipping unreadable ones.
     *  Selected-but-broken files surface on the Dart side as absent entries;
     *  the bulk importer reports per-file failures for everything it DID get. */
    private fun completeAudioFiles(resultCode: Int, data: Intent?) {
        val pending = pendingAudioFilesResult ?: return
        pendingAudioFilesResult = null
        if (resultCode != Activity.RESULT_OK) {
            pending.success(null)
            return
        }
        val uris = mutableListOf<Uri>()
        val clip = data?.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        } else {
            data?.data?.let { uris.add(it) }
        }
        val copies = mutableListOf<Map<String, Any>>()
        for (uri in uris) {
            try {
                copies.add(copyIntoCache(uri))
            } catch (_: Exception) {
                // Unreadable selection: skip. The batch must not die here.
            }
        }
        pending.success(copies)
    }

    private fun pickImageFile() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, requestImageFile)
    }

    /// Reads the picked image, downscaling when its longest edge exceeds
    /// [maxImageEdge], and reports bytes + final pixel size + MIME.
    ///
    /// Downscaled images are re-encoded (PNG keeps transparency, everything
    /// else becomes JPEG 90); images already within bounds pass through
    /// byte-for-byte so a small PNG's exact pixels survive.
    private fun readImageBytes(uri: Uri): Map<String, Any> {
        val maxImageEdge = 2048
        val source = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw IllegalStateException("Cannot read the selected image")
        if (source.isEmpty()) throw IllegalStateException("The selected image is empty")

        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeByteArray(source, 0, source.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw IllegalStateException("The selected file is not a decodable image")
        }
        val mime = bounds.outMimeType ?: "image/jpeg"
        val longest = maxOf(bounds.outWidth, bounds.outHeight)
        if (longest <= maxImageEdge) {
            return mapOf(
                "bytes" to source,
                "mime" to mime,
                "width" to bounds.outWidth,
                "height" to bounds.outHeight,
            )
        }

        // Power-of-two subsample close to the target, then exact scale.
        var sample = 1
        while (longest / (sample * 2) >= maxImageEdge) sample *= 2
        val options = android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = android.graphics.BitmapFactory.decodeByteArray(source, 0, source.size, options)
            ?: throw IllegalStateException("The selected image could not be decoded")
        val scale = maxImageEdge.toFloat() / maxOf(decoded.width, decoded.height)
        val bitmap = if (scale < 1f) {
            android.graphics.Bitmap.createScaledBitmap(
                decoded,
                (decoded.width * scale).toInt().coerceAtLeast(1),
                (decoded.height * scale).toInt().coerceAtLeast(1),
                true,
            ).also { if (it !== decoded) decoded.recycle() }
        } else {
            decoded
        }
        val keepPng = mime == "image/png"
        val output = java.io.ByteArrayOutputStream()
        bitmap.compress(
            if (keepPng) android.graphics.Bitmap.CompressFormat.PNG
            else android.graphics.Bitmap.CompressFormat.JPEG,
            90,
            output,
        )
        val result = mapOf(
            "bytes" to output.toByteArray(),
            "mime" to if (keepPng) "image/png" else "image/jpeg",
            "width" to bitmap.width,
            "height" to bitmap.height,
        )
        bitmap.recycle()
        return result
    }

    /// Copies the picked document into cache and reports its path and name.
    private fun copyIntoCache(uri: Uri): Map<String, Any> {
        val name = contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
        } ?: "imported-audio"

        val staging = File(cacheDir, "TangentImport").apply { mkdirs() }
        // Distinct per import: two files with the same name must not collide.
        val target = File(staging, "${System.currentTimeMillis()}-${name.replace(File.separatorChar, '_')}")

        contentResolver.openInputStream(uri).use { input ->
            if (input == null) throw IllegalStateException("Cannot read the selected file")
            target.outputStream().use { output -> input.copyTo(output) }
        }
        if (target.length() <= 0L) {
            target.delete()
            throw IllegalStateException("The selected file is empty")
        }
        return mapOf("path" to target.absolutePath, "name" to name)
    }

    private fun pickDirectory() {
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
        candidatePicker.complete(requestCode == requestTree, resultCode == Activity.RESULT_OK, data?.data, data?.flags ?: 0)
        audioFilePicker.complete(requestCode == requestAudioFile, resultCode == Activity.RESULT_OK, data?.data, data?.flags ?: 0)
        if (requestCode == requestAudioFiles) completeAudioFiles(resultCode, data)
        imageFilePicker.complete(requestCode == requestImageFile, resultCode == Activity.RESULT_OK, data?.data, data?.flags ?: 0)
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
        storageOwner?.detach()
        storageOwner = null
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        candidatePicker.interrupt()
        audioFilePicker.interrupt()
        pendingAudioFilesResult?.error("activity_destroyed", "File picker was interrupted", null)
        pendingAudioFilesResult = null
        imageFilePicker.interrupt()
        super.onDestroy()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        storageOwner?.detach()
        storageOwner = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
