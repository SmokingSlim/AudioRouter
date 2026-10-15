// Command Line Tools installations may not include XCTest. Compile this
// standalone test alongside AudioDevices.swift using the command in README.md.
import CoreAudio
import Foundation

@MainActor
@main
struct AudioDevicesTests {
    static func testDestinationErrors() {
        func device(id: AudioObjectID = 123, uid: String? = "adam-d3v-uid",
                    transport: UInt32? = kAudioDeviceTransportTypeUSB) -> AudioDevice {
            AudioDevice(id: id, name: "ADAM D3V", uid: uid, transport: transport, direction: .output,
                         supportsVolume: true, supportsMute: true, canBeDefault: true, canBeSoundEffects: true)
        }
        let selected = device()
        func expect(_ error: AudioDeviceError, selected: AudioDevice = selected,
                    inventory: [AudioDevice], alive: UInt32? = 1) {
            do {
                try AudioDevices.validateMirrorDestination(selected, inventory: inventory, alive: alive)
                preconditionFailure("Expected destination validation failure")
            } catch let actual as AudioDeviceError {
                precondition(actual == error)
                precondition(!actual.localizedDescription.contains("default output"))
                precondition(actual.localizedDescription.contains("ADAM D3V"))
            } catch { preconditionFailure("Unexpected error: \(error)") }
        }
        try! AudioDevices.validateMirrorDestination(selected, inventory: [selected], alive: 1)
        expect(.mirrorDestinationUnavailable(selected.name), inventory: [])
        expect(.mirrorDestinationUnavailable(selected.name), inventory: [selected], alive: 0)
        expect(.mirrorDestinationUnknown(selected.name), inventory: [selected], alive: nil)
        expect(.mirrorDestinationUnknown(selected.name), inventory: [selected], alive: 2)
        expect(.mirrorDestinationChanged(selected.name), inventory: [device(id: 456)]) // reconnect: same UID, new object
        expect(.mirrorDestinationChanged(selected.name), inventory: [device(uid: "another-device")]) // reused object ID
        expect(.mirrorDestinationUnknown(selected.name), inventory: [device(uid: nil)])
        expect(.mirrorDestinationUnknown(selected.name), inventory: [selected, device(id: 456)]) // ambiguous UID
        expect(.mirrorDestinationUnknown(selected.name), inventory: [device(transport: nil)])
        expect(.mirrorDestinationChanged(selected.name), inventory: [device(transport: kAudioDeviceTransportTypeBluetooth)])
        expect(.mirrorDestinationUnknown(selected.name), selected: device(uid: nil), inventory: [])
        expect(.mirrorDestinationUnsupported(selected.name), selected: device(transport: kAudioDeviceTransportTypeAggregate), inventory: [])
        precondition(AudioDeviceError.defaultDeviceChanged(.output).localizedDescription.contains("output"))

        let notice = ProcessMeter.StoppedOutput(destination: selected,
            reason: AudioDeviceError.mirrorDestinationUnavailable(selected.name))
        precondition(notice.destination.uid == selected.uid)
        precondition(notice.message.contains("ADAM D3V"))
        precondition(notice.message.contains("tap unmuted"))
        precondition(notice.message.contains("released the route resources"))
        let failedCleanup = ProcessMeter.Failure.startAndCleanup("destination unavailable", "restore failed")
        precondition(failedCleanup.localizedDescription.contains("Resources are retained"))
        precondition(!failedCleanup.localizedDescription.contains("released the route resources"))
        print("Destination identity/liveness errors separated from default-output changes; stopped-route notice: passed")
    }

    static func main() {
        precondition(AudioDevices.clampedVolume(-0.5) == 0)
        precondition(AudioDevices.clampedVolume(0.4) == 0.4)
        precondition(AudioDevices.clampedVolume(2) == 1)
        print("Volume bounds: passed")
        testDestinationErrors()
        SystemAudioTests.run()
        AudioProcessesTests.run()
        var samples: [Float32] = [-0.75, 0.3, .nan]
        samples.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 1,
                                                             mDataByteSize: UInt32(buffer.count * 4),
                                                             mData: buffer.baseAddress))
            withUnsafePointer(to: &list) { pointer in
                precondition(ProcessMeter.peakLevel(pointer) == 0.75)
            }
            let state = CaptureState(transport: nil)
            let callback = ProcessMeter.makeCaptureBlock(state: state)
            var time = AudioTimeStamp()
            withUnsafeMutablePointer(to: &list) { listPointer in
                withUnsafePointer(to: &time) { timePointer in
                    // Reproduces the HAL call on a non-main queue without
                    // creating a tap or requesting capture permission.
                    DispatchQueue(label: "app.soundtool.local.test.io").sync {
                        callback(timePointer, UnsafePointer(listPointer), timePointer, listPointer, timePointer)
                        precondition(state.peak.load(ordering: .relaxed) == 0.75)
                        precondition(state.lastPacket.load(ordering: .relaxed) != 0)
                    }
                }
            }
        }
        print("Process meter peak and off-main callback: passed")
        let idleMeter = ProcessMeter()
        precondition(!idleMeter.hasResources)
        try! idleMeter.stop()
        precondition(!idleMeter.hasResources)
        print("Idle meter cleanup: passed")
        SampleTransportTests.run()
        TapPlaybackControlTests.run()
        RoutePresentationTests.run()
        AudioRoutesTests.run()
        UIRefreshTests.run()
        do {
            let audio = AudioDevices()
            let inventory = try audio.inventory()
            let outputs = try inventory.outputs.get()
            let selected = try? audio.defaultDevice(for: .output)
            for role in SystemAudioRole.allCases {
                let devices = try inventory.devices(for: role)
                let id = try? audio.defaultDevice(for: role)
                print("Read-only system \(role.title): \(devices.count) devices, default ID \(id.map(String.init) ?? "unavailable")")
                if role == .input, let device = devices.first(where: { $0.id == id }), device.supportsVolume {
                    _ = try audio.volume(for: device)
                }
            }
            print("Core Audio read-only inventory: \(outputs.count) outputs, default ID \(selected.map(String.init) ?? "unavailable")")
            if let device = outputs.first(where: { $0.id == selected }) {
                print("Selected output: volume=\(device.supportsVolume), mute=\(device.supportsMute), selectable=\(device.canBeDefault)")
                if device.supportsVolume { _ = try audio.volume(for: device) }
                if device.supportsMute { _ = try audio.isMuted(device) }
            }
            let processReader = AudioProcesses()
            let clients = try processReader.snapshot()
            print("Core Audio read-only clients: \(clients.activeOutputClients.count) active output, \(clients.unknownActivityCount) unknown")
            print("Output destinations known for \(clients.activeOutputClients.filter { $0.outputDeviceIDs != nil }.count) active clients")
            if let client = clients.activeOutputClients.first(where: { $0.pid != nil && $0.birth != nil && $0.bundleID != nil }) {
                // A process can legitimately exit between snapshots; do not
                // turn that race into a test failure or assert continued activity.
                let present = try processReader.stillContains(client)
                print("Audio client identity recheck: \(present.map(String.init) ?? "unknown")")
            }
        } catch {
            print("Core Audio read-only inventory unavailable: \(error)")
        }
    }
}
