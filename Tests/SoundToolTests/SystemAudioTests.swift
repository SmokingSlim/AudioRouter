import AppKit
import CoreAudio

/// Typed HAL boundary simulation. No writes reach Core Audio or host settings.
final class SimulatedAudioDeviceProperties: AudioDeviceProperties {
    struct Key: Hashable {
        let id: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
    }
    var ids: [AudioObjectID] = [101, 102, 103]
    var uids: [AudioObjectID: String] = [101: "speaker-a", 102: "mic-a", 103: "usb-duplex"]
    var alive: UInt32 = 1
    var eligible: UInt32 = 1
    var systemEligible: UInt32 = 1
    var readbackOverride: AudioObjectID?
    var defaults: [AudioObjectPropertySelector: UInt32] = [
        kAudioHardwarePropertyDefaultOutputDevice: 101,
        kAudioHardwarePropertyDefaultInputDevice: 102,
        kAudioHardwarePropertyDefaultSystemOutputDevice: 101,
    ]
    var scalars: [Key: Float32] = [:]
    var mute: [Key: UInt32] = [:]
    var writes: [Key] = []
    var writable = true
    var inventoryReads = 0
    var unknownStreamScope: AudioObjectPropertyScope?

    func objectIDs(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [AudioObjectID] {
        if address.mSelector == kAudioHardwarePropertyDevices { inventoryReads += 1; return ids }
        guard address.mSelector == kAudioDevicePropertyStreams else { throw AudioDeviceError.inventoryUnavailable }
        if address.mScope == unknownStreamScope { throw AudioDeviceError.coreAudio(-1) }
        let supported = id == 103 || (id == 101 && address.mScope == kAudioObjectPropertyScopeOutput) || (id == 102 && address.mScope == kAudioObjectPropertyScopeInput)
        return supported ? [id + 1000] : []
    }
    func uint32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> UInt32 {
        if let value = defaults[address.mSelector] { return readbackOverride ?? value }
        switch address.mSelector {
        case kAudioDevicePropertyTransportType: return kAudioDeviceTransportTypeUSB
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: return eligible
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return systemEligible
        case kAudioDevicePropertyDeviceIsAlive: return alive
        case kAudioDevicePropertyMute: return mute[key(id, address), default: 0]
        default: throw AudioDeviceError.inventoryUnavailable
        }
    }
    func float(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> Float32 { scalars[key(id, address), default: 0.5] }
    func string(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        switch address.mSelector {
        case kAudioObjectPropertyName: return "Device \(id)"
        case kAudioDevicePropertyDeviceUID:
            guard let uid = uids[id] else { throw AudioDeviceError.inventoryUnavailable }
            return uid
        default: throw AudioDeviceError.inventoryUnavailable
        }
    }
    func isWritable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool { writable }
    func writeUInt32(_ value: UInt32, _ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws {
        writes.append(key(id, address))
        if defaults[address.mSelector] != nil { defaults[address.mSelector] = value }
        else { mute[key(id, address)] = value }
    }
    func writeFloat(_ value: Float32, _ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws {
        writes.append(key(id, address)); scalars[key(id, address)] = value
    }
    private func key(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Key { Key(id: id, selector: address.mSelector, scope: address.mScope) }
}

@MainActor
enum SystemAudioTests {
    static func run() {
        let properties = SimulatedAudioDeviceProperties()
        let audio = AudioDevices(properties: properties)
        let inventory = try! audio.inventory()
        precondition(properties.inventoryReads == 1) // shared list for all roles
        let outputs = try! inventory.outputs.get()
        let inputs = try! inventory.inputs.get()
        precondition(outputs.map(\.id) == [101, 103])
        precondition(inputs.map(\.id) == [102, 103])
        let output = outputs.first!
        let input = inputs.first!
        let usbOutput = outputs.last!
        precondition(input.direction == .input && !input.isMirrorDestination)
        precondition(!input.isEligible(for: .output) && !output.isEligible(for: .input))
        precondition(Set(SystemAudioRole.allCases.map(\.selector)).count == 3)

        func expect(_ error: AudioDeviceError, writes count: Int? = nil, _ action: () throws -> Void) {
            do { try action(); preconditionFailure("Expected \(error)") }
            catch let actual as AudioDeviceError { precondition(actual == error) }
            catch { preconditionFailure("Unexpected error: \(error)") }
            if let count { precondition(properties.writes.count == count) }
        }
        expect(.systemDeviceIneligible(.output), writes: 0) { try audio.select(input, for: .output) }
        expect(.mirrorDestinationUnsupported(input.name), writes: 0) {
            try AudioDevices.validateMirrorDestination(input, inventory: inputs, alive: 1)
        }
        properties.uids[101] = "reused-object"
        expect(.systemDeviceChanged(output.name), writes: 0) { try audio.select(output, for: .output) }
        properties.uids[101] = "speaker-a"
        properties.alive = 2
        expect(.systemDeviceChanged(output.name), writes: 0) { try audio.select(output, for: .output) }
        properties.alive = 1
        properties.ids = [102, 103]
        expect(.systemDeviceChanged(output.name), writes: 0) { try audio.select(output, for: .output) }
        properties.ids = [101, 102, 103]
        properties.systemEligible = 0
        expect(.systemDeviceIneligible(.soundEffects), writes: 0) { try audio.select(output, for: .soundEffects) }
        properties.systemEligible = 1
        properties.eligible = 2
        expect(.systemDeviceIneligible(.input), writes: 0) { try audio.select(input, for: .input) }
        properties.eligible = 1
        properties.writable = false
        expect(.systemDeviceIneligible(.input), writes: 0) { try audio.select(input, for: .input) }
        properties.writable = true
        properties.readbackOverride = 999
        expect(.settingNotConfirmed(.output), writes: 1) { try audio.select(usbOutput, for: .output) }
        properties.readbackOverride = nil
        precondition(try! audio.defaultDevice(for: .output) == 103) // write took effect; not falsely rolled back
        precondition(try! audio.defaultDevice(for: .input) == 102)
        precondition(try! audio.defaultDevice(for: .soundEffects) == 101)
        expect(.defaultDeviceChanged(.output), writes: 1) { try audio.setVolume(0.2, for: output, role: .output) }
        expect(.volumeUnavailable, writes: 1) { try audio.setVolume(.nan, for: usbOutput, role: .output) }
        expect(.volumeUnavailable, writes: 1) { try audio.setVolume(0.2, for: output, role: .soundEffects) }
        expect(.muteUnavailable, writes: 1) { try audio.setMute(true, for: output, role: .soundEffects) }
        try! audio.setVolume(2, for: input, role: .input)
        precondition(try! audio.volume(for: input) == 1)
        precondition(properties.writes.last?.scope == kAudioObjectPropertyScopeInput)
        try! audio.setMute(true, for: usbOutput, role: .output)
        precondition(try! audio.isMuted(usbOutput))
        precondition(properties.writes.last?.scope == kAudioObjectPropertyScopeOutput)
        let count = properties.writes.count
        properties.uids[102] = "restarted-mic"
        expect(.systemDeviceChanged(input.name), writes: count) { try audio.setVolume(0.1, for: input, role: .input) }
        properties.uids[102] = "mic-a"
        properties.defaults[kAudioHardwarePropertyDefaultInputDevice] = 0
        expect(.noDefaultDevice(.input)) { _ = try audio.defaultDevice(for: .input) }
        properties.defaults[kAudioHardwarePropertyDefaultInputDevice] = 102
        properties.ids.append(101)
        expect(.inventoryUnavailable) { _ = try audio.inventory() }
        properties.ids.removeLast()
        properties.unknownStreamScope = kAudioObjectPropertyScopeInput
        let partial = try! audio.inventory()
        precondition(try! partial.outputs.get().count == 2)
        expect(.coreAudio(-1)) { _ = try partial.inputs.get() }
        properties.unknownStreamScope = kAudioObjectPropertyScopeOutput
        expect(.coreAudio(-1)) { try audio.validateMirrorDestination(output) }
        properties.unknownStreamScope = nil
        print("System role separation, scoped levels/mute, identity/liveness/eligibility guards, readback, unknown defaults: passed (simulated property boundary)")

        // Production controller + controls: real AppKit target/actions, fake
        // system HAL writes; actual process inventory is read-only.
        _ = NSApplication.shared
        let uiProperties = SimulatedAudioDeviceProperties()
        let controller = SoundToolApp(audio: AudioDevices(properties: uiProperties))
        controller.refreshInventory()
        for row in controller.panel.systemRows {
            let before = uiProperties.defaults
            let selected = row.picker.itemArray.first { ($0.representedObject as? AudioDevice)?.id == 103 }!
            row.picker.select(selected)
            precondition(NSApp.sendAction(row.picker.action!, to: row.picker.target, from: row.picker))
            precondition(uiProperties.defaults[row.role.selector] == 103)
            for role in SystemAudioRole.allCases where role != row.role {
                precondition(uiProperties.defaults[role.selector] == before[role.selector])
            }
            precondition(row.displayedDevice?.id == 103)
        }
        let inputRow = controller.panel.systemRows.first { $0.role == .input }!
        let inputMenu = inputRow.picker.itemArray
        let appRows = controller.panel.applicationRows
        inputRow.volume.doubleValue = 0.25
        precondition(NSApp.sendAction(inputRow.volume.action!, to: inputRow.volume.target, from: inputRow.volume))
        precondition(uiProperties.writes.last?.scope == kAudioObjectPropertyScopeInput)
        precondition(inputRow.valueLabel.stringValue == "25%")
        precondition(inputMenu.count == inputRow.picker.numberOfItems && zip(inputMenu, inputRow.picker.itemArray).allSatisfy { $0 === $1 })
        precondition(appRows.count == controller.panel.applicationRows.count && zip(appRows, controller.panel.applicationRows).allSatisfy { $0 === $1 })
        let outputRow = controller.panel.systemRows.first { $0.role == .output }!
        outputRow.muteButton.state = .on
        precondition(NSApp.sendAction(outputRow.muteButton.action!, to: outputRow.muteButton.target, from: outputRow.muteButton))
        precondition(uiProperties.writes.last?.scope == kAudioObjectPropertyScopeOutput)
        precondition(outputRow.muteButton.state == .on)
        print("Production System row target/actions through controller and property boundary: passed (no live audio-setting writes)")
    }
}
