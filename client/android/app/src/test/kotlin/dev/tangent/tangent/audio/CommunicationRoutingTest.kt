package dev.tangent.tangent.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rules that decide whether capture gets routed to a headset mic.
 *
 * The governing constraint throughout: a headset that is off, out of range,
 * refused by the platform, or running on an older Android must NEVER prevent a
 * recording from starting. Every failure path here degrades to the default
 * microphone.
 */
class CommunicationRoutingTest {

    private val builtIn = RoutableDevice(1, null, 15, "Built-in (bottom)")
    private val buds = RoutableDevice(
        1535,
        "AA:BB:CC:DD:35:C2",
        CommunicationRouting.TYPE_BLUETOOTH_SCO,
        "AirPods Pro (Bluetooth telephony SCO)",
    )
    private val budsTarget = RoutableDevice(
        42,
        "AA:BB:CC:DD:35:C2",
        CommunicationRouting.TYPE_BLUETOOTH_SCO,
        "AirPods Pro",
    )

    private class FakeDevices(
        override val supported: Boolean = true,
        private val inputs: List<RoutableDevice> = emptyList(),
        private val targets: List<RoutableDevice> = emptyList(),
        private val accept: Boolean = true,
    ) : CommunicationDevices {
        var applied: RoutableDevice? = null
        var cleared = 0
        override fun inputs() = inputs
        override fun communicationTargets() = targets
        override fun apply(device: RoutableDevice): Boolean {
            if (!accept) return false
            applied = device
            return true
        }
        override fun clear() {
            cleared++
        }
    }

    @Test fun routesToTheHeadsetMatchingTheChosenInputByBluetoothAddress() {
        // The input and communication enumerations give the same physical
        // headset different ids (1535 vs 42). Matching must use the address.
        val devices = FakeDevices(inputs = listOf(builtIn, buds), targets = listOf(budsTarget))
        val outcome = CommunicationRouting(devices).route(1535)

        assertEquals(RoutingState.APPLIED, outcome.state)
        assertEquals(budsTarget, devices.applied)
    }

    @Test fun aHeadsetThatIsNoLongerConnectedDoesNotRouteAndDoesNotThrow() {
        // Earbuds switched off between choosing them and tapping record.
        val devices = FakeDevices(inputs = listOf(builtIn), targets = emptyList())
        val outcome = CommunicationRouting(devices).route(1535)

        assertEquals(RoutingState.ABSENT, outcome.state)
        assertNull(devices.applied)
    }

    @Test fun theBuiltInMicrophoneIsNotRouted() {
        // Forcing a communication route for the built-in mic would put the
        // phone into call-audio mode for no benefit.
        val devices = FakeDevices(inputs = listOf(builtIn, buds), targets = listOf(budsTarget))
        val outcome = CommunicationRouting(devices).route(1)

        assertEquals(RoutingState.NOT_APPLICABLE, outcome.state)
        assertNull(devices.applied)
    }

    @Test fun aPlatformWithoutTheApiReportsUnsupportedRatherThanFailing() {
        val devices = FakeDevices(supported = false, inputs = listOf(buds), targets = listOf(budsTarget))
        val outcome = CommunicationRouting(devices).route(1535)

        assertEquals(RoutingState.UNSUPPORTED, outcome.state)
        assertNull(devices.applied)
    }

    @Test fun aRefusedRouteIsReportedAndStillLetsRecordingProceed() {
        val devices = FakeDevices(
            inputs = listOf(buds),
            targets = listOf(budsTarget),
            accept = false,
        )
        val outcome = CommunicationRouting(devices).route(1535)

        assertEquals(RoutingState.REFUSED, outcome.state)
        assertNull(devices.applied)
    }

    @Test fun fallsBackToAnyHeadsetTargetWhenTheAddressIsNotReported() {
        // Some platforms report a null address on the communication endpoint.
        val anonymous = RoutableDevice(42, null, CommunicationRouting.TYPE_BLUETOOTH_SCO, "Headset")
        val devices = FakeDevices(inputs = listOf(buds), targets = listOf(anonymous))
        val outcome = CommunicationRouting(devices).route(1535)

        assertEquals(RoutingState.APPLIED, outcome.state)
        assertEquals(anonymous, devices.applied)
    }

