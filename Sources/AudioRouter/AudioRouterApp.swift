import AppKit
import CoreAudio

@MainActor
final class AudioRouterApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let audio: AudioDevices
    private let processes: any AudioProcessInventory
    let routes: AudioRoutes
    let panel = AudioPopover()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var inventoryDetail = ""
    private var lastNotice: String?
    private var pendingErrors: [String] = []
    private var presentingError = false
    private var inventoryRefreshPending = false
    private var stateRefreshPending = false
    private var displayedSymbol: String?
    private struct RenderedRoute: Equatable {
        let id: UUID
        let destination: UInt32?
        let state: RoutePresentation
    }
    private var renderedRoutes: [RenderedRoute] = []
    private struct DisplayedClient {
        let client: AudioProcess
        let name: String
        let icon: NSImage?
    }

    init(audio: AudioDevices = AudioDevices(), routes: AudioRoutes = AudioRoutes(),
         processes: any AudioProcessInventory = AudioProcesses()) {
        self.audio = audio
        self.routes = routes
        self.processes = processes
        super.init()
        _ = panel.view
        panel.onMenuTrackingEnded = { [weak self] in
            // AppKit may close a menu before sending its selection action.
            // Leave that item/row alive until the next main-loop turn.
            DispatchQueue.main.async { [weak self] in self?.flushPendingRefresh() }
        }
        bind(panel.monitorPicker, #selector(monitorSelectionChanged(_:)))
        bind(panel.monitorButton, #selector(startMonitoring(_:)))
        bind(panel.diagnosticsToggle, #selector(toggleDiagnostics(_:)))
        bind(panel.refreshButton, #selector(refresh(_:)))
        bind(panel.quitButton, #selector(quit(_:)))
        for row in panel.systemRows {
            row.onSelection = { [weak self] role, device in
                guard let self else { return }
                self.performAudioAction(recordRouteNotice: false) { try self.audio.select(device, for: role) }
                self.refreshInventory()
            }
            row.onVolume = { [weak self, weak row] role, device, value in
                guard let self, let row else { return }
                self.performAudioAction(recordRouteNotice: false) { try self.audio.setVolume(value, for: device, role: role) }
                self.refreshLevels(row, device: device)
            }
            row.onMute = { [weak self, weak row] role, device, muted in
                guard let self, let row else { return }
                self.performAudioAction(recordRouteNotice: false) { try self.audio.setMute(muted, for: device, role: role) }
                self.refreshLevels(row, device: device)
            }
        }
        routes.onChange = { [weak self] in self?.refreshState() }
        routes.onFailure = { [weak self] error in
            guard let self else { return }
            self.lastNotice = error.localizedDescription
            self.refreshState(force: true)
            self.showError(error)
        }
        routes.onStoppedOutput = { [weak self] client, notice in
            guard let self else { return }
            self.lastNotice = "\(self.displayName(client)): stopped output to \(notice.destination.name). \(notice.message)"
            self.refreshState(force: true)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePopover(_:))
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.delegate = self
        refreshState(force: true)
        observeSystemDevices()
    }

    private func bind(_ control: NSControl, _ action: Selector) { control.target = self; control.action = action }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem?.button else { return }
        refreshInventory()
        let screenHeight = button.window?.screen?.visibleFrame.height ?? 800
        panel.resizeToFit(maximumHeight: max(1, screenHeight - 80))
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentSize = panel.preferredContentSize
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool { panel.view.window?.attachedSheet == nil }
    @objc private func refresh(_ sender: Any?) { refreshInventory() }
    private var selectedMonitor: AudioProcess? { panel.monitorPicker.selectedItem?.representedObject as? AudioProcess }

    // Names/icons are display only. Routing carries original parsed identity
    // snapshots; ProcessMeter revalidates them immediately before capture.
    private func runningApplication(_ client: AudioProcess) -> NSRunningApplication? {
        guard let pid = client.pid, let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == client.bundleID else { return nil }
        return app
    }
    private func displayName(_ client: AudioProcess) -> String {
        runningApplication(client)?.localizedName ?? client.label
    }
    private func displayClient(_ client: AudioProcess) -> DisplayedClient {
        let app = runningApplication(client)
        return DisplayedClient(client: client, name: app?.localizedName ?? client.label, icon: app?.icon)
    }
    private func recordStopped(_ client: AudioProcess) {
        lastNotice = "\(displayName(client)): original playback restoration and cleanup completed. Other routes are unchanged."
    }
    private func isOwnAudioClient(_ client: AudioProcess) -> Bool {
        if client.pid == ProcessInfo.processInfo.processIdentifier { return true }
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return client.bundleID == bundleID
    }
    private func canCapture(_ client: AudioProcess) -> Bool {
        client.isIdentified && !isOwnAudioClient(client)
    }

    @discardableResult
    private func refreshSystemControls() -> [AudioDevice] {
        do {
            let inventory = try audio.inventory()
            for row in panel.systemRows {
                let devices = (try? inventory.devices(for: row.role)) ?? []
                let selectedID = try? audio.defaultDevice(for: row.role)
                let device = devices.first { $0.id == selectedID }
                let value = row.role != .soundEffects ? device.flatMap { try? audio.volume(for: $0) } : nil
                let muted = row.role != .soundEffects ? device.flatMap { try? audio.isMuted($0) } : nil
                row.update(devices: devices, selectedID: selectedID, volumeValue: value, muted: muted)
            }
            return (try? inventory.outputs.get()) ?? []
        } catch {
            for row in panel.systemRows { row.update(devices: [], selectedID: nil, volumeValue: nil, muted: nil) }
            return []
        }
    }

    private func refreshLevels(_ row: SystemAudioRow, device: AudioDevice) {
        do {
            // Revalidate the selected live identity, then read back only this
            // row. Slider drags do not rebuild app menus or input/output lists.
            let controls = try audio.currentControls(for: device, role: row.role)
            row.updateLevels(volumeValue: controls.volume, muted: controls.muted)
        } catch { refreshSystemControls() }
    }

    // Internal for read-only production UI tests; no capture is started here.
    func refreshInventory() {
        guard !panel.isTrackingMenu else { inventoryRefreshPending = true; return }
        inventoryRefreshPending = false
        let outputs = refreshSystemControls()
        let oldMonitor = selectedMonitor
        panel.monitorPicker.removeAllItems()
        panel.monitorPicker.addItem(withTitle: "Choose a client to monitor…")
        var displayedClients: [DisplayedClient] = []
        do {
            let snapshot = try processes.snapshot()
            displayedClients = snapshot.activeOutputClients.filter { !isOwnAudioClient($0) }.map(displayClient)
            inventoryDetail = "\(displayedClients.count) external active output clients; \(snapshot.unknownActivityCount) with unknown output activity. Active I/O does not prove audibility."
            panel.applicationsHint.stringValue = displayedClients.isEmpty ? "Play audio in an app, then Refresh." : ""
            for displayed in displayedClients {
                let client = displayed.client
                panel.monitorPicker.addItem(withTitle: "\(displayed.name) · \(client.pid.map { "PID \($0)" } ?? "PID unknown")")
                let item = panel.monitorPicker.lastItem!
                item.representedObject = client
                if let oldMonitor, client.hasSameIdentity(as: oldMonitor) { panel.monitorPicker.select(item) }
            }
        } catch {
            inventoryDetail = "Audio client inventory unavailable · Refresh to retry"
            panel.applicationsHint.stringValue = inventoryDetail
        }
        // Keep a route's row accessible even after the active-I/O inventory
        // loses it. This is owned context, not a claim of continued activity.
        for route in routes.routes where !displayedClients.contains(where: { $0.client.hasSameIdentity(as: route.client) }) {
            displayedClients.insert(displayClient(route.client), at: 0)
        }
        panel.applicationsHint.isHidden = panel.applicationsHint.stringValue.isEmpty
        let counts = Dictionary(displayedClients.map { ($0.name, 1) }, uniquingKeysWith: +)
        let outputNames = Dictionary(uniqueKeysWithValues: outputs.map { ($0.id, $0.name) })
        let routingDestinations = outputs.filter(\.isMirrorDestination)
        let existingRows = Dictionary(grouping: panel.applicationRows, by: { $0.client.id })
        let rows = displayedClients.map { displayed in
            let client = displayed.client
            let name = counts[displayed.name, default: 0] > 1 ? "\(displayed.name) · \(client.pid.map(String.init) ?? "unknown PID")" : displayed.name
            let row: ApplicationAudioRow
            if let existing = existingRows[client.id]?.first(where: { $0.client.hasSameIdentity(as: client) }) {
                row = existing
                row.updateInventory(client: client, name: name, icon: displayed.icon, devices: routingDestinations, canCapture: canCapture(client))
            } else {
                row = ApplicationAudioRow(client: client, name: name, icon: displayed.icon, devices: routingDestinations, canCapture: canCapture(client))
                row.onSelection = { [weak self] client, selection in self?.selectAppOutput(client: client, selection: selection) }
                row.onLevel = { [weak self, weak row] client, level in
                    guard let self, let row else { return }
                    do { try self.routes.setPlaybackLevel(level, for: client) }
                    catch { self.showError(error) }
                    let owned = self.routes.route(for: client)
                    row.updatePlaybackLevel(owned?.owner.playbackLevel ?? .unity, canAdjust: owned?.canAdjustLevel == true)
                }
            }
            let reported = client.outputDeviceIDs.map { ids in
                ids.isEmpty ? "not reported" : ids.map { outputNames[$0] ?? "device \($0)" }.joined(separator: ", ")
            } ?? "unknown"
            row.toolTip = "\(client.label) · \(client.pid.map { "PID \($0)" } ?? "PID unknown"). Active I/O is not proof of audibility. Reported app outputs: \(reported)."
            return row
        }
        panel.setApplicationRows(rows)
        refreshState(force: true)
    }

    private func flushPendingRefresh() {
        guard !panel.isTrackingMenu else { return }
        if inventoryRefreshPending { refreshInventory() }
        else if stateRefreshPending { refreshState(force: true) }
    }

    @objc private func monitorSelectionChanged(_ sender: Any?) { refreshState(force: true) }
    private func refreshState(force: Bool = false) {
        let idle = RoutePresentation(hasResources: false, isRunning: false,
            isStopping: false, restorationPending: false, suppressionRequested: false,
            hasDestination: false, canSuppressOriginal: false)
        let snapshot = routes.routes.map { RenderedRoute(id: $0.id, destination: $0.owner.mirrorDestination?.id, state: $0.presentation) }
        statusItem?.button?.toolTip = "AudioRouter — \(routes.routes.count) owned audio routes"
        let symbol = routes.routes.isEmpty ? "speaker.wave.2" : "waveform"
        if displayedSymbol != symbol {
            displayedSymbol = symbol
            statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AudioRouter")
        }
        guard force || popover.isShown else { return }
        // Audio owners continue polling/restoring in common run-loop modes.
        // Only destructive presentation/inventory updates wait for menu close.
        guard !panel.isTrackingMenu else { stateRefreshPending = true; return }
        stateRefreshPending = false
        if panel.diagnosticsToggle.state == .on {
            panel.diagnosticsLabel.stringValue = (routes.routes.map {
                "\(displayName($0.client)) · PID \($0.client.pid.map(String.init) ?? "unknown"): \($0.presentation.detail)\nPeak: \(Int($0.owner.peak * 100))% · \($0.owner.transportStatus ?? "capture only")"
            } + [inventoryDetail]).joined(separator: "\n")
        }
        // Level changes read back only PCM controls, not inventory/menus/layout.
        for row in panel.applicationRows {
            let owned = routes.route(for: row.client)
            row.updatePlaybackLevel(owned?.owner.playbackLevel ?? .unity, canAdjust: owned?.canAdjustLevel == true)
        }
        // Health/peak ticks do not rebuild every app menu or resize the panel.
        if force || renderedRoutes != snapshot {
            renderedRoutes = snapshot
            panel.noticeLabel.stringValue = lastNotice ?? ""
            panel.noticeLabel.isHidden = lastNotice == nil
            for row in panel.applicationRows {
                let owned = routes.route(for: row.client)
                row.update(isOwner: owned != nil, canStart: canCapture(row.client) && routes.canStart(row.client),
                    canChangeDestination: owned?.canReplace == true,
                    destination: owned?.owner.mirrorDestination, state: owned?.presentation ?? idle,
                    level: owned?.owner.playbackLevel ?? .unity, canAdjustLevel: owned?.canAdjustLevel == true)
            }
            panel.monitorButton.isEnabled = selectedMonitor.map { canCapture($0) && routes.canStart($0, monitoring: true) } == true
            panel.resizeToFit()
            panel.view.window?.recalculateKeyViewLoop()
            if popover.isShown { popover.contentSize = panel.preferredContentSize }
        }
    }

    @objc private func toggleDiagnostics(_ sender: NSButton) {
        panel.setDiagnosticsVisible(sender.state == .on)
        refreshState(force: true)
    }

    private func selectAppOutput(client: AudioProcess, selection: AppOutputSelection) {
        performAudioAction {
            switch selection {
            case .original:
                try routes.select(client: client, destination: nil)
                recordStopped(client)
            case .hardware(let destination):
                guard canCapture(client) else { return }
                try routes.select(client: client, destination: destination)
                lastNotice = nil
            }
        }
    }

    @objc private func startMonitoring(_ sender: Any?) {
        guard let client = selectedMonitor, canCapture(client), routes.canStart(client, monitoring: true) else { return }
        performAudioAction {
            try routes.start(client: client, destination: nil)
            lastNotice = nil
        }
    }

    private func performAudioAction(recordRouteNotice: Bool = true, _ action: () throws -> Void) {
        do { try action() }
        catch {
            if recordRouteNotice { lastNotice = error.localizedDescription }
            showError(error)
        }
        if recordRouteNotice { refreshState(force: true) }
    }

    private func observeSystemDevices() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyProcessObjectList] + SystemAudioRole.allCases.map(\.selector) {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if selector == kAudioHardwarePropertyProcessObjectList { self.releaseRoutesIfClientsGone() }
                    if self.popover.isShown { self.refreshInventory() }
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main, listener)
            if status != noErr { NSLog("AudioRouter: audio notification registration failed: %d", status) }
        }
    }

    private func releaseRoutesIfClientsGone() {
        for route in routes.routes where !route.owner.isStopping && !route.owner.restorationPending {
            guard (try? processes.stillContains(route.client)) == false else { continue }
            performAudioAction { try routes.stop(route) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do { try routes.stopAll(); return .terminateNow }
        catch { refreshState(force: true); showError(error); return .terminateCancel }
    }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func showError(_ error: Error) {
        panel.cancelMenuTracking()
        let message = error.localizedDescription
        if !pendingErrors.contains(message) { pendingErrors.append(message) }
        presentNextError()
    }

    private func presentNextError() {
        // Independent owners can fault on the same health tick. Serialize their
        // alerts rather than attach competing sheets to the popover window.
        guard !presentingError, !pendingErrors.isEmpty else { return }
        presentingError = true
        let alert = NSAlert()
        alert.messageText = "AudioRouter couldn’t complete the audio operation"
        alert.informativeText = pendingErrors.removeFirst()
        alert.alertStyle = .warning
        if popover.isShown, let window = panel.view.window {
            alert.beginSheetModal(for: window) { [weak self] _ in
                guard let self else { return }
                self.presentingError = false
                self.presentNextError()
            }
        } else {
            alert.runModal()
            presentingError = false
            presentNextError()
        }
    }
}
