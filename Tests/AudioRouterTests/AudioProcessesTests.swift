import CoreAudio
import Foundation

/// Read-only process properties. Every write is a test failure.
private final class SimulatedAudioProcessProperties: AudioDeviceProperties {
    var ids: [AudioObjectID] = [11, 12, 13]
    var listFailure: AudioDeviceError?
    var activity: [AudioObjectID: UInt32] = [11: 1, 12: 0]
    var pids: [AudioObjectID: UInt32] = [11: 101]
    var bundles: [AudioObjectID: String] = [11: "test.audio"]
    var outputs: [AudioObjectID: [AudioObjectID]] = [11: [201]]

    func objectIDs(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [AudioObjectID] {
        switch address.mSelector {
        case kAudioHardwarePropertyProcessObjectList:
            precondition(id == kAudioObjectSystemObject && address.mScope == kAudioObjectPropertyScopeGlobal)
            if let listFailure { throw listFailure }
            return ids
        case kAudioProcessPropertyDevices:
            precondition(address.mScope == kAudioObjectPropertyScopeOutput)
            guard let values = outputs[id] else { throw AudioDeviceError.inventoryUnavailable }
            return values
        default: preconditionFailure("Unexpected object-ID property")
        }
    }
    func uint32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> UInt32 {
        precondition(address.mScope == kAudioObjectPropertyScopeGlobal)
        let value: UInt32?
        switch address.mSelector {
        case kAudioProcessPropertyIsRunningOutput: value = activity[id]
        case kAudioProcessPropertyPID: value = pids[id]
        default: preconditionFailure("Unexpected scalar property")
        }
        guard let value else { throw AudioDeviceError.inventoryUnavailable }
        return value
    }
    func string(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        precondition(address.mSelector == kAudioProcessPropertyBundleID && address.mScope == kAudioObjectPropertyScopeGlobal)
        guard let value = bundles[id] else { throw AudioDeviceError.inventoryUnavailable }
        return value
    }
    func float(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> Float32 { preconditionFailure("Unexpected float read") }
    func isWritable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool { preconditionFailure("Unexpected write query") }
    func writeUInt32(_ value: UInt32, _ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws { preconditionFailure("Unexpected write") }
    func writeFloat(_ value: Float32, _ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws { preconditionFailure("Unexpected write") }
}

enum AudioProcessesTests {
    static func run() {
        let properties = SimulatedAudioProcessProperties()
        let originalBirth = ProcessBirth(seconds: 123, microseconds: 4)
        var birth: ProcessBirth? = originalBirth
        let processes = AudioProcesses(properties: properties, processBirth: { pid in
            precondition(pid == 101)
            return birth
        })
        let snapshot = try! processes.snapshot()
        precondition(snapshot.activeOutputClients.count == 1 && snapshot.unknownActivityCount == 1)
        let client = snapshot.activeOutputClients[0]
        precondition(client.id == 11 && client.pid == 101 && client.birth == originalBirth)
        precondition(client.bundleID == "test.audio" && client.outputDeviceIDs == [201])
        precondition(try! processes.stillContains(client) == true)

        // Unknown outputs are not empty outputs and do not weaken identity.
        properties.outputs[11] = nil
        precondition(try! processes.snapshot().activeOutputClients[0].outputDeviceIDs == nil)
        properties.outputs[11] = []
        precondition(try! processes.snapshot().activeOutputClients[0].outputDeviceIDs == [])
        precondition(try! processes.stillContains(client) == true)

        birth = nil
        precondition(try! processes.stillContains(client) == nil)
        precondition(try! processes.snapshot().activeOutputClients[0].birth == nil)
        birth = ProcessBirth(seconds: 456, microseconds: 4)
        precondition(try! processes.stillContains(client) == false)
        birth = originalBirth
        properties.bundles[11] = nil
        precondition(try! processes.stillContains(client) == nil)
        properties.bundles[11] = "another.audio"
        precondition(try! processes.stillContains(client) == false)
        properties.bundles[11] = "test.audio"
        properties.pids[11] = UInt32.max
        let unidentified = try! processes.snapshot().activeOutputClients[0]
        precondition(unidentified.pid == nil && unidentified.birth == nil && !unidentified.isIdentified)
        precondition(try! processes.stillContains(client) == nil)
        properties.pids[11] = 102
        precondition(try! processes.stillContains(client) == false)
        properties.pids[11] = nil
        precondition(try! processes.stillContains(client) == nil)
        properties.pids[11] = 101

        // A failed complete-list read never establishes absence. Exercise both
        // malformed-list and transport failures delivered by the typed owner.
        for failure in [AudioDeviceError.inventoryUnavailable, .coreAudio(-1)] {
            properties.listFailure = failure
            for read in [{ _ = try processes.snapshot() }, { _ = try processes.stillContains(client) }] {
                do { try read(); preconditionFailure("Expected list failure") }
                catch let actual as AudioDeviceError { precondition(actual == failure) }
                catch { preconditionFailure("Unexpected failure: \(error)") }
            }
        }
        properties.listFailure = nil
        properties.ids = []
        precondition(try! processes.stillContains(client) == false)
        let empty = try! processes.snapshot()
        precondition(empty.activeOutputClients.isEmpty && empty.unknownActivityCount == 0)
        print("Process inventory typed reads: activity/outputs, lifetime match/change/unknown, malformed/unavailable lists and confirmed absence: passed (simulated properties; no writes)")
    }
}
