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
import dev.tangent.tangent.storage.StorageChannel
import dev.tangent.tangent.storage.CandidatePicker
import dev.tangent.tangent.storage.StorageMethodRouter
import dev.tangent.tangent.storage.StorageReply

class MainActivity : FlutterActivity() {
    private val channelName = "dev.tangent.tangent/storage"
    private val audioChannelName = "dev.tangent.tangent/audio"
    private val requestTree = 7301
    private var storageOwner: StorageChannel? = null
    private val documentsPort by lazy { AndroidDocumentsPort(applicationContext) }
    private val candidatePicker by lazy {
        CandidatePicker<Uri>(
            launch = ::pickDirectory,
            takeGrant = { selected, flags -> contentResolver.takePersistableUriPermission(selected, flags) },
            candidate = { selected -> documentsPort.picked(selected) },
            grantMask = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
        super.onDestroy()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        storageOwner?.detach()
        storageOwner = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
