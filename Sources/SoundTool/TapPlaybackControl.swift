import CoreAudio
import Foundation

/// Owns interpretation of tap-description mutation/readback and the obligation
/// to restore direct playback. ProcessMeter owns the tap's actual lifetime.
@MainActor
final class TapPlaybackControl {
    @MainActor
    struct Access {
        let read: (AudioObjectID) throws -> CATapDescription
        let checkWritable: (AudioObjectID) throws -> Void
        let write: (AudioObjectID, CATapDescription) throws -> Void

        static let live = Access(read: { tap in
            var address = Self.address()
            var value: Unmanaged<CATapDescription>?
            var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
            let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &value)
            guard status == noErr else { throw Failure.coreAudio(status) }
            guard size == MemoryLayout<Unmanaged<CATapDescription>?>.size, let value else {
                throw Failure.unreadableDescription
            }
            return value.takeRetainedValue()
        }, checkWritable: { tap in
            var address = Self.address()
            var settable = DarwinBoolean(false)
            let status = AudioObjectIsPropertySettable(tap, &address, &settable)
            guard status == noErr else { throw Failure.coreAudio(status) }
            guard settable.boolValue else { throw Failure.notWritable }
        }, write: { tap, description in
            var address = Self.address()
            var value = Unmanaged.passUnretained(description)
            let result = AudioObjectSetPropertyData(tap, &address, 0, nil,
                UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), &value)
            guard result == noErr else { throw Failure.coreAudio(result) }
        })

        private static func address() -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
    }

    enum Failure: LocalizedError {
        case coreAudio(OSStatus)
        case unreadableDescription
        case notWritable
        case changedTap
        case readbackMismatch
        case restorationPending
        var errorDescription: String? {
            switch self {
            case .coreAudio(let status): "Tap playback control error \(status)."
            case .unreadableDescription: "The tap playback description could not be read."
            case .notWritable: "macOS does not allow updating this tap's playback behavior."
            case .changedTap: "The tap identity changed; refusing to modify an unidentified tap."
            case .readbackMismatch: "macOS did not confirm the requested tap playback behavior."
            case .restorationPending: "Original playback restoration is pending. Retry Stop / restore before suppressing again."
            }
        }
    }

    private let tap: AudioObjectID
    private let uuid: UUID
    private let access: Access
    private(set) var restorationRequired = false
    private(set) var suppressionConfirmed = false

    init(tap: AudioObjectID, uuid: UUID, access: Access = .live) {
        self.tap = tap
        self.uuid = uuid
        self.access = access
    }

    func suppress() throws {
        guard !restorationRequired else { throw Failure.restorationPending }
        let description = try ownedDescription()
        try access.checkWritable(tap)
        // A write error does not prove the write had no effect. Record the
        // restoration obligation BEFORE crossing the mutating boundary.
        restorationRequired = true
        suppressionConfirmed = false
        description.muteBehavior = .mutedWhenTapped
        try access.write(tap, description)
        guard try ownedDescription().muteBehavior == .mutedWhenTapped else { throw Failure.readbackMismatch }
        suppressionConfirmed = true
    }

    func restore() throws {
        guard restorationRequired else { return }
        suppressionConfirmed = false
        let description = try ownedDescription()
        try access.checkWritable(tap)
        description.muteBehavior = .unmuted
        try access.write(tap, description)
        guard try ownedDescription().muteBehavior == .unmuted else { throw Failure.readbackMismatch }
        restorationRequired = false
    }

    func validateSuppression() throws {
        guard suppressionConfirmed,
              try ownedDescription().muteBehavior == .mutedWhenTapped else { throw Failure.readbackMismatch }
    }

    private func ownedDescription() throws -> CATapDescription {
        let description = try access.read(tap)
        guard description.uuid == uuid else { throw Failure.changedTap }
        return description // preserve all other description fields
    }
}
