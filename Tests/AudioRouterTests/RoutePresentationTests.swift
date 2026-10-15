import AppKit

@MainActor
enum RoutePresentationTests {
    static func run() {
        func state(resources: Bool = true, running: Bool = true, stopping: Bool = false,
                   restoring: Bool = false, suppressed: Bool = false,
                   destination: Bool = true, ready: Bool = false, pending: Bool = false) -> RoutePresentation {
            RoutePresentation(hasResources: resources, isRunning: running, isStopping: stopping,
                restorationPending: restoring, suppressionRequested: suppressed,
                hasDestination: destination, canSuppressOriginal: ready, exclusiveOutputPending: pending)
        }
        let idle = state(resources: false, running: false, destination: false)
        precondition(idle.title == "No active route")
        let waiting = state()
        precondition(waiting.title == "Starting…")
        let ready = state(ready: true)
        precondition(ready.title == "Also playing on original output")
        precondition(ready.detail.contains("Choose Original output") && ready.detail.contains("restart"))
        let pending = state(pending: true)
        precondition(pending.title == "Starting…" && pending.detail.contains("automatically"))
        // Ready PCM still describes deferred automatic suppression, not opt-in.
        let pendingReady = state(ready: true, pending: true)
        precondition(pendingReady == pending)
        let pendingRestore = state(restoring: true, ready: true, pending: true)
        precondition(pendingRestore.title.contains("restoration pending"))
        let pendingStop = state(stopping: true, pending: true)
        precondition(pendingStop.title == "Audio cleanup pending")
        let exclusive = state(suppressed: true)
        precondition(exclusive.title.isEmpty && exclusive.detail.contains("not a measurement"))
        let restoring = state(restoring: true, ready: true)
        precondition(restoring.title.contains("restoration pending"))
        precondition(restoring.detail.contains("Choose Original output"))
        let stopping = state(stopping: true, suppressed: true, ready: true)
        precondition(stopping.title == "Audio cleanup pending")
        let retained = state(running: false, ready: true)
        precondition(retained.title == "Audio cleanup pending" && retained.detail.contains("Choose Original output"))
        let monitor = state(destination: false, ready: true)
        precondition(monitor.title.contains("Monitoring"))
        // Priority: failed restoration must never be displayed as a ready or
        // successfully exclusive route, even with stale confirmation facts.
        let ambiguous = state(stopping: true, restoring: true, suppressed: true, ready: true)
        precondition(ambiguous == restoring)
        print("Route presentation: idle, monitor, deferred exclusive startup, ready, suppression request, restoration/cleanup retention: passed")

        _ = NSApplication.shared
        let panel = AudioPopover()
        _ = panel.view
        let inventory = try! AudioDevices(properties: SimulatedAudioDeviceProperties()).inventory()
        let outputs = try! inventory.outputs.get()
        for row in panel.systemRows {
            row.update(devices: try! inventory.devices(for: row.role), selectedID: row.role == .input ? 102 : 101,
                       volumeValue: row.role == .soundEffects ? nil : 0.5, muted: row.role == .soundEffects ? nil : false)
        }
        func client(_ id: UInt32, birth: UInt64 = 123) -> AudioProcess {
            AudioProcess(id: id, pid: Int32(id), birth: ProcessBirth(seconds: birth, microseconds: 1), bundleID: "test.audio.app", outputDeviceIDs: nil)
        }
        precondition(!client(1).hasSameIdentity(as: client(1, birth: 456))) // PID/object reuse
        let unidentified = AudioProcess(id: 1, pid: nil, birth: nil, bundleID: nil, outputDeviceIDs: nil)
        precondition(!unidentified.hasSameIdentity(as: unidentified))
        let rows = (1...12).map { id in
            ApplicationAudioRow(client: client(UInt32(id)), name: "Audio App \(id)", icon: nil,
                                devices: outputs, canCapture: true)
        }
        let destination = outputs.last!
        for row in rows {
            row.update(isOwner: row === rows[0], canStart: true, canChangeDestination: true, destination: destination, state: exclusive)
        }
        precondition(rows[0].destinationPicker.isEnabled)
        precondition(rows[1].destinationPicker.isEnabled) // another route can start independently
        rows[1].update(isOwner: false, canStart: false, canChangeDestination: false, destination: nil, state: idle)
        precondition(!rows[1].destinationPicker.isEnabled) // capacity/duplicate-process guard
        precondition(rows[0].statusLabel.stringValue.isEmpty && rows[0].statusLabel.isHidden)
        precondition(rows[2].statusLabel.stringValue.isEmpty && rows[2].statusLabel.isHidden)
        var actionCount = 0
        rows[0].onSelection = { selected, selection in
            precondition(selected.hasSameIdentity(as: client(1)))
            switch selection {
            case .original: actionCount += 1
            case .hardware(let chosen):
                precondition(chosen.hasSameIdentity(as: destination)); actionCount += 1
            }
        }
        let picker = rows[0].destinationPicker
        precondition(picker.numberOfItems == 2) // Original plus actual destination, no expanded choices
        picker.menu!.delegate?.menuWillOpen?(picker.menu!)
        precondition(picker.numberOfItems == outputs.count + 1)
        picker.menu!.delegate?.menuDidClose?(picker.menu!)
        precondition(NSApp.sendAction(picker.action!, to: picker.target, from: picker))
        picker.selectItem(at: 0)
        precondition(NSApp.sendAction(picker.action!, to: picker.target, from: picker))
        precondition(actionCount == 2) // action payloads preserve client/device identities
        rows[0].update(isOwner: true, canStart: false, canChangeDestination: false, destination: destination, state: restoring)
        precondition(picker.isEnabled && picker.item(at: 0)?.isEnabled == true)
        precondition(!rows[0].statusLabel.isHidden && rows[0].statusLabel.stringValue == restoring.title)
        picker.menu!.delegate?.menuWillOpen?(picker.menu!)
        precondition(picker.itemArray.dropFirst().allSatisfy { !$0.isEnabled })
        picker.menu!.delegate?.menuDidClose?(picker.menu!)
        rows[0].collapseChoices()
        let actualItem = picker.selectedItem!
        picker.selectItem(at: 0) // simulate a rejected Original output / cleanup attempt
        rows[0].update(isOwner: true, canStart: false, canChangeDestination: false, destination: destination, state: restoring)
        precondition(picker.selectedItem === actualItem) // cached menu still restores owner truth
        let missing = ApplicationAudioRow(client: client(1), name: "Retained route", icon: nil, devices: [], canCapture: false)
        missing.update(isOwner: true, canStart: false, canChangeDestination: false, destination: destination, state: stopping)
        precondition(missing.destinationPicker.isEnabled) // restoration survives inventory loss
        precondition(missing.destinationPicker.titleOfSelectedItem?.contains("unavailable") == true)
        let unsafe = ApplicationAudioRow(client: unidentified, name: "Unknown client", icon: nil, devices: outputs, canCapture: false)
        unsafe.update(isOwner: false, canStart: true, canChangeDestination: true, destination: nil, state: idle)
        precondition(!unsafe.destinationPicker.isEnabled)
        rows[0].update(isOwner: true, canStart: false, canChangeDestination: true, destination: destination, state: exclusive)
        panel.setApplicationRows(Array(rows.prefix(3)))
        panel.applicationsHint.stringValue = ""
        panel.applicationsHint.isHidden = true
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(panel.view)
        precondition(!controls.compactMap { ($0 as? NSTextField)?.stringValue }.contains("Selected app · route controls"))
        let titles = controls.compactMap { ($0 as? NSButton)?.title }
        precondition(!titles.contains("Use exclusively") && !titles.contains("Stop & restore original"))
        panel.diagnosticsLabel.stringValue = "Peak: 100%\nBuffer: 20 underruns, 30 dropped packets\n12 active clients; 2 with unknown output activity. Active I/O does not prove audibility."
        panel.resizeToFit(maximumHeight: 740)
        let compact = panel.preferredContentSize
        precondition(compact.width == 580 && compact.height > 400 && compact.height <= 741)
        panel.setDiagnosticsVisible(true)
        let expanded = panel.preferredContentSize
        precondition(expanded.height <= 741)
        panel.setDiagnosticsVisible(false)
        precondition(abs(panel.preferredContentSize.height - compact.height) < 1)
        panel.setApplicationRows(rows)
        precondition(panel.applicationRows.count == 12 && panel.applicationScroll.hasVerticalScroller)
        precondition(panel.preferredContentSize.height <= 741)
        // Native menu objects grow with clients + destinations, never their
        // product. Expanding the next row releases the previous row's choices.
        for row in rows { row.update(isOwner: false, canStart: true, canChangeDestination: true, destination: nil, state: idle) }
        for row in rows {
            row.destinationPicker.menu!.delegate?.menuWillOpen?(row.destinationPicker.menu!)
            precondition(row.destinationPicker.numberOfItems == outputs.count + 1)
            precondition(rows.reduce(0) { $0 + $1.destinationPicker.numberOfItems } == rows.count + outputs.count)
            row.destinationPicker.menu!.delegate?.menuDidClose?(row.destinationPicker.menu!)
        }
        for row in rows { row.update(isOwner: row === rows[0], canStart: true, canChangeDestination: true, destination: destination, state: exclusive) }
        panel.setDiagnosticsVisible(true)
        // The removed section now fits at 560pt; use a genuinely short
        // viewport to continue exercising outer-scroll reachability.
        panel.resizeToFit(maximumHeight: 360)
        precondition(panel.preferredContentSize.height <= 360)
        panel.view.setFrameSize(panel.preferredContentSize)
        panel.view.layoutSubtreeIfNeeded()
        let outer = panel.view.subviews.first as! NSScrollView
        let document = outer.documentView!
        precondition(document.bounds.height > outer.documentVisibleRect.height)
        let quitRect = panel.quitButton.convert(panel.quitButton.bounds, to: document)
        precondition(quitRect.maxY <= document.bounds.maxY + 1)
        document.scrollToVisible(quitRect)
        precondition(outer.documentVisibleRect.intersects(quitRect))
        let appDocument = panel.applicationScroll.documentView!
        let lastRowRect = rows.last!.convert(rows.last!.bounds, to: appDocument)
        precondition(appDocument.bounds.height >= CGFloat(rows.count) * ApplicationAudioRow.rowHeight)
        appDocument.scrollToVisible(lastRowRect)
        precondition(panel.applicationScroll.documentVisibleRect.intersects(lastRowRect))
        panel.setDiagnosticsVisible(false)
        panel.resizeToFit(maximumHeight: 740)
        precondition(panel.systemRows.first { $0.role == .output }!.volume.accessibilityLabel()?.contains("all apps") == true)
        precondition(rows[0].destinationPicker.accessibilityLabel()?.contains("does not change system default") == true)
        precondition(rows[0].destinationPicker.accessibilityLabel()?.contains("starts exclusive routing") == true)
        print("App row typed actions/identity, independent availability/capacity, retained cleanup, unknown client, lazy bounded menu expansion and scrollable layout/accessibility: passed")

        // Optional visual verification of the actual production view. No app
        // capture, device startup, system writes or on-screen window required.
        if let path = ProcessInfo.processInfo.environment["SOUNDTOOL_UI_SNAPSHOT"] {
            panel.setApplicationRows(Array(rows.prefix(3)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel.preferredContentSize), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = panel.view
            panel.view.wantsLayer = true
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                panel.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            panel.view.setFrameSize(panel.preferredContentSize)
            panel.view.layoutSubtreeIfNeeded()
            let bitmap = panel.view.bitmapImageRepForCachingDisplay(in: panel.view.bounds)!
            panel.view.cacheDisplay(in: panel.view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            print("Read-only production UI snapshot: \(path)")
        }
        print("Read-only AppKit System/Application layout: \(Int(compact.height)) pt compact, \(Int(expanded.height)) pt diagnostics")
    }
}
