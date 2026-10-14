import CoreAudio
import Darwin
import Foundation

struct ProcessBirth: Equatable {
    let seconds: UInt64
    let microseconds: UInt64
}

struct AudioProcess: Identifiable {
    let id: AudioObjectID
    let pid: pid_t?
    let birth: ProcessBirth?
    let bundleID: String?
    let outputDeviceIDs: [AudioObjectID]?

    var label: String { bundleID ?? pid.map { "Process \($0)" } ?? "Unidentified audio client" }
    var isIdentified: Bool { pid != nil && birth != nil && bundleID != nil }

    func hasSameIdentity(as other: AudioProcess) -> Bool {
        isIdentified && other.isIdentified && id == other.id && pid == other.pid && birth == other.birth && bundleID == other.bundleID
    }
}

struct AudioProcessSnapshot {
    let activeOutputClients: [AudioProcess]
    let unknownActivityCount: Int
}

protocol AudioProcessInventory {
    func snapshot() throws -> AudioProcessSnapshot
    func stillContains(_ client: AudioProcess) throws -> Bool?
}

/// A read-only snapshot of Core Audio process objects. An active output client
/// can be silent; neither PID nor bundle ID establishes control or routing.
struct AudioProcesses: AudioProcessInventory {
    private let system = AudioObjectID(kAudioObjectSystemObject)

    func snapshot() throws -> AudioProcessSnapshot {
        let ids = try processIDs()
        var active: [AudioProcess] = []
        var unknown = 0
        for id in ids {
            guard let running = uint32(id, selector: kAudioProcessPropertyIsRunningOutput) else {
                unknown += 1
                continue
            }
            guard running != 0 else { continue }
            let rawPID = uint32(id, selector: kAudioProcessPropertyPID)
            let pid = rawPID.flatMap { $0 <= Int32.max ? pid_t($0) : nil }
            active.append(AudioProcess(id: id, pid: pid, birth: pid.flatMap(processBirth),
                                       bundleID: bundleID(id), outputDeviceIDs: outputDeviceIDs(id)))
        }
        return AudioProcessSnapshot(
            activeOutputClients: active.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending },
            unknownActivityCount: unknown
        )
    }

    // A complete list absence establishes that the original Core Audio object
    // is gone. An unreadable identity stays unknown, never "same" or "gone".
    func stillContains(_ client: AudioProcess) throws -> Bool? {
        guard try processIDs().contains(client.id) else { return false }
        guard let rawPID = uint32(client.id, selector: kAudioProcessPropertyPID),
              rawPID <= Int32.max, let bundle = bundleID(client.id),
              let originalPID = client.pid, let originalBirth = client.birth,
              let originalBundle = client.bundleID else { return nil }
        guard pid_t(rawPID) == originalPID, bundle == originalBundle else { return false }
        guard let currentBirth = processBirth(originalPID) else { return nil }
        return currentBirth == originalBirth
    }

    private func processBirth(_ pid: pid_t) -> ProcessBirth? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size) }
        guard read == size, info.pbi_start_tvsec != 0 else { return nil }
        return ProcessBirth(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    private func processIDs() throws -> [AudioObjectID] {
        var address = globalAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
        let stride = MemoryLayout<AudioObjectID>.stride
        guard Int(size) % stride == 0, Int(size) / stride <= 4096 else {
            throw AudioDeviceError.inventoryUnavailable
        }
        let count = Int(size) / stride
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        try ids.withUnsafeMutableBufferPointer { buffer in
            try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!))
        }
        // A changed list is not a complete snapshot. Do not present its truncated tail as absence.
        guard Int(size) == count * stride else { throw AudioDeviceError.inventoryUnavailable }
        return ids
    }

    private func uint32(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = globalAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              size == UInt32(MemoryLayout<UInt32>.size) else { return nil }
        return value
    }

    private func outputDeviceIDs(_ id: AudioObjectID) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
        let stride = MemoryLayout<AudioObjectID>.stride
        guard Int(size) % stride == 0, Int(size) / stride <= 4096 else { return nil }
        let count = Int(size) / stride
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr, Int(size) == count * stride else { return nil }
        return ids
    }

    private func bundleID(_ id: AudioObjectID) -> String? {
        var address = globalAddress(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioDeviceError.coreAudio(status) }
    }
}
