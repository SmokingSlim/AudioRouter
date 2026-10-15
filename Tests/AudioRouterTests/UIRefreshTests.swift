import AppKit

private final class MutableUIProcessInventory: AudioProcessInventory {
    var clients: [AudioProcess]
    var failure: AudioDeviceError?
    init(_ clients: [AudioProcess]) { self.clients = clients }
    func snapshot() throws -> AudioProcessSnapshot {
        if let failure { throw failure }
        return AudioProcessSnapshot(activeOutputClients: clients, unknownActivityCount: 0)
    }
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

    static func displayFacts() {
        func client(_ id: UInt32, birth: UInt64 = 100, outputs: [UInt32]? = nil) -> AudioProcess {
            AudioProcess(id: id, pid: Int32(id + 31000), birth: ProcessBirth(seconds: birth, microseconds: 1),
                         bundleID: "test.shared.display", outputDeviceIDs: outputs)
        }
        let first = client(301), second = client(302)
        let unknown = AudioProcess(id: 303, pid: nil, birth: nil, bundleID: "test.shared.display", outputDeviceIDs: nil)
        let inventory = MutableUIProcessInventory([first, second, unknown])
        let properties = SimulatedAudioDeviceProperties()
        let routes = AudioRoutes { SimulatedRouteOwner() }
        let controller = AudioRouterApp(audio: AudioDevices(properties: properties), routes: routes, processes: inventory)
        controller.refreshInventory()
        let panel = controller.panel
        let rows = panel.applicationRows
        precondition(rows[0].nameLabel.stringValue == "test.shared.display · 31301")
        precondition(rows[1].nameLabel.stringValue == "test.shared.display · 31302")
        precondition(rows[2].nameLabel.stringValue == "test.shared.display · unknown PID")
        precondition(!rows[2].destinationPicker.isEnabled)
        precondition(panel.monitorPicker.numberOfItems == 4) // Includes unknown active clients, not just capturable ones.
        precondition(panel.monitorPicker.item(at: 1)!.title == "test.shared.display · PID 31301")
        precondition((panel.monitorPicker.item(at: 1)!.representedObject as! AudioProcess).hasSameIdentity(as: first))

        // The creation-time callback must consume refreshed parsed metadata,
        // not the client captured when this native row was first created.
        inventory.clients[0] = client(301, outputs: [103])
        controller.refreshInventory()
        precondition(panel.applicationRows[0] === rows[0])
        let destination = try! AudioDevices(properties: properties).inventory().outputs.get().last!
        choose(rows[0], destination)
        precondition(routes.routes.count == 1 && routes.routes[0].client.outputDeviceIDs == [103])
        drainRefresh()

        // Same display and reused object/PID are not the same lifetime. The
        // old owned row stays reachable; only active snapshots enter Monitor.
        inventory.clients[0] = client(301, birth: 200)
        controller.refreshInventory()
        precondition(panel.applicationRows.count == 4 && panel.applicationRows[0] === rows[0])
        let replacement = panel.applicationRows.first { $0.client.hasSameIdentity(as: inventory.clients[0]) }!
        precondition(replacement !== rows[0] && !replacement.destinationPicker.isEnabled)
        precondition(panel.monitorPicker.numberOfItems == 4)
        precondition((panel.monitorPicker.item(at: 1)!.representedObject as! AudioProcess).birth?.seconds == 200)

        // Inventory failure is not empty-success and never hides owned actions.
        inventory.failure = .inventoryUnavailable
        controller.refreshInventory()
        precondition(panel.applicationRows.count == 1 && panel.applicationRows[0] === rows[0])
        precondition(rows[0].destinationPicker.isEnabled && panel.monitorPicker.numberOfItems == 1)
        precondition(!panel.applicationsHint.isHidden && panel.applicationsHint.stringValue.contains("unavailable"))
        choose(rows[0], nil)
        precondition(routes.routes.isEmpty && panel.noticeLabel.stringValue.contains("cleanup completed"))
        drainRefresh()
        inventory.failure = nil
        inventory.clients = []
        controller.refreshInventory()
        precondition(panel.applicationRows.isEmpty && !panel.applicationsHint.isHidden)
        precondition(panel.applicationsHint.stringValue == "Play audio in an app, then Refresh.")
        precondition(properties.writes.isEmpty)
        print("Refresh-local display facts: duplicate/unknown names, fresh callback payloads, reused/retained lifetimes and inventory-failure actions: passed (simulated inventory/owners; no host writes)")
    }

    static func ownClientVisibility() {
        let own = AudioProcess(id: 401, pid: ProcessInfo.processInfo.processIdentifier,
                               birth: nil, bundleID: nil, outputDeviceIDs: nil)
        // Same display label is not self identity; missing identities remain visible.
        let external = AudioProcess(id: 402, pid: 31402, birth: ProcessBirth(seconds: 100, microseconds: 1),
                                    bundleID: "AudioRouter", outputDeviceIDs: nil)
        let unknown = AudioProcess(id: 403, pid: nil, birth: nil, bundleID: nil, outputDeviceIDs: nil)
        var clients = [own, external, unknown]
        if let bundleID = Bundle.main.bundleIdentifier {
            clients.append(AudioProcess(id: 404, pid: 31404, birth: nil, bundleID: bundleID, outputDeviceIDs: nil))
        }
        let inventory = MutableUIProcessInventory(clients)
        let properties = SimulatedAudioDeviceProperties()
        let routes = AudioRoutes { SimulatedRouteOwner() }
        let controller = AudioRouterApp(audio: AudioDevices(properties: properties), routes: routes, processes: inventory)
        controller.panel.diagnosticsToggle.state = .on
        controller.refreshInventory()
        let panel = controller.panel
        precondition(panel.applicationRows.map { $0.client.id } == [external.id, unknown.id])
        precondition(panel.monitorPicker.itemArray.dropFirst().map { ($0.representedObject as! AudioProcess).id } == [external.id, unknown.id])
        precondition(!panel.applicationRows[1].destinationPicker.isEnabled)
        precondition(panel.diagnosticsLabel.stringValue.contains("2 external active output clients"))
        inventory.clients = [own]
        controller.refreshInventory()
        precondition(panel.applicationRows.isEmpty && panel.monitorPicker.numberOfItems == 1)
        precondition(!panel.monitorButton.isEnabled && !panel.applicationsHint.isHidden)
        precondition(routes.routes.isEmpty && properties.writes.isEmpty)
        print("Own audio client hidden from app/monitor presentation; external and unknown clients preserved: passed (simulated inventory; no host writes)")
    }

