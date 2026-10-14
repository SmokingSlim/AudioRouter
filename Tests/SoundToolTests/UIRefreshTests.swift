import AppKit

private final class MutableUIProcessInventory: AudioProcessInventory {
    var clients: [AudioProcess]
    init(_ clients: [AudioProcess]) { self.clients = clients }
    func snapshot() throws -> AudioProcessSnapshot { AudioProcessSnapshot(activeOutputClients: clients, unknownActivityCount: 0) }
    func stillContains(_ client: AudioProcess) throws -> Bool? { clients.contains { $0.hasSameIdentity(as: client) } }
}

@MainActor
enum UIRefreshTests {
    static func action(_ control: NSControl) {
        precondition(NSApp.sendAction(control.action!, to: control.target, from: control))
    }
    static func open(_ picker: NSPopUpButton) { picker.menu!.delegate?.menuWillOpen?(picker.menu!) }
    static func close(_ picker: NSPopUpButton) { picker.menu!.delegate?.menuDidClose?(picker.menu!) }
    static func drainRefresh() {
        // Fence the queued main-loop work, not a timing guess (TSan can delay it).
        var drained = false
        DispatchQueue.main.async { drained = true }
        let deadline = Date(timeIntervalSinceNow: 5)
        while !drained && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        precondition(drained, "Deferred UI refresh did not complete")
    }
    static func choose(_ row: ApplicationAudioRow, _ device: AudioDevice?) {
        open(row.destinationPicker)
        if let device {
            row.destinationPicker.select(row.destinationPicker.itemArray.first {
                guard case .hardware(let chosen) = $0.representedObject as? AppOutputSelection else { return false }
                return chosen.hasSameIdentity(as: device)
            }!)
        } else { row.destinationPicker.selectItem(at: 0) }
        close(row.destinationPicker) // AppKit closes before delivering the action
        action(row.destinationPicker)
    }

