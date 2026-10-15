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
    private let properties: any AudioDeviceProperties
    private let processBirth: (pid_t) -> ProcessBirth?

    init(properties: any AudioDeviceProperties = CoreAudioDeviceProperties(),
         processBirth: @escaping (pid_t) -> ProcessBirth? = AudioProcesses.readProcessBirth) {
        self.properties = properties
        self.processBirth = processBirth
    }

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

    private static func readProcessBirth(_ pid: pid_t) -> ProcessBirth? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size) }
        guard read == size, info.pbi_start_tvsec != 0 else { return nil }
        return ProcessBirth(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    private func processIDs() throws -> [AudioObjectID] {
        try properties.objectIDs(system, globalAddress(kAudioHardwarePropertyProcessObjectList))
    }

    private func uint32(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        try? properties.uint32(id, globalAddress(selector))
    }

    private func outputDeviceIDs(_ id: AudioObjectID) -> [AudioObjectID]? {
        let address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                                                mScope: kAudioObjectPropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
        return try? properties.objectIDs(id, address)
    }

    private func bundleID(_ id: AudioObjectID) -> String? {
        try? properties.string(id, globalAddress(kAudioProcessPropertyBundleID))
    }

    private func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

}
