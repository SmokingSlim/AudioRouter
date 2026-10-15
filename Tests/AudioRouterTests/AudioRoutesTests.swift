import AppKit

/// Simulation of the lifecycle port, NOT of HAL mute or disposal semantics.
@MainActor
final class SimulatedRouteOwner: AudioRouteOwner {
    enum Fault: Error { case start, restore, cleanup }
    var hasResources = false
    var isRunning = false
    var isStopping = false
    var restorationPending = false
    var suppressionRequested = false
    var canSuppressOriginal = false
    var exclusiveOutputPending = false
    var mirrorDestination: AudioDevice?
    private(set) var playbackLevel: PlaybackLevel = .unity
    func setPlaybackLevel(_ level: PlaybackLevel) { playbackLevel = level }
    var peak: Float = 0
    var transportStatus: String? { "simulated transport" }
    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onStoppedOutput: ((ProcessMeter.StoppedOutput) -> Void)?
    var onStateChange: (() -> Void)?
    var startFault = false
    var retainOnStartFailure = false
    var stopFault: Fault?
    var stops = 0
    var restores = 0
    var starts = 0
    var whileStarting: (() -> Void)?

    func start(client: AudioProcess, mirroringTo destination: AudioDevice?, suppressWhenReady: Bool) throws {
        starts += 1
        onStateChange?() // no resources yet; registry must retain in-flight ownership
        whileStarting?()
        hasResources = !startFault || retainOnStartFailure
        if startFault { throw Fault.start }
        mirrorDestination = destination
        isRunning = true
        exclusiveOutputPending = suppressWhenReady
    }
    func stop() throws {
        stops += 1
        isStopping = true
        exclusiveOutputPending = false
        if stopFault == .restore {
            restorationPending = true
            onStateChange?()
            throw Fault.restore
        }
        try restoreOriginalPlayback()
        isRunning = false
        if stopFault == .cleanup { throw Fault.cleanup }
        hasResources = false
        mirrorDestination = nil
        isStopping = false
        onStateChange?()
    }
    func restoreOriginalPlayback() throws {
        restores += 1
        exclusiveOutputPending = false
        suppressionRequested = false
        restorationPending = false
        onStateChange?()
    }
    func suppressOriginalPlayback() throws {
        suppressionRequested = true
        exclusiveOutputPending = false
        onStateChange?()
    }
}

struct SimulatedProcessInventory: AudioProcessInventory {
    var clients: [AudioProcess]
    func snapshot() throws -> AudioProcessSnapshot { AudioProcessSnapshot(activeOutputClients: clients, unknownActivityCount: 0) }
    func stillContains(_ client: AudioProcess) throws -> Bool? { clients.contains { $0.hasSameIdentity(as: client) } }
}