    @Test fun bleHeadsetsRouteTheSameWayAsClassicSco() {
        val ble = RoutableDevice(77, "AA:BB:CC:DD:35:C2", CommunicationRouting.TYPE_BLE_HEADSET, "Buds LE")
        val bleTarget = RoutableDevice(78, "AA:BB:CC:DD:35:C2", CommunicationRouting.TYPE_BLE_HEADSET, "Buds LE")
        val devices = FakeDevices(inputs = listOf(ble), targets = listOf(bleTarget))
        val outcome = CommunicationRouting(devices).route(77)

        assertEquals(RoutingState.APPLIED, outcome.state)
        assertEquals(bleTarget, devices.applied)
    }

    // ── Auto mode: "route like a phone call does" (Jeff, 2026-09-23) ──
    // No chosen device: the FIRST connected Bluetooth headset mic wins;
    // with none connected the outcome is ABSENT and capture stays on the
    // built-in microphone.

    @Test fun autoRoutesToTheOnlyConnectedHeadset() {
        val devices = FakeDevices(inputs = listOf(builtIn, buds), targets = listOf(budsTarget))
        val outcome = CommunicationRouting(devices).routeAuto()

        assertEquals(RoutingState.APPLIED, outcome.state)
        assertEquals(budsTarget, devices.applied)
        // The recorder needs the INPUT id (1535), not the target id (42):
        // RecordConfig selects among GET_DEVICES_INPUTS entries.
        assertEquals(buds, outcome.input)
    }

    @Test fun autoWithNoHeadsetIsAbsentAndRoutesNothing() {
        val devices = FakeDevices(inputs = listOf(builtIn), targets = emptyList())
        val outcome = CommunicationRouting(devices).routeAuto()

        assertEquals(RoutingState.ABSENT, outcome.state)
        assertNull(devices.applied)
        assertNull(outcome.input)
    }

    @Test fun autoOnAnUnsupportedPlatformIsUnsupported() {
        val devices = FakeDevices(supported = false, inputs = listOf(buds))
        val outcome = CommunicationRouting(devices).routeAuto()

        assertEquals(RoutingState.UNSUPPORTED, outcome.state)
        assertNull(devices.applied)
    }

    @Test fun autoPrefersTheHeadsetWhoseTargetSharesItsAddress() {
        // Two headsets connected: the one the platform can actually take
        // communication audio to must win, not merely the first listed.
        val orphan = RoutableDevice(
            9,
            "FF:FF:FF:FF:00:01",
            CommunicationRouting.TYPE_BLUETOOTH_SCO,
            "Zombie headset",
        )
        val devices = FakeDevices(
            inputs = listOf(builtIn, orphan, buds),
            targets = listOf(budsTarget),
        )
        val outcome = CommunicationRouting(devices).routeAuto()

        assertEquals(RoutingState.APPLIED, outcome.state)
        assertEquals(budsTarget, devices.applied)
        assertEquals(buds, outcome.input)
    }

    @Test fun clearingReleasesTheRouteSoThePhoneLeavesCallAudioMode() {
        val devices = FakeDevices(inputs = listOf(buds), targets = listOf(budsTarget))
        val routing = CommunicationRouting(devices)
        routing.route(1535)
        routing.clear()

        assertEquals(1, devices.cleared)
    }

    @Test fun clearingOnAnUnsupportedPlatformIsANoOp() {
        val devices = FakeDevices(supported = false)
        CommunicationRouting(devices).clear()

        assertEquals(0, devices.cleared)
    }

    @Test fun anUnknownInputIdIsAbsentRatherThanAnError() {
        val devices = FakeDevices(inputs = listOf(builtIn), targets = listOf(budsTarget))
        val outcome = CommunicationRouting(devices).route(9999)

        assertEquals(RoutingState.ABSENT, outcome.state)
        assertTrue(devices.applied == null)
    }
}
