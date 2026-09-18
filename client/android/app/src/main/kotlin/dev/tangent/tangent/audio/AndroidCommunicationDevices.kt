package dev.tangent.tangent.audio

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

/**
 * [CommunicationDevices] backed by the real AudioManager.
 *
 * Kept deliberately thin: every decision lives in [CommunicationRouting], which
 * is unit-tested. This class only translates AudioDeviceInfo into
 * [RoutableDevice] and forwards the two platform calls, because AudioManager is
 * final and its device lists cannot be built in a JVM test.
 */
class AndroidCommunicationDevices(context: Context) : CommunicationDevices {

    private val audio =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /**
     * setCommunicationDevice landed in API 31. Below that the only option is
     * the deprecated startBluetoothSco() pair, which is exactly what fails on
     * this project's target hardware, so older versions report unsupported and
     * recording proceeds on the built-in mic.
     */
    override val supported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    override fun inputs(): List<RoutableDevice> =
        audio.getDevices(AudioManager.GET_DEVICES_INPUTS).map(::describe)

    override fun communicationTargets(): List<RoutableDevice> {
        if (!supported) return emptyList()
        return audio.availableCommunicationDevices.map(::describe)
    }

    override fun apply(device: RoutableDevice): Boolean {
        if (!supported) return false
        val target = audio.availableCommunicationDevices
            .firstOrNull { it.id == device.id }
            ?: return false
        return runCatching { audio.setCommunicationDevice(target) }.getOrDefault(false)
    }

    override fun clear() {
        if (!supported) return
        runCatching { audio.clearCommunicationDevice() }
    }

    private fun describe(info: AudioDeviceInfo): RoutableDevice = RoutableDevice(
        id = info.id,
        address = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            runCatching { info.address }.getOrNull()
        } else {
            null
        },
        type = info.type,
        label = info.productName?.toString().orEmpty(),
    )
}
