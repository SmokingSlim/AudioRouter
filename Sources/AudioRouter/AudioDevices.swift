import AudioToolbox
import CoreAudio
import Foundation

enum AudioDirection: Equatable {
    case input, output
    var scope: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }
}

/// The owner of the role → HAL property mapping. UI controls carry this role,
/// never an array index or an independently interpreted property selector.
enum SystemAudioRole: CaseIterable {
    case output, input, soundEffects
    var title: String {
        switch self { case .output: "Output"; case .input: "Input"; case .soundEffects: "Sound Effects" }
    }
    var direction: AudioDirection { self == .input ? .input : .output }
    var selector: AudioObjectPropertySelector {
        switch self {
        case .output: kAudioHardwarePropertyDefaultOutputDevice
        case .input: kAudioHardwarePropertyDefaultInputDevice
        case .soundEffects: kAudioHardwarePropertyDefaultSystemOutputDevice
        }
    }
    var eligibilitySelector: AudioObjectPropertySelector {
        self == .soundEffects ? kAudioDevicePropertyDeviceCanBeDefaultSystemDevice : kAudioDevicePropertyDeviceCanBeDefaultDevice
    }
}

// Snapshot equality is for presentation caching, not proof of device identity.
// Mutation/capture boundaries must still use hasSameIdentity and live validation.
struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let uid: String?
    let transport: UInt32?
    let direction: AudioDirection
    let supportsVolume: Bool
    let supportsMute: Bool
    let canBeDefault: Bool
    let canBeSoundEffects: Bool

    var isMirrorDestination: Bool {
        guard direction == .output, uid != nil, let transport else { return false }
        return [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
                kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
                kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
                kAudioDeviceTransportTypeFireWire].contains(transport)
    }

    func isEligible(for role: SystemAudioRole) -> Bool {
        direction == role.direction && (role == .soundEffects ? canBeSoundEffects : canBeDefault)
    }

    func hasSameIdentity(as other: AudioDevice) -> Bool {
        // Unknown UID is not proof that two snapshots denote the same device.
        uid != nil && id == other.id && uid == other.uid && direction == other.direction && transport == other.transport
    }
}

struct AudioDeviceInventory {
    let outputs: Result<[AudioDevice], Error>
    let inputs: Result<[AudioDevice], Error>
    func devices(for role: SystemAudioRole) throws -> [AudioDevice] { try (role == .input ? inputs : outputs).get() }
}

enum AudioDeviceError: LocalizedError, Equatable {
    case coreAudio(OSStatus)
    case noDefaultDevice(SystemAudioRole)
    case volumeUnavailable
    case muteUnavailable
    case defaultDeviceChanged(SystemAudioRole)
    case systemDeviceChanged(String)
    case systemDeviceIneligible(SystemAudioRole)
    case settingNotConfirmed(SystemAudioRole)
    case mirrorDestinationUnavailable(String)
    case mirrorDestinationChanged(String)
    case mirrorDestinationUnknown(String)
    case mirrorDestinationUnsupported(String)
    case inventoryUnavailable

    var errorDescription: String? {
        switch self {
        case .coreAudio(let status): "Core Audio error \(status)."
        case .noDefaultDevice(let role): "The system \(role.title.lowercased()) device is unavailable."
        case .volumeUnavailable: "This device does not expose a writable main volume/input-level control."
        case .muteUnavailable: "This device does not expose writable mute control."
        case .defaultDeviceChanged(let role): "The system \(role.title.lowercased()) device changed; reopen the panel and try again."
        case .systemDeviceChanged(let name): "The identity or liveness of ‘\(name)’ could not be verified. Refresh and try again."
        case .systemDeviceIneligible(let role): "This device cannot be selected for system \(role.title.lowercased())."
        case .settingNotConfirmed(let role): "macOS did not confirm the selected \(role.title.lowercased()) device. Refresh to check the current setting."
        case .mirrorDestinationUnavailable(let name): "The selected app output ‘\(name)’ is unavailable or disconnected."
        case .mirrorDestinationChanged(let name): "The identity of the selected app output ‘\(name)’ changed. Restart the route explicitly."
        case .mirrorDestinationUnknown(let name): "The identity or liveness of the selected app output ‘\(name)’ could not be verified."
        case .mirrorDestinationUnsupported(let name): "The selected app output ‘\(name)’ is not an eligible hardware destination."
        case .inventoryUnavailable: "The audio inventory changed or returned malformed data; try again."
        }
    }
}