    static func run() {
        _ = NSApplication.shared
        let properties = SimulatedAudioDeviceProperties()
        let inventory = MutableUIProcessInventory((1...12).map { AudioRoutesTests.client(UInt32($0)) })
        var owners: [SimulatedRouteOwner] = []
        let routes = AudioRoutes { let owner = SimulatedRouteOwner(); owners.append(owner); return owner }
        let controller = SoundToolApp(audio: AudioDevices(properties: properties), routes: routes, processes: inventory)
        controller.refreshInventory()
        let panel = controller.panel
        precondition(panel.routePicker.isHiddenOrHasHiddenAncestor)
        let devices = try! AudioDevices(properties: properties).inventory().outputs.get()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = panel.view // Off-screen, never order front or activate.
        panel.resizeToFit(maximumHeight: 560)
        panel.view.setFrameSize(panel.preferredContentSize)
        panel.view.layoutSubtreeIfNeeded()
        let initialRows = panel.applicationRows
        let focused = initialRows[7].destinationPicker
        precondition(window.makeFirstResponder(focused))
        let appDocument = panel.applicationScroll.documentView!
        let lastRect = initialRows.last!.convert(initialRows.last!.bounds, to: appDocument)
        appDocument.scrollToVisible(lastRect)
        let scrollOrigin = panel.applicationScroll.contentView.bounds.origin
        let originalItem = initialRows[7].destinationPicker.item(at: 0)!
        let systemItem = panel.systemRows[0].picker.selectedItem!
        for _ in 0..<3 { controller.refreshInventory() }
        precondition(zip(initialRows, panel.applicationRows).allSatisfy { $0 === $1 })
        precondition(window.firstResponder === focused)
        precondition(panel.applicationScroll.contentView.bounds.origin == scrollOrigin)
        precondition(initialRows[7].destinationPicker.item(at: 0) === originalItem)
        precondition(panel.systemRows[0].picker.selectedItem === systemItem)

        // Reorder a stable lifetime without rebuilding its control or focus.
        inventory.clients.reverse()
        controller.refreshInventory()
        precondition(panel.applicationRows.last === initialRows.first)
        precondition(window.firstResponder === focused)
        let old = inventory.clients[4]
        inventory.clients[4] = AudioProcess(id: old.id, pid: old.pid, birth: old.birth, bundleID: old.bundleID, outputDeviceIDs: [103])
        controller.refreshInventory()
        precondition(panel.applicationRows[4] === initialRows[7])
        precondition(panel.applicationRows[4].client.outputDeviceIDs == [103])
        precondition(panel.applicationRows[4].toolTip!.components(separatedBy: "Reported app outputs:").count == 2)
        precondition(panel.applicationRows[4].toolTip!.contains("Device 103"))

        // A reused PID/object is a different lifetime: never reuse its row.
        inventory.clients[4] = AudioRoutesTests.client(old.id, birth: 999)
        controller.refreshInventory()
        precondition(panel.applicationRows[4] !== initialRows[7])
        precondition(window.firstResponder !== focused)
        precondition(window.firstResponder === panel.applicationRows.first!.destinationPicker)
        precondition(initialRows[7].window == nil)

        choose(panel.applicationRows[0], devices.first!)
        choose(panel.applicationRows[1], devices.last!)
        precondition(!panel.routePicker.isHiddenOrHasHiddenAncestor)
        precondition(panel.stopButton.accessibilityLabel()!.contains(panel.applicationRows[1].client.label))

        // Every production dropdown participates in the same interaction gate.
        // Notifications/forced presentation changes cannot remove open items;
        // only view work waits. Owner progress/restoration still happens.
        let pickers = panel.systemRows.map(\.picker) + [panel.routePicker, panel.monitorPicker, panel.applicationRows[0].destinationPicker]
        for picker in pickers {
            open(picker)
            precondition(panel.isTrackingMenu)
            let items = picker.itemArray
            let rows = panel.applicationRows
            let reads = properties.inventoryReads
            properties.defaults[SystemAudioRole.output.selector] = 103
            controller.refreshInventory()
            panel.monitorPicker.selectItem(at: 0)
            action(panel.monitorPicker) // force presentation refresh while menu is tracking
            try! owners[0].suppressOriginalPlayback()
            precondition(properties.inventoryReads == reads)
            precondition(zip(rows, panel.applicationRows).allSatisfy { $0 === $1 })
            precondition(picker.itemArray.count == items.count)
            precondition(zip(items, picker.itemArray).allSatisfy { $0 === $1 })
            precondition(routes.routes.count == 2 && owners.allSatisfy { $0.hasResources && $0.stops == 0 })
            close(picker)
            precondition(!panel.isTrackingMenu)
            precondition(zip(items, picker.itemArray).allSatisfy { $0 === $1 }) // close must not rebuild before selection action
            drainRefresh()
            precondition(properties.inventoryReads > reads)
            precondition(panel.systemRows[0].picker.titleOfSelectedItem == "Device 103")
            precondition(panel.applicationRows[0].statusLabel.stringValue.contains("suppression requested"))
        }

        // A caller's selected item survives deferred inventory until the action
        // consumes its parsed snapshot. Only this route switches.
        let row = panel.applicationRows[0]
        open(row.destinationPicker)
        let chosen = row.destinationPicker.itemArray.first {
            guard case .hardware(let device) = $0.representedObject as? AppOutputSelection else { return false }
            return device.hasSameIdentity(as: devices.last!)
        }!
        row.destinationPicker.select(chosen)
        inventory.clients.reverse()
        controller.refreshInventory()
        close(row.destinationPicker)
        precondition(row.destinationPicker.selectedItem === chosen)
        action(row.destinationPicker)
        precondition(owners[0].stops == 1 && owners[1].stops == 0 && owners.count == 3)
        precondition(routes.route(for: row.client)!.owner.mirrorDestination!.hasSameIdentity(as: devices.last!))
        drainRefresh()
        precondition(panel.applicationRows.last === row)
        precondition(panel.applicationRows.last!.destinationPicker.titleOfSelectedItem == devices.last!.name)

        // Recovery/Stop notices and selected-owner lifecycle detail have distinct
        // views. An old notice cannot hide another route's restoration warning.
        choose(row, nil)
        precondition(panel.noticeLabel.stringValue.contains(row.client.label))
        let survivor = routes.routes.first!
        let owner = survivor.owner as! SimulatedRouteOwner
        owner.stopFault = .restore
        do { try owner.stop(); preconditionFailure("Expected retained restoration") } catch {}
        panel.routePicker.selectItem(at: 0)
        action(panel.routePicker)
        precondition(panel.stateTitle.stringValue.contains("restoration pending"))
        precondition(panel.stateDetail.stringValue.contains("This route's audio resources are retained"))
        precondition(panel.noticeLabel.stringValue.contains(row.client.label))
        precondition(!panel.stateDetail.isHiddenOrHasHiddenAncestor && !panel.noticeLabel.isHiddenOrHasHiddenAncestor)
        precondition(panel.stopButton.title == "Retry restore / cleanup")
        let retained = panel.applicationRows.first { $0.client.hasSameIdentity(as: survivor.client) }!
        open(retained.destinationPicker)
        precondition(retained.destinationPicker.item(at: 0)!.isEnabled)
        precondition(retained.destinationPicker.itemArray.dropFirst().allSatisfy { !$0.isEnabled })
        close(retained.destinationPicker)
        owner.stopFault = nil
        try! routes.stopAll()
        controller.refreshInventory()
        precondition(panel.routePicker.isHiddenOrHasHiddenAncestor && !panel.noticeLabel.isHiddenOrHasHiddenAncestor)

        // Shorter-than-old-500pt viewports retain reachable controls through
        // outer scrolling, including diagnostics and long contextual notices.
        panel.diagnosticsToggle.state = .on
        action(panel.diagnosticsToggle)
        panel.resizeToFit(maximumHeight: 420)
        panel.view.setFrameSize(panel.preferredContentSize)
        panel.view.layoutSubtreeIfNeeded()
        precondition(panel.preferredContentSize.height <= 420)
        let outer = panel.view.subviews.first as! NSScrollView
        let document = outer.documentView!
        let quitRect = panel.quitButton.convert(panel.quitButton.bounds, to: document)
        document.scrollToVisible(quitRect)
        precondition(outer.documentVisibleRect.intersects(quitRect))
        precondition(properties.writes.isEmpty && routes.routes.isEmpty)
        print("Production UI refresh: all-dropdown deferral/action ordering, row/menu identity, focus/scroll preservation, reused lifetime, contextual notices and 420pt scrolling: passed (simulated inventory/owners; no host writes)")
    }
}
