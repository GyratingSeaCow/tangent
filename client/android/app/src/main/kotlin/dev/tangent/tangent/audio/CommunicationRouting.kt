package dev.tangent.tangent.audio

/**
 * A microphone or communication endpoint the platform can route to.
 *
 * [address] is the Bluetooth MAC for BT devices and null otherwise. It is the
 * only reliable way to tie an INPUT device to its COMMUNICATION counterpart:
 * the two enumerations carry different ids for the same physical headset.
 */
data class RoutableDevice(
    val id: Int,
    val address: String?,
    val type: Int,
    val label: String,
)

/** Outcome of asking the platform to route capture to a headset. */
enum class RoutingState {
    /** Routing was applied; the headset mic should become active shortly. */
    APPLIED,

    /** The platform accepted no such device — it is gone or never existed. */
    ABSENT,

    /** The platform refused the request. */
    REFUSED,

    /** This Android version has no communication-device API. */
    UNSUPPORTED,

    /** The selection is not a Bluetooth headset; nothing to route. */
    NOT_APPLICABLE,
}

data class RoutingOutcome(
    val state: RoutingState,
    val device: RoutableDevice?,
    /** The INPUT-enumeration device that was (or would be) captured from.
     *  The recorder selects by input id; [device] is the communication-side
     *  endpoint, which carries a different id for the same headset. */
    val input: RoutableDevice? = null,
)

/**
 * The platform surface [CommunicationRouting] drives.
 *
 * Extracted as a port so the routing rules can be tested without a device:
 * AudioManager is final and its enumerations cannot be constructed in a unit
 * test.
 */
interface CommunicationDevices {
    /** True when the running Android version exposes setCommunicationDevice. */
    val supported: Boolean

    /** Microphones, as reported by GET_DEVICES_INPUTS. */
    fun inputs(): List<RoutableDevice>

    /** Endpoints that may be selected for communication audio. */
    fun communicationTargets(): List<RoutableDevice>

    /** Ask the platform to route communication audio to [device]. */
    fun apply(device: RoutableDevice): Boolean

    /** Release any routing this class applied. */
    fun clear()
}

/**
 * Routes capture to a Bluetooth headset microphone.
 *
 * WHY THIS EXISTS: the `record` plugin (record_android 1.5.2) drives Bluetooth
 * with the deprecated startBluetoothSco()/setBluetoothScoOn() pair. On this
 * project's target hardware that does not bring the SCO link up. Verified on a
 * Galaxy Z Fold (REDACTED_DEVICE_MODEL) with AirPods Pro connected: the picker listed the
 * headset, the preference persisted, and `dumpsys audio` during an active
 * recording still reported
 *
 *     source client=MIC                      <- built-in microphone
 *     Active communication device: role:output type:bt_a2dp
 *     mScoAudioState: SCO_STATE_INACTIVE
 *     Preferred communication device: null
 *
 * A2DP is a playback profile and carries no microphone, so selecting the
 * headset changed nothing but a stored preference. The supported API on
 * Android 12+ is AudioManager.setCommunicationDevice(), which this drives.
 */
class CommunicationRouting(private val devices: CommunicationDevices) {

    /**
     * Route capture for the chosen INPUT device id.
     *
     * Returns without throwing in every failure case: a headset that is off,
     * out of range, or unsupported must never prevent a recording. The caller
     * proceeds on the default microphone instead.
     */
    fun route(inputDeviceId: Int): RoutingOutcome {
        if (!devices.supported) return RoutingOutcome(RoutingState.UNSUPPORTED, null)

        val input = devices.inputs().firstOrNull { it.id == inputDeviceId }
            ?: return RoutingOutcome(RoutingState.ABSENT, null)

        // Only Bluetooth headset mics need routing. Built-in and wired mics are
        // already reachable by the recorder's own device selection, and forcing
        // a communication route for them would needlessly put the phone into
        // call-audio mode.
        if (!isBluetoothHeadset(input)) {
            return RoutingOutcome(RoutingState.NOT_APPLICABLE, input)
        }

        val target = matchTarget(input)
            ?: return RoutingOutcome(RoutingState.ABSENT, input)

        return if (devices.apply(target)) {
            RoutingOutcome(RoutingState.APPLIED, target)
        } else {
            RoutingOutcome(RoutingState.REFUSED, target)
        }
    }

    /**
     * Auto mode: route like a phone call does (Jeff, 2026-09-23 — "It
     * needs to default to the system defaults like it does when you enter
     * into calls"). No chosen device id: the first connected Bluetooth
     * headset mic that the platform can take communication audio to wins.
     * With no headset connected the outcome is ABSENT and the caller
     * records from the built-in microphone.
     */
    fun routeAuto(): RoutingOutcome {
        if (!devices.supported) return RoutingOutcome(RoutingState.UNSUPPORTED, null)

        val headsets = devices.inputs().filter { isBluetoothHeadset(it) }
        if (headsets.isEmpty()) return RoutingOutcome(RoutingState.ABSENT, null)

        // Prefer a headset whose communication target shares its address —
        // an input with no matching target cannot receive call audio and
        // would strand the route (the "zombie headset" case).
        val input = headsets.firstOrNull { matchByAddress(it) != null } ?: headsets.first()
        val target = matchTarget(input)
            ?: return RoutingOutcome(RoutingState.ABSENT, input)

        return if (devices.apply(target)) {
            RoutingOutcome(RoutingState.APPLIED, target, input)
        } else {
            RoutingOutcome(RoutingState.REFUSED, target, input)
        }
    }

    private fun matchByAddress(input: RoutableDevice): RoutableDevice? {
        val address = input.address ?: return null
        if (address.isEmpty()) return null
        return devices.communicationTargets().firstOrNull { it.address == address }
    }

    /**
     * Release the routing.
     *
     * Must be called when capture ends. Leaving a communication device applied
     * keeps the phone in call-audio mode, which degrades music playback and
     * holds the headset in its low-quality SCO profile.
     */
    fun clear() {
        if (!devices.supported) return
        devices.clear()
    }

    /**
     * Tie an input device to its communication counterpart.
     *
     * Matching is by Bluetooth address, because the input and communication
     * enumerations give the same physical headset different ids. Type is the
     * fallback for platforms that report a null address.
     */
    private fun matchTarget(input: RoutableDevice): RoutableDevice? {
        val targets = devices.communicationTargets()
        val address = input.address
        if (address != null && address.isNotEmpty()) {
            targets.firstOrNull { it.address == address }?.let { return it }
        }
        return targets.firstOrNull { isBluetoothHeadset(it) }
    }

    private fun isBluetoothHeadset(device: RoutableDevice): Boolean =
        device.type == TYPE_BLUETOOTH_SCO || device.type == TYPE_BLE_HEADSET

    companion object {
        /** AudioDeviceInfo.TYPE_BLUETOOTH_SCO */
        const val TYPE_BLUETOOTH_SCO = 7

        /** AudioDeviceInfo.TYPE_BLE_HEADSET (API 31+) */
        const val TYPE_BLE_HEADSET = 26
    }
}
