import Foundation

/// The existing lifecycle remains the sole owner of each route's HAL resources.
/// This port lets registry/failure policy be exercised without live capture.
@MainActor
protocol AudioRouteOwner: AnyObject {
    var hasResources: Bool { get }
    var isRunning: Bool { get }
    var isStopping: Bool { get }
    var restorationPending: Bool { get }
    var suppressionRequested: Bool { get }
    var canSuppressOriginal: Bool { get }
    var exclusiveOutputPending: Bool { get }
    var mirrorDestination: AudioDevice? { get }
    var peak: Float { get }
    var transportStatus: String? { get }
    var onLevel: ((Float) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var onStoppedOutput: ((ProcessMeter.StoppedOutput) -> Void)? { get set }
    var onStateChange: (() -> Void)? { get set }
    func start(client: AudioProcess, mirroringTo: AudioDevice?, suppressWhenReady: Bool) throws
    func stop() throws
    func restoreOriginalPlayback() throws
    func suppressOriginalPlayback() throws
}

extension ProcessMeter: AudioRouteOwner {}

@MainActor
final class AudioRoutes {
    // Four owners bound taps, IOProcs, output units and timers. Each hardware
    // route has a 128 KiB PCM FIFO: at most 512 KiB total FIFO storage. HAL/AU
    // allocations are additional, host-dependent, and not measured here.
    static let capacity = 4

    @MainActor
    final class Route: Identifiable {
        let id = UUID()
        let client: AudioProcess
        let owner: any AudioRouteOwner
        let isMonitor: Bool
        fileprivate var operating = false
        init(client: AudioProcess, owner: any AudioRouteOwner, isMonitor: Bool) {
            self.client = client
            self.owner = owner
            self.isMonitor = isMonitor
        }
        var presentation: RoutePresentation {
            RoutePresentation(hasResources: owner.hasResources, isRunning: owner.isRunning,
                isStopping: owner.isStopping, restorationPending: owner.restorationPending,
                suppressionRequested: owner.suppressionRequested, hasDestination: owner.mirrorDestination != nil,
                canSuppressOriginal: owner.canSuppressOriginal, exclusiveOutputPending: owner.exclusiveOutputPending)
        }
        var canReplace: Bool {
            owner.isRunning && !owner.isStopping && !owner.restorationPending && owner.mirrorDestination != nil
        }
    }

    enum Failure: LocalizedError {
        case capacity, unidentified, duplicateClient, monitorExists, cleanupPending
        var errorDescription: String? {
            switch self {
            case .capacity: "AudioRouter supports up to four owned routes, including monitoring. Stop a route before adding another."
            case .unidentified: "The audio client's lifetime identity is unavailable. Refresh and try again."
            case .duplicateClient: "This process already has an owned route. Restore and clean it up before starting another capture of that process."
            case .monitorExists: "Stop the existing diagnostics monitor before starting another monitor."
            case .cleanupPending: "This route is monitoring or has restoration/cleanup pending. Choose Original output before replacing it."
            }
        }
    }

    struct OperationFailure: LocalizedError {
        let client: AudioProcess
        let reason: Error
        var errorDescription: String? { "\(client.label) (PID \(client.pid.map(String.init) ?? "unknown")): \(reason.localizedDescription)" }
    }
    struct StopFailures: LocalizedError {
        let failures: [OperationFailure]
        var errorDescription: String? { failures.map(\.localizedDescription).joined(separator: "\n") }
    }

    private let makeOwner: () -> any AudioRouteOwner
    private(set) var routes: [Route] = []
    var onChange: (() -> Void)?
    var onFailure: ((OperationFailure) -> Void)?
    var onStoppedOutput: ((AudioProcess, ProcessMeter.StoppedOutput) -> Void)?

    init(makeOwner: @escaping () -> any AudioRouteOwner = { ProcessMeter() }) { self.makeOwner = makeOwner }

    func route(for client: AudioProcess) -> Route? {
        routes.first { $0.client.hasSameIdentity(as: client) }
    }
    private func conflicts(_ client: AudioProcess) -> Bool {
        // A second HAL object for the same PID is not a separate app. Also
        // block reused IDs/PIDs while a previous owner's cleanup is unresolved.
        routes.contains { $0.client.id == client.id || $0.client.pid == client.pid }
    }
    private func startFailure(_ client: AudioProcess, monitoring: Bool) -> Failure? {
        if !client.isIdentified { return .unidentified }
        if conflicts(client) { return .duplicateClient }
        if routes.count >= Self.capacity { return .capacity }
        if monitoring && routes.contains(where: { $0.isMonitor }) { return .monitorExists }
        return nil
    }
    func canStart(_ client: AudioProcess, monitoring: Bool = false) -> Bool {
        startFailure(client, monitoring: monitoring) == nil
    }

    @discardableResult
    func start(client: AudioProcess, destination: AudioDevice?) throws -> Route {
        if let failure = startFailure(client, monitoring: destination == nil) { throw failure }
        let route = Route(client: client, owner: makeOwner(), isMonitor: destination == nil)
        routes.append(route) // Install ownership BEFORE any partial setup.
        route.owner.onLevel = { [weak self] _ in self?.onChange?() }
        route.owner.onStateChange = { [weak self, weak route] in
            guard let self, let route else { return }
            self.reconcile(route)
        }
        route.owner.onFailure = { [weak self, weak route] error in
            guard let self, let route else { return }
            self.reconcile(route)
            self.onFailure?(OperationFailure(client: route.client, reason: error))
        }
        route.owner.onStoppedOutput = { [weak self, weak route] notice in
            guard let self else { return }
            if let route { self.reconcile(route) }
            self.onStoppedOutput?(client, notice)
        }
        try operate(route) {
            try route.owner.start(client: client, mirroringTo: destination, suppressWhenReady: destination != nil)
        }
        return route
    }

    func select(client: AudioProcess, destination: AudioDevice?) throws {
        if let existing = route(for: client) {
            if destination != nil {
                guard existing.canReplace else { throw Failure.cleanupPending }
            }
            try stop(existing) // Failure retains this owner and blocks replacement only here.
        }
        if let destination { try start(client: client, destination: destination) }
    }

    func stop(_ route: Route) throws { try operate(route) { try route.owner.stop() } }
    func toggleSuppression(_ route: Route) throws {
        try operate(route) {
            if route.owner.suppressionRequested || route.owner.restorationPending { try route.owner.restoreOriginalPlayback() }
            else { try route.owner.suppressOriginalPlayback() }
        }
    }

    func stopAll() throws {
        var failures: [OperationFailure] = []
        // Snapshot: successful operations remove entries; failure must never
        // short-circuit restoration of later owners during Quit.
        for route in routes {
            do { try stop(route) }
            catch { failures.append(OperationFailure(client: route.client, reason: error)) }
        }
        if !failures.isEmpty { throw StopFailures(failures: failures) }
    }

    private func operate(_ route: Route, _ action: () throws -> Void) throws {
        guard routes.contains(where: { $0 === route }), !route.operating else { throw Failure.cleanupPending }
        route.operating = true
        defer { route.operating = false; reconcile(route) }
        try action()
    }
    private func reconcile(_ route: Route) {
        // Stop emits intermediate restoration callbacks. Never release the
        // owner or permit a new start while its operation is still executing.
        guard !route.operating else { return }
        if !route.owner.hasResources {
            routes.removeAll { $0 === route }
            // Keep callbacks until owner release: a completed recovery notice
            // can follow Stop's state callback in the same health poll.
        }
        onChange?()
    }
}
