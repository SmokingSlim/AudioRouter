import CoreAudio
import Foundation

@MainActor
struct TapPlaybackControlTests {
    // Typed production-property boundary simulation. No process tap is created
    // and no real application's mute state is changed by these tests.
    @MainActor
    final class PropertyStub {
        let uuid = UUID()
        var returnedUUID: UUID?
        var mode: CATapMuteBehavior = .unmuted
        var readbackOverride: CATapMuteBehavior?
        var writable = true
        var failRead = false
        var failWrite = false
        var failAfterWrite = false
        var writes: [CATapMuteBehavior] = []

        var access: TapPlaybackControl.Access {
            .init(read: { [self] _ in
                if failRead { throw TapPlaybackControl.Failure.unreadableDescription }
                let description = CATapDescription(stereoMixdownOfProcesses: [456])
                description.uuid = returnedUUID ?? uuid
                description.name = "Preserve this name"
                description.isPrivate = true
                description.muteBehavior = readbackOverride ?? mode
                return description
            }, checkWritable: { [self] _ in
                if !writable { throw TapPlaybackControl.Failure.notWritable }
            }, write: { [self] _, description in
                precondition(description.uuid == uuid && description.isPrivate)
                precondition(description.name == "Preserve this name")
                precondition(description.isMixdown && !description.isMono && !description.isExclusive)
                writes.append(description.muteBehavior)
                if failWrite { throw TapPlaybackControl.Failure.coreAudio(-1) }
                mode = description.muteBehavior
                if failAfterWrite { throw TapPlaybackControl.Failure.coreAudio(-2) }
            })
        }

        func control() -> TapPlaybackControl { TapPlaybackControl(tap: 123, uuid: uuid, access: access) }
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected failure") } catch {}
    }

    static func run() {
        let normal = PropertyStub(), control = normal.control()
        precondition(!control.restorationRequired && !control.suppressionConfirmed)
        try! control.restore() // no unnecessary mutation for an unmuted tap
        precondition(normal.writes.isEmpty)
        try! control.suppress()
        precondition(normal.mode == .mutedWhenTapped && control.restorationRequired && control.suppressionConfirmed)
        try! control.validateSuppression()
        expectFailure { try control.suppress() } // never reapply over unresolved state
        try! control.restore()
        precondition(normal.mode == .unmuted && !control.restorationRequired && !control.suppressionConfirmed)
        precondition(normal.writes == [.mutedWhenTapped, .unmuted])

        let unsupported = PropertyStub(), unsupportedControl = unsupported.control()
        unsupported.writable = false
        expectFailure { try unsupportedControl.suppress() }
        precondition(unsupported.writes.isEmpty && !unsupportedControl.restorationRequired)

        let ambiguous = PropertyStub(), ambiguousControl = ambiguous.control()
        ambiguous.failAfterWrite = true
        expectFailure { try ambiguousControl.suppress() }
        precondition(ambiguous.mode == .mutedWhenTapped)
        precondition(ambiguousControl.restorationRequired && !ambiguousControl.suppressionConfirmed)
        expectFailure { try ambiguousControl.restore() }
        // Even when the errored restore actually reached the backend, a write
        // error is not permission to release the restoration obligation.
        precondition(ambiguous.mode == .unmuted && ambiguousControl.restorationRequired)
        ambiguous.failAfterWrite = false
        try! ambiguousControl.restore()
        precondition(!ambiguousControl.restorationRequired)

        let refused = PropertyStub(), refusedControl = refused.control()
        refused.failWrite = true
        expectFailure { try refusedControl.suppress() }
        precondition(refusedControl.restorationRequired)
        expectFailure { try refusedControl.restore() }
        precondition(refusedControl.restorationRequired)
        refused.failWrite = false
        try! refusedControl.restore()

        let mismatch = PropertyStub(), mismatchControl = mismatch.control()
        mismatch.readbackOverride = .unmuted
        expectFailure { try mismatchControl.suppress() }
        precondition(mismatchControl.restorationRequired && !mismatchControl.suppressionConfirmed)
        mismatch.readbackOverride = nil
        try! mismatchControl.restore()
        try! mismatchControl.suppress()
        mismatch.readbackOverride = .mutedWhenTapped
        expectFailure { try mismatchControl.restore() }
        precondition(mismatchControl.restorationRequired && !mismatchControl.suppressionConfirmed)
        mismatch.readbackOverride = nil
        try! mismatchControl.restore()

        let identity = PropertyStub(), identityControl = identity.control()
        try! identityControl.suppress()
        identity.returnedUUID = UUID()
        expectFailure { try identityControl.restore() }
        precondition(identity.writes == [.mutedWhenTapped] && identityControl.restorationRequired)
        identity.returnedUUID = nil
        identity.failRead = true
        expectFailure { try identityControl.restore() }
        precondition(identityControl.restorationRequired)
        identity.failRead = false
        try! identityControl.restore()

        let revoked = PropertyStub(), revokedControl = revoked.control()
        try! revokedControl.suppress()
        revoked.writable = false
        expectFailure { try revokedControl.restore() }
        precondition(revokedControl.restorationRequired && !revokedControl.suppressionConfirmed)
        revoked.writable = true
        try! revokedControl.restore()
        precondition(!revokedControl.restorationRequired)

        let foreign = PropertyStub(), foreignControl = foreign.control()
        foreign.returnedUUID = UUID()
        expectFailure { try foreignControl.suppress() }
        precondition(foreign.writes.isEmpty && !foreignControl.restorationRequired)

        let changed = PropertyStub(), changedControl = changed.control()
        try! changedControl.suppress()
        changed.mode = .unmuted
        expectFailure { try changedControl.validateSuppression() }
        try! changedControl.restore()
        precondition(!changedControl.restorationRequired)

        let idle = ProcessMeter()
        precondition(!idle.canSuppressOriginal)
        expectFailure { try idle.suppressOriginalPlayback() }
        try! idle.restoreOriginalPlayback()
        try! idle.stop()
        print("Tap suppression/readback, ambiguous writes, restoration retention/retry, identity, unavailable controls, idle readiness: passed")
    }
}
