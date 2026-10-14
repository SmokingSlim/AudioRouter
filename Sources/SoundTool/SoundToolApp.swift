import AppKit
import CoreAudio

@MainActor
final class SoundToolApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let audio: AudioDevices
    private let processes: any AudioProcessInventory
    let routes: AudioRoutes
    let panel = AudioPopover()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var selectedRouteID: UUID?
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
    private var renderedSelection: UUID?

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
        bind(panel.routePicker, #selector(routeSelectionChanged(_:)))
        bind(panel.suppressionButton, #selector(toggleSuppression(_:)))
        bind(panel.stopButton, #selector(stopMonitoring(_:)))
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
    private func displayName(_ client: AudioProcess) -> String {
        guard let pid = client.pid, let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == client.bundleID else { return client.label }
        return app.localizedName ?? client.label
    }
    private func appIcon(_ client: AudioProcess) -> NSImage? {
        guard let pid = client.pid, let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == client.bundleID else { return nil }
        return app.icon
    }
    private func canCapture(_ client: AudioProcess) -> Bool {
        client.isIdentified && client.pid != ProcessInfo.processInfo.processIdentifier && client.bundleID != Bundle.main.bundleIdentifier
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
        var clients: [AudioProcess] = []
        do {
            let snapshot = try processes.snapshot()
            clients = snapshot.activeOutputClients
            inventoryDetail = "\(clients.count) active output clients; \(snapshot.unknownActivityCount) with unknown output activity. Active I/O does not prove audibility."
            panel.applicationsHint.stringValue = clients.isEmpty ? "Play audio in an app, then Refresh." : "Experimental routing · original playback stays unmuted until ready"
            for client in clients {
                panel.monitorPicker.addItem(withTitle: "\(displayName(client)) · \(client.pid.map { "PID \($0)" } ?? "PID unknown")")
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
        for route in routes.routes where !clients.contains(where: { $0.hasSameIdentity(as: route.client) }) {
            clients.insert(route.client, at: 0)
        }
        let names = clients.map(displayName)
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        let outputNames = Dictionary(uniqueKeysWithValues: outputs.map { ($0.id, $0.name) })
        let routingDestinations = outputs.filter(\.isMirrorDestination)
        let existingRows = Dictionary(grouping: panel.applicationRows, by: { $0.client.id })
        let rows = clients.enumerated().map { index, client in
            let name = counts[names[index], default: 0] > 1 ? "\(names[index]) · \(client.pid.map(String.init) ?? "unknown PID")" : names[index]
            let row: ApplicationAudioRow
            if let existing = existingRows[client.id]?.first(where: { $0.client.hasSameIdentity(as: client) }) {
                row = existing
                row.updateInventory(client: client, name: name, icon: appIcon(client), devices: routingDestinations, canCapture: canCapture(client))
            } else {
                row = ApplicationAudioRow(client: client, name: name, icon: appIcon(client), devices: routingDestinations, canCapture: canCapture(client))
            }
            let reported = client.outputDeviceIDs.map { ids in
                ids.isEmpty ? "not reported" : ids.map { outputNames[$0] ?? "device \($0)" }.joined(separator: ", ")
            } ?? "unknown"
            row.toolTip = "\(client.label) · \(client.pid.map { "PID \($0)" } ?? "PID unknown"). Active I/O is not proof of audibility. Reported app outputs: \(reported)."
            row.onSelection = { [weak self] client, selection in self?.selectAppOutput(client: client, selection: selection) }
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
    @objc private func routeSelectionChanged(_ sender: Any?) {
        selectedRouteID = panel.routePicker.selectedItem?.representedObject as? UUID
        refreshState(force: true)
    }
    private var selectedRoute: AudioRoutes.Route? {
        routes.routes.first { $0.id == selectedRouteID }
    }

    private func refreshState(force: Bool = false) {
        if selectedRoute == nil { selectedRouteID = routes.routes.first?.id }
        let route = selectedRoute
        let state = route?.presentation ?? RoutePresentation(hasResources: false, isRunning: false,
            isStopping: false, restorationPending: false, suppressionRequested: false,
            hasDestination: false, canSuppressOriginal: false)
        let snapshot = routes.routes.map { RenderedRoute(id: $0.id, destination: $0.owner.mirrorDestination?.id, state: $0.presentation) }
        statusItem?.button?.toolTip = "SoundTool — \(routes.routes.count) owned audio routes"
        let symbol = routes.routes.isEmpty ? "speaker.wave.2" : "waveform"
        if displayedSymbol != symbol {
            displayedSymbol = symbol
            statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SoundTool")
        }
        guard force || popover.isShown else { return }
        // Audio owners continue polling/restoring in common run-loop modes.
        // Only destructive presentation/inventory updates wait for menu close.
        guard !panel.isTrackingMenu else { stateRefreshPending = true; return }
        stateRefreshPending = false
        if panel.diagnosticsToggle.state == .on {
            panel.diagnosticsLabel.stringValue = (routes.routes.map {
                "\(displayName($0.client)) · PID \($0.client.pid.map(String.init) ?? "unknown"): \($0.presentation.title)\nPeak: \(Int($0.owner.peak * 100))% · \($0.owner.transportStatus ?? "capture only")"
            } + [inventoryDetail]).joined(separator: "\n")
        }
        // Health/peak ticks do not rebuild every app menu or resize the panel.
        if force || renderedRoutes != snapshot || renderedSelection != selectedRouteID {
            renderedRoutes = snapshot
            renderedSelection = selectedRouteID
            panel.routePicker.removeAllItems()
            for owned in routes.routes {
                panel.routePicker.addItem(withTitle: "\(displayName(owned.client)) · PID \(owned.client.pid.map(String.init) ?? "unknown") → \(owned.owner.mirrorDestination?.name ?? (owned.isMonitor ? "monitor only" : "retained setup"))")
                panel.routePicker.lastItem!.representedObject = owned.id
                if owned.id == selectedRouteID { panel.routePicker.select(panel.routePicker.lastItem!) }
            }
            panel.setRouteControlsVisible(!routes.routes.isEmpty)
            panel.stateTitle.stringValue = state.title
            panel.stateDetail.stringValue = state.detail
            panel.noticeLabel.stringValue = lastNotice ?? ""
            panel.noticeLabel.isHidden = lastNotice == nil
            let needsAttention = route.map { $0.owner.isStopping || $0.owner.restorationPending || !$0.owner.isRunning } ?? false
            panel.stateTitle.isHidden = route != nil && !needsAttention
            panel.stateDetail.isHidden = !needsAttention
            panel.suppressionButton.title = state.suppressionTitle
            panel.suppressionButton.isEnabled = state.suppressionEnabled
            panel.suppressionButton.setAccessibilityLabel("\(state.suppressionTitle) for \(route.map { displayName($0.client) } ?? "selected route")")
            panel.suppressionButton.isHidden = route?.owner.mirrorDestination == nil
            panel.stopButton.title = state.stopTitle
            panel.stopButton.isEnabled = route != nil
            panel.stopButton.setAccessibilityLabel("\(state.stopTitle) for \(route.map { displayName($0.client) } ?? "selected route")")
            panel.stopButton.isHidden = route == nil
            for row in panel.applicationRows {
                let owned = routes.route(for: row.client)
                row.update(isOwner: owned != nil, canStart: canCapture(row.client) && routes.canStart(row.client),
                    canChangeDestination: owned?.canReplace == true,
                    destination: owned?.owner.mirrorDestination, state: owned?.presentation ?? state)
            }
            panel.monitorPicker.isEnabled = true
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
                lastNotice = "\(displayName(client)): original playback restoration and cleanup completed. Other routes are unchanged."
            case .hardware(let destination):
                guard canCapture(client) else { return }
                try routes.select(client: client, destination: destination)
                selectedRouteID = routes.route(for: client)?.id
                lastNotice = nil
            }
        }
    }

    @objc private func startMonitoring(_ sender: Any?) {
        guard let client = selectedMonitor, canCapture(client), routes.canStart(client, monitoring: true) else { return }
        performAudioAction {
            selectedRouteID = try routes.start(client: client, destination: nil).id
            lastNotice = nil
        }
    }

    @objc private func toggleSuppression(_ sender: Any?) {
        guard let route = selectedRoute else { return }
        performAudioAction { try routes.toggleSuppression(route) }
    }

    @objc private func stopMonitoring(_ sender: Any?) {
        guard let route = selectedRoute else { return }
        performAudioAction {
            try routes.stop(route)
            lastNotice = "\(displayName(route.client)): original playback restoration and cleanup completed. Other routes are unchanged."
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
            if status != noErr { NSLog("SoundTool: audio notification registration failed: %d", status) }
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
        alert.messageText = "SoundTool couldn’t complete the audio operation"
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