    static func run() {
        _ = NSApplication.shared
        ownClientVisibility()
        let properties = SimulatedAudioDeviceProperties()
        let inventory = MutableUIProcessInventory((1...12).map { AudioRoutesTests.client(UInt32($0)) })
        var owners: [SimulatedRouteOwner] = []
        let routes = AudioRoutes { let owner = SimulatedRouteOwner(); owners.append(owner); return owner }
        let controller = AudioRouterApp(audio: AudioDevices(properties: properties), routes: routes, processes: inventory)
        controller.refreshInventory()
        let panel = controller.panel
        precondition(panel.applicationsHint.isHidden)
        precondition(panel.applicationRows.allSatisfy { $0.statusLabel.isHidden })
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
        precondition(routes.routes.count == 2)
        precondition(panel.applicationRows.prefix(2).allSatisfy { $0.destinationPicker.accessibilityLabel()!.contains($0.nameLabel.stringValue) })

        // Every production dropdown participates in the same interaction gate.
        // Notifications/forced presentation changes cannot remove open items;
        // only view work waits. Owner progress/restoration still happens.
        let pickers = panel.systemRows.map(\.picker) + [panel.monitorPicker, panel.applicationRows[0].destinationPicker]
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
            precondition(panel.applicationRows[0].statusLabel.stringValue.isEmpty)
            precondition(panel.applicationRows[0].statusLabel.isHidden)
            panel.diagnosticsToggle.state = .on
            action(panel.diagnosticsToggle)
            precondition(panel.diagnosticsLabel.stringValue.contains("macOS confirmed the suppression property"))
            panel.diagnosticsToggle.state = .off
            action(panel.diagnosticsToggle)
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

        // A global notice cannot hide a retained app row's restoration warning.
        // Diagnostics describes all owners without a selected-route surface.
        choose(row, nil)
        precondition(panel.noticeLabel.stringValue.contains(row.client.label))
        let survivor = routes.routes.first!
        let owner = survivor.owner as! SimulatedRouteOwner
        owner.stopFault = .restore
        do { try owner.stop(); preconditionFailure("Expected retained restoration") } catch {}
        controller.refreshInventory()
        let retained = panel.applicationRows.first { $0.client.hasSameIdentity(as: survivor.client) }!
        precondition(retained.statusLabel.stringValue.contains("restoration pending"))
        precondition(!retained.statusLabel.isHiddenOrHasHiddenAncestor && !panel.noticeLabel.isHiddenOrHasHiddenAncestor)
        precondition(panel.noticeLabel.stringValue.contains(row.client.label))
        precondition(!retained.gainSlider.isEnabled && !retained.muteButton.isEnabled)
        panel.diagnosticsToggle.state = .on
        action(panel.diagnosticsToggle)
        precondition(panel.diagnosticsLabel.stringValue.contains("This route's audio resources are retained"))
        precondition(panel.diagnosticsLabel.stringValue.contains("Choose Original output"))
        panel.diagnosticsToggle.state = .off
        action(panel.diagnosticsToggle)
        open(retained.destinationPicker)
        precondition(retained.destinationPicker.item(at: 0)!.isEnabled)
        precondition(retained.destinationPicker.itemArray.dropFirst().allSatisfy { !$0.isEnabled })
        close(retained.destinationPicker)
        owner.stopFault = nil
        choose(retained, nil) // Native Original output is the restoration/cleanup retry.
        precondition(owner.stops == 2 && routes.routes.isEmpty)
        precondition(!panel.noticeLabel.isHiddenOrHasHiddenAncestor)
        precondition(panel.noticeLabel.stringValue.contains(survivor.client.label))

        // A stopped-but-owned cleanup failure has the same retry surface;
        // it must not disappear or look like an editable running route.
        choose(row, devices.first!)
        let cleanupOwner = routes.route(for: row.client)!.owner as! SimulatedRouteOwner
        cleanupOwner.stopFault = .cleanup
        do { try cleanupOwner.stop(); preconditionFailure("Expected retained cleanup") } catch {}
        controller.refreshInventory()
        precondition(row.statusLabel.stringValue == "Audio cleanup pending" && !row.statusLabel.isHidden)
        precondition(row.destinationPicker.isEnabled && !row.gainSlider.isEnabled)
        open(row.destinationPicker)
        precondition(row.destinationPicker.item(at: 0)!.isEnabled)
        precondition(row.destinationPicker.itemArray.dropFirst().allSatisfy { !$0.isEnabled })
        close(row.destinationPicker)
        cleanupOwner.stopFault = nil
        choose(row, nil)
        precondition(cleanupOwner.stops == 2 && routes.routes.isEmpty)

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
        displayFacts()
    }
}