/// Typed property boundary, also used by deterministic tests which must never
/// change the host's audio settings. Only this implementation parses HAL bytes.
protocol AudioDeviceProperties {
    func objectIDs(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [AudioObjectID]
    func uint32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> UInt32
    func float(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> Float32
    func string(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String
    func isWritable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool
    func writeUInt32(_ value: UInt32, _ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws
    func writeFloat(_ value: Float32, _ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws
}

struct CoreAudioDeviceProperties: AudioDeviceProperties {
    func objectIDs(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size))
        let stride = MemoryLayout<AudioObjectID>.stride
        guard Int(size) % stride == 0, Int(size) / stride <= 4096 else { throw AudioDeviceError.inventoryUnavailable }
        let count = Int(size) / stride
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        try ids.withUnsafeMutableBufferPointer { buffer in
            try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!))
        }
        guard Int(size) == count * stride else { throw AudioDeviceError.inventoryUnavailable }
        return ids
    }

    func uint32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> UInt32 {
        var value: UInt32 = 0
        try read(id, address, &value)
        return value
    }

    func float(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> Float32 {
        var value: Float32 = 0
        try read(id, address, &value)
        guard value.isFinite, (0...1).contains(value) else { throw AudioDeviceError.inventoryUnavailable }
        return value
    }

    func string(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var value: Unmanaged<CFString>?
        try read(id, address, &value)
        guard let value else { throw AudioDeviceError.inventoryUnavailable }
        return value.takeRetainedValue() as String
    }

    private func read<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T) throws {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer))
        }
        guard size == MemoryLayout<T>.size else { throw AudioDeviceError.inventoryUnavailable }
    }

    func isWritable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    func writeUInt32(_ value: UInt32, _ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws {
        try write(value, id, address)
    }

    func writeFloat(_ value: Float32, _ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws {
        try write(value, id, address)
    }

    private func write<T>(_ value: T, _ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws {
        var address = address
        var value = value
        try withUnsafePointer(to: &value) { pointer in
            try check(AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), pointer))
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioDeviceError.coreAudio(status) }
    }
}

struct AudioDevices {
    static func clampedVolume(_ value: Float) -> Float32 { Float32(min(1, max(0, value))) }
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let properties: any AudioDeviceProperties

    init(properties: any AudioDeviceProperties = CoreAudioDeviceProperties()) { self.properties = properties }

    // The UI shares one device-ID snapshot for all three roles. Route health
    // checks query only output facts, avoiding unnecessary input work.
    func inventory() throws -> AudioDeviceInventory {
        let ids = try deviceIDs()
        return AudioDeviceInventory(outputs: Result { try devices(ids, direction: .output) },
                                    inputs: Result { try devices(ids, direction: .input) })
    }

    func outputs() throws -> [AudioDevice] { try devices(deviceIDs(), direction: .output) }

    private func deviceIDs() throws -> [AudioObjectID] {
        let ids = try properties.objectIDs(system, address(kAudioHardwarePropertyDevices))
        guard Set(ids).count == ids.count else { throw AudioDeviceError.inventoryUnavailable }
        return ids
    }