@MainActor
enum AudioRoutesTests {
    static func client(_ id: UInt32, pid: Int32? = nil, birth: UInt64 = 100) -> AudioProcess {
        AudioProcess(id: id, pid: pid ?? Int32(id + 31000), birth: ProcessBirth(seconds: birth, microseconds: 1),
                     bundleID: "test.audio.\(id)", outputDeviceIDs: nil)
    }
    static func expectFailure(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected route failure") } catch {}
    }
    static func run() {
        let devices = try! AudioDevices(properties: SimulatedAudioDeviceProperties()).inventory().outputs.get()
        let a = devices.first!, b = devices.last!
        var owners: [SimulatedRouteOwner] = []
        weak var registry: AudioRoutes?
        let routes = AudioRoutes {
            let owner = SimulatedRouteOwner()
            owners.append(owner)
            owner.whileStarting = { precondition(registry!.routes.count > 0) }
            return owner
        }
        registry = routes
        let first = try! routes.start(client: client(1), destination: a)
        let second = try! routes.start(client: client(2), destination: b)
        precondition(routes.routes.count == 2 && first.owner !== second.owner)
        precondition(owners[0].exclusiveOutputPending && owners[1].exclusiveOutputPending)
        expectFailure { try routes.start(client: client(1), destination: b) }
        expectFailure { try routes.start(client: client(99, pid: client(1).pid), destination: b) } // alias HAL object
        precondition(owners.count == 2)
        let quiet = PlaybackLevel(gain: 0.4, muted: true)!
        try! routes.setPlaybackLevel(quiet, for: client(1))
        precondition(owners[0].playbackLevel == quiet && owners[1].playbackLevel == .unity)
        expectFailure { try routes.setPlaybackLevel(quiet, for: client(1, birth: 200)) }
        try! routes.select(client: client(1), destination: b) // shared destination; no shared owner/transport
        precondition(owners[2].playbackLevel == quiet)
        precondition(owners[0].stops == 1 && owners[1].stops == 0 && owners.count == 3)
        precondition(routes.route(for: client(1))!.owner.mirrorDestination!.hasSameIdentity(as: b))
        precondition(routes.route(for: client(2)) === second)
        try! routes.select(client: client(1), destination: nil)
        precondition(routes.routes.count == 1 && owners[1].exclusiveOutputPending)

        // One monitor can coexist with hardware routes; no duplicate-client tap.
        let monitor = try! routes.start(client: client(3), destination: nil)
        precondition(monitor.isMonitor && !owners.last!.exclusiveOutputPending)
        expectFailure { try routes.setPlaybackLevel(quiet, for: client(3)) }
        expectFailure { try routes.start(client: client(4), destination: nil) }
        expectFailure { try routes.start(client: client(3), destination: a) }
        try! routes.start(client: client(4), destination: a)
        try! routes.start(client: client(5), destination: b)
        precondition(routes.routes.count == AudioRoutes.capacity)
        precondition(!routes.canStart(client(6)))
        let allocated = owners.count
        expectFailure { try routes.start(client: client(6), destination: b) }
        precondition(owners.count == allocated)
        try! routes.stopAll()
        precondition(routes.routes.isEmpty)

        // Partial setup and failed restoration remain owned. They reserve a
        // slot and identity, not a global lock on independent clients.
        var failedOwners: [SimulatedRouteOwner] = []
        let faults = AudioRoutes {
            let owner = SimulatedRouteOwner()
            if failedOwners.isEmpty { owner.startFault = true; owner.retainOnStartFailure = true }
            failedOwners.append(owner)
            return owner
        }
        expectFailure { try faults.start(client: client(10), destination: a) }
        precondition(faults.routes.count == 1 && faults.routes[0].owner === failedOwners[0])
        precondition(faults.canStart(client(11), monitoring: true)) // partial hardware start is NOT a monitor
        expectFailure { try faults.select(client: client(10), destination: b) }
        expectFailure { try faults.start(client: client(10, birth: 200), destination: b) } // reused lifetime ID/PID retained
        let healthy = try! faults.start(client: client(11), destination: b)
        failedOwners[0].stopFault = .restore
        expectFailure { try faults.stopAll() }
        precondition(failedOwners.allSatisfy { $0.stops == 1 }) // Quit attempts EVERY owner
        precondition(faults.routes.count == 1 && faults.routes[0].owner.hasResources)
        precondition(!healthy.owner.hasResources && failedOwners[0].restorationPending)
        failedOwners[0].stopFault = .cleanup
        expectFailure { try faults.stopAll() }
        precondition(faults.routes.count == 1 && !failedOwners[0].isRunning)
        failedOwners[0].stopFault = nil
        try! faults.stopAll()
        precondition(faults.routes.isEmpty)
        try! faults.start(client: client(10, birth: 200), destination: a)
        try! faults.stopAll()

        // Replacement cannot proceed past this route's failed Stop. The
        // unaffected owner is neither restored nor torn down by that failure.
        var switchingOwners: [SimulatedRouteOwner] = []
        let switching = AudioRoutes {
            let owner = SimulatedRouteOwner(); switchingOwners.append(owner); return owner
        }
        let blocked = try! switching.start(client: client(12), destination: a)
        let unaffected = try! switching.start(client: client(13), destination: b)
        try! switching.setPlaybackLevel(quiet, for: client(12))
        switchingOwners[0].stopFault = .restore
        expectFailure { try switching.select(client: client(12), destination: b) }
        precondition(switching.route(for: client(12)) === blocked && switchingOwners.count == 2)
        precondition(switchingOwners[0].restorationPending && switchingOwners[1].stops == 0)
        precondition(switchingOwners[0].playbackLevel == quiet)
        expectFailure { try switching.setPlaybackLevel(.unity, for: client(12)) }
        precondition(switching.route(for: client(13)) === unaffected && unaffected.owner.exclusiveOutputPending)
        switchingOwners[0].stopFault = .cleanup
        expectFailure { try switching.select(client: client(12), destination: nil) }
        precondition(switching.routes.count == 2 && switchingOwners[1].restores == 0)
        switchingOwners[0].stopFault = nil
        try! switching.select(client: client(12), destination: nil)
        precondition(switching.routes.count == 1 && switching.routes[0] === unaffected)
        try! switching.stopAll()

        let cleanFailure = AudioRoutes {
            let owner = SimulatedRouteOwner(); owner.startFault = true; return owner
        }
        expectFailure { try cleanFailure.start(client: client(20), destination: a) }
        precondition(cleanFailure.routes.isEmpty)
        let unknown = AudioProcess(id: 21, pid: nil, birth: nil, bundleID: nil, outputDeviceIDs: nil)
        expectFailure { try cleanFailure.start(client: unknown, destination: a) }

        // Automatic recovery callback AFTER Stop's state callback removed the
        // entry still carries client context. Only the affected owner is lost.
        let recovered = try! routes.start(client: client(30), destination: a).owner
        let survivor = try! routes.start(client: client(31), destination: b)
        var notices = 0
        routes.onStoppedOutput = { selected, notice in
            precondition(selected.hasSameIdentity(as: client(30)))
            precondition(notice.destination.hasSameIdentity(as: a))
            notices += 1
        }
        try! recovered.stop() // mimic owner health recovery, outside coordinator operation
        recovered.onStoppedOutput?(ProcessMeter.StoppedOutput(destination: a, reason: SimulatedRouteOwner.Fault.cleanup))
        precondition(notices == 1 && routes.routes.count == 1 && routes.routes[0] === survivor)
        var failures = 0
        routes.onFailure = { error in
            precondition(error.client.hasSameIdentity(as: client(31))); failures += 1
        }
        (survivor.owner as! SimulatedRouteOwner).stopFault = .restore
        expectFailure { try survivor.owner.stop() }
        survivor.owner.onFailure?(SimulatedRouteOwner.Fault.restore)
        precondition(failures == 1 && routes.routes.count == 1)
        (survivor.owner as! SimulatedRouteOwner).stopFault = nil
        try! survivor.owner.stop() // automatic retry completion removes retained entry
        precondition(routes.routes.isEmpty)
        print("Route registry (simulated lifecycle): independent start/switch/stop/recovery, shared output, identity/capacity/monitor guards, partial starts, retained failures and all-owner Quit: passed")

        controllerWorkflow(devices: devices)
    }