    private func devices(_ ids: [AudioObjectID], direction: AudioDirection) throws -> [AudioDevice] {
        try ids.compactMap { id in
            // An unreadable direction is not absence. Fail that directional
            // snapshot while preserving the other direction's partial facts.
            let streams = try properties.objectIDs(id, address(kAudioDevicePropertyStreams, direction.scope))
            guard !streams.isEmpty else { return nil }
            return AudioDevice(id: id,
                name: (try? properties.string(id, address(kAudioObjectPropertyName))) ?? "Device \(id)",
                uid: (try? properties.string(id, address(kAudioDevicePropertyDeviceUID))).flatMap { $0.isEmpty ? nil : $0 },
                transport: try? properties.uint32(id, address(kAudioDevicePropertyTransportType)), direction: direction,
                supportsVolume: volumeAddress(id, direction: direction) != nil,
                supportsMute: muteAddress(id, direction: direction) != nil,
                canBeDefault: (try? properties.uint32(id, address(kAudioDevicePropertyDeviceCanBeDefaultDevice, direction.scope))) == 1,
                canBeSoundEffects: direction == .output && (try? properties.uint32(id, address(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, direction.scope))) == 1)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func defaultDevice(for role: SystemAudioRole) throws -> AudioObjectID {
        let id = try properties.uint32(system, address(role.selector))
        guard id != kAudioObjectUnknown else { throw AudioDeviceError.noDefaultDevice(role) }
        return id
    }

    func select(_ device: AudioDevice, for role: SystemAudioRole) throws {
        guard device.isEligible(for: role) else { throw AudioDeviceError.systemDeviceIneligible(role) }
        try validateSystemDevice(device)
        guard (try? properties.uint32(device.id, address(role.eligibilitySelector, role.direction.scope))) == 1,
              properties.isWritable(system, address(role.selector)) else { throw AudioDeviceError.systemDeviceIneligible(role) }
        try properties.writeUInt32(device.id, system, address(role.selector))
        guard try defaultDevice(for: role) == device.id else { throw AudioDeviceError.settingNotConfirmed(role) }
    }

    func currentControls(for device: AudioDevice, role: SystemAudioRole) throws -> (volume: Float?, muted: Bool?) {
        try validateCurrent(device, role: role)
        return (try? volume(for: device), try? isMuted(device))
    }

    func volume(for device: AudioDevice) throws -> Float {
        guard let address = volumeAddress(device.id, direction: device.direction) else { throw AudioDeviceError.volumeUnavailable }
        return try properties.float(device.id, address)
    }

    func setVolume(_ value: Float, for device: AudioDevice, role: SystemAudioRole) throws {
        // Effects volume is deliberately not a hardware-volume control: on a
        // shared device that would also change normal playback. No fake slider.
        guard role != .soundEffects, value.isFinite else { throw AudioDeviceError.volumeUnavailable }
        try validateCurrent(device, role: role)
        guard let address = volumeAddress(device.id, direction: device.direction) else { throw AudioDeviceError.volumeUnavailable }
        try properties.writeFloat(Self.clampedVolume(value), device.id, address)
    }

    func isMuted(_ device: AudioDevice) throws -> Bool {
        guard let address = muteAddress(device.id, direction: device.direction) else { throw AudioDeviceError.muteUnavailable }
        let value = try properties.uint32(device.id, address)
        guard value <= 1 else { throw AudioDeviceError.inventoryUnavailable }
        return value == 1
    }

    func setMute(_ muted: Bool, for device: AudioDevice, role: SystemAudioRole) throws {
        guard role != .soundEffects else { throw AudioDeviceError.muteUnavailable }
        try validateCurrent(device, role: role)
        guard let address = muteAddress(device.id, direction: device.direction) else { throw AudioDeviceError.muteUnavailable }
        try properties.writeUInt32(muted ? 1 : 0, device.id, address)
    }

    private func validateCurrent(_ device: AudioDevice, role: SystemAudioRole) throws {
        guard device.direction == role.direction, try defaultDevice(for: role) == device.id else { throw AudioDeviceError.defaultDeviceChanged(role) }
        try validateSystemDevice(device)
    }

    private func validateSystemDevice(_ device: AudioDevice) throws {
        guard try deviceIDs().contains(device.id), let uid = device.uid, !uid.isEmpty,
              (try? properties.string(device.id, address(kAudioDevicePropertyDeviceUID))) == uid,
              (try? properties.uint32(device.id, address(kAudioDevicePropertyDeviceIsAlive))) == 1,
              let streams = try? properties.objectIDs(device.id, address(kAudioDevicePropertyStreams, device.direction.scope)),
              !streams.isEmpty else { throw AudioDeviceError.systemDeviceChanged(device.name) }
    }

    /// Re-resolve UID, never silently rebind an existing sink after reconnect.
    func validateMirrorDestination(_ device: AudioDevice) throws {
        try Self.validateMirrorDestination(device, inventory: outputs(),
            alive: try? properties.uint32(device.id, address(kAudioDevicePropertyDeviceIsAlive)))
    }

    static func validateMirrorDestination(_ device: AudioDevice, inventory: [AudioDevice], alive: UInt32?) throws {
        guard let uid = device.uid, !uid.isEmpty, device.transport != nil else { throw AudioDeviceError.mirrorDestinationUnknown(device.name) }
        guard device.isMirrorDestination else { throw AudioDeviceError.mirrorDestinationUnsupported(device.name) }
        let matches = inventory.filter { $0.uid == uid }
        if matches.isEmpty {
            if let current = inventory.first(where: { $0.id == device.id }) {
                if current.uid == nil { throw AudioDeviceError.mirrorDestinationUnknown(device.name) }
                throw AudioDeviceError.mirrorDestinationChanged(device.name)
            }
            throw AudioDeviceError.mirrorDestinationUnavailable(device.name)
        }
        guard matches.count == 1 else { throw AudioDeviceError.mirrorDestinationUnknown(device.name) }
        let current = matches[0]
        guard current.id == device.id else { throw AudioDeviceError.mirrorDestinationChanged(device.name) }
        guard current.transport != nil else { throw AudioDeviceError.mirrorDestinationUnknown(device.name) }
        guard current.transport == device.transport, current.direction == device.direction else { throw AudioDeviceError.mirrorDestinationChanged(device.name) }
        switch alive {
        case 1: return
        case 0: throw AudioDeviceError.mirrorDestinationUnavailable(device.name)
        default: throw AudioDeviceError.mirrorDestinationUnknown(device.name)
        }
    }

    func sampleRate(_ id: AudioObjectID) throws -> Double {
        // Nominal sample rate is Float64, unlike the scalar controls above.
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        guard status == noErr else { throw AudioDeviceError.coreAudio(status) }
        guard size == MemoryLayout<Float64>.size, rate.isFinite, rate > 0 else { throw AudioDeviceError.inventoryUnavailable }
        return rate
    }

    private func volumeAddress(_ id: AudioObjectID, direction: AudioDirection) -> AudioObjectPropertyAddress? {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            let address = address(selector, direction.scope)
            if properties.isWritable(id, address) { return address }
        }
        return nil
    }

    private func muteAddress(_ id: AudioObjectID, direction: AudioDirection) -> AudioObjectPropertyAddress? {
        let address = address(kAudioDevicePropertyMute, direction.scope)
        return properties.isWritable(id, address) ? address : nil
    }

    private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