    static func controllerWorkflow(devices: [AudioDevice]) {
        _ = NSApplication.shared
        var owners: [SimulatedRouteOwner] = []
        let routes = AudioRoutes { let owner = SimulatedRouteOwner(); owners.append(owner); return owner }
        let properties = SimulatedAudioDeviceProperties()
        let controller = AudioRouterApp(audio: AudioDevices(properties: properties), routes: routes,
                                      processes: SimulatedProcessInventory(clients: [client(41), client(42), client(43)]))
        controller.refreshInventory()
        func choose(_ row: ApplicationAudioRow, destination: AudioDevice?) {
            let picker = row.destinationPicker
            picker.menu!.delegate?.menuWillOpen?(picker.menu!)
            if let destination {
                let item = picker.itemArray.first {
                    guard case .hardware(let device) = $0.representedObject as? AppOutputSelection else { return false }
                    return device.hasSameIdentity(as: destination)
                }!
                precondition(item.isEnabled)
                picker.select(item)
            } else { picker.selectItem(at: 0) }
            picker.menu!.delegate?.menuDidClose?(picker.menu!)
            precondition(NSApp.sendAction(picker.action!, to: picker.target, from: picker))
        }
        let rows = controller.panel.applicationRows
        precondition(!rows[0].gainSlider.isEnabled && !rows[0].muteButton.isEnabled)
        choose(rows[0], destination: devices.first!)
        precondition(rows[0].gainSlider.isEnabled && rows[0].gainSlider.doubleValue == 1)
        let outputMenu = rows[0].destinationPicker.menu
        rows[0].gainSlider.doubleValue = 0.35
        precondition(NSApp.sendAction(rows[0].gainSlider.action!, to: rows[0].gainSlider.target, from: rows[0].gainSlider))
        precondition(abs(owners[0].playbackLevel.gain - 0.35) < 0.00001 && !owners[0].playbackLevel.muted)
        rows[0].muteButton.state = .on
        precondition(NSApp.sendAction(rows[0].muteButton.action!, to: rows[0].muteButton.target, from: rows[0].muteButton))
        precondition(owners[0].playbackLevel.muted && rows[0].gainLabel.stringValue == "35%")
        precondition(rows[0].destinationPicker.menu === outputMenu)
        precondition(rows[1].destinationPicker.isEnabled)
        choose(rows[1], destination: devices.last!)
        precondition(routes.routes.count == 2)
        precondition(rows[0].destinationPicker.titleOfSelectedItem == devices.first!.name)
        precondition(rows[1].destinationPicker.titleOfSelectedItem == devices.last!.name)
        choose(rows[0], destination: devices.last!)
        precondition(owners[0].stops == 1 && owners[1].stops == 0)
        precondition(owners[2].playbackLevel == owners[0].playbackLevel && owners[1].playbackLevel == .unity)
        precondition(properties.writes.isEmpty)
        choose(rows[1], destination: nil)
        precondition(owners[1].stops == 1 && owners[2].stops == 0) // client 42, not last-started 41
        choose(rows[0], destination: nil)
        precondition(routes.routes.isEmpty)
        choose(rows[0], destination: devices.first!)
        let monitorPicker = controller.panel.monitorPicker
        monitorPicker.selectItem(at: 3)
        precondition(NSApp.sendAction(monitorPicker.action!, to: monitorPicker.target, from: monitorPicker))
        let monitor = controller.panel.monitorButton
        precondition(monitor.isEnabled && NSApp.sendAction(monitor.action!, to: monitor.target, from: monitor))
        precondition(routes.routes.count == 2 && routes.routes.last!.isMonitor)
        precondition(rows[0].gainSlider.doubleValue == 1 && rows[0].muteButton.state == .off)
        precondition(!rows[2].gainSlider.isEnabled && !rows[2].muteButton.isEnabled)
        // Inventory loss retains owned app rows and their Original output action.
        let retained = AudioRouterApp(audio: AudioDevices(properties: SimulatedAudioDeviceProperties()), routes: routes,
                                    processes: SimulatedProcessInventory(clients: []))
        retained.refreshInventory()
        precondition(retained.panel.applicationRows.count == 2)
        precondition(retained.panel.applicationRows.allSatisfy { $0.destinationPicker.isEnabled })
        let retainedMonitor = retained.panel.applicationRows.first { $0.client.hasSameIdentity(as: client(43)) }!
        choose(retainedMonitor, destination: nil)
        precondition(routes.routes.count == 1 && !routes.routes[0].isMonitor)
        precondition(retained.applicationShouldTerminate(NSApp) == .terminateNow)
        precondition(routes.routes.isEmpty)
        print("Production app-row routing/gain/stop, retained monitor-stop and Quit actions with simulated lifecycle/inventory: passed (no live capture or host writes)")
    }
}
