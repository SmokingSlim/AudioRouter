import AppKit

/// Controls carry parsed role/device/client facts; none of these views owns
/// capture, playback, restoration, or system-device policy.
@MainActor
final class SystemAudioRow: NSStackView {
    let role: SystemAudioRole
    let picker = NSPopUpButton()
    let volume = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let valueLabel = AudioPopover.label("—", secondary: true)
    let muteButton = NSButton(checkboxWithTitle: "Mute", target: nil, action: nil)
    let hint = AudioPopover.label("", secondary: true)
    private(set) var displayedDevice: AudioDevice?
    private struct MenuSnapshot: Equatable {
        let devices: [AudioDevice]
        let selectedID: UInt32?
    }
    private var menuSnapshot: MenuSnapshot?
    var onSelection: ((SystemAudioRole, AudioDevice) -> Void)?
    var onVolume: ((SystemAudioRole, AudioDevice, Float) -> Void)?
    var onMute: ((SystemAudioRole, AudioDevice, Bool) -> Void)?

    init(role: SystemAudioRole) {
        self.role = role
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        let title = AudioPopover.label(role.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let icon = NSImageView(image: NSImage(systemSymbolName: role == .input ? "mic" : role == .output ? "speaker.wave.2" : "bell", accessibilityDescription: role.title) ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let headline = NSStackView(views: role == .soundEffects
            ? [icon, title, NSView(), picker] : [icon, title, NSView()])
        headline.alignment = .centerY
        headline.distribution = .fill
        headline.spacing = 8
        picker.widthAnchor.constraint(equalToConstant: 230).isActive = true
        addArrangedSubview(headline)
        headline.translatesAutoresizingMaskIntoConstraints = false
        headline.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.autoenablesItems = false
        picker.target = self
        picker.action = #selector(selectDevice(_:))
        picker.setAccessibilityLabel("System \(role.title.lowercased()) device")
        hint.isHidden = true
        guard role != .soundEffects else { return }
        volume.isContinuous = true
        volume.target = self
        volume.action = #selector(changeVolume(_:))
        volume.widthAnchor.constraint(equalToConstant: 160).isActive = true
        volume.setAccessibilityLabel(role == .input ? "System microphone input level" : "System output volume, all apps on this device")
        valueLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        muteButton.target = self
        muteButton.action = #selector(changeMute(_:))
        muteButton.setAccessibilityLabel("Mute system \(role.title.lowercased()) device")
        let controls = NSStackView(views: [volume, valueLabel, muteButton, NSView(), picker])
        controls.alignment = .centerY
        controls.spacing = 8
        addArrangedSubview(controls)
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        addArrangedSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(devices: [AudioDevice], selectedID: UInt32?, volumeValue: Float?, muted: Bool?) {
        displayedDevice = devices.first { $0.id == selectedID }
        let snapshot = MenuSnapshot(devices: devices, selectedID: selectedID)
        if menuSnapshot != snapshot {
            menuSnapshot = snapshot
            picker.removeAllItems()
            picker.addItem(withTitle: selectedID.map { "Device \($0) · unavailable" } ?? "Unavailable")
            picker.lastItem?.isEnabled = false
            for device in devices {
                picker.addItem(withTitle: device.name)
                let item = picker.lastItem!
                item.representedObject = device
                item.isEnabled = device.uid != nil && device.isEligible(for: role)
                if device.id == selectedID { picker.select(item) }
            }
        }
        // Readback restores the actual selection even after a rejected write.
        let actual = picker.itemArray.first { ($0.representedObject as? AudioDevice)?.id == selectedID }
        picker.select(actual ?? picker.item(at: 0))
        picker.isEnabled = devices.contains { $0.uid != nil && $0.isEligible(for: role) }
        updateLevels(volumeValue: volumeValue, muted: muted)
    }

    func updateLevels(volumeValue: Float?, muted: Bool?) {
        volume.isEnabled = volumeValue != nil && displayedDevice?.uid != nil
        volume.doubleValue = Double(volumeValue ?? 0)
        valueLabel.stringValue = volumeValue.map { "\(Int($0 * 100))%" } ?? "—"
        muteButton.isEnabled = muted != nil && displayedDevice?.uid != nil
        muteButton.state = muted == true ? .on : .off
        if role != .soundEffects {
            hint.stringValue = volumeValue == nil ? "\(role == .input ? "Input level" : "Volume") unavailable" : ""
            hint.isHidden = hint.stringValue.isEmpty
        }
    }

    @objc private func selectDevice(_ sender: NSPopUpButton) {
        guard let device = sender.selectedItem?.representedObject as? AudioDevice else { return }
        onSelection?(role, device)
    }
    @objc private func changeVolume(_ sender: NSSlider) {
        guard let device = displayedDevice else { return }
        onVolume?(role, device, Float(sender.doubleValue))
    }
    @objc private func changeMute(_ sender: NSButton) {
        guard let device = displayedDevice else { return }
        onMute?(role, device, sender.state == .on)
    }
}

enum AppOutputSelection {
    case original
    case hardware(AudioDevice)
}

@MainActor
final class ApplicationAudioRow: NSStackView, NSMenuDelegate {
    private(set) var client: AudioProcess
    let nameLabel: NSTextField
    let statusLabel = AudioPopover.label("", secondary: true)
    let destinationPicker = NSPopUpButton()
    static let rowHeight: CGFloat = 78
    let gainSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    let gainLabel = AudioPopover.label("100%", secondary: true)
    let muteButton = NSButton(checkboxWithTitle: "Mute", target: nil, action: nil)
    private var levelControls: NSStackView!
    private var displayedLevel: PlaybackLevel = .unity
    var onLevel: ((AudioProcess, PlaybackLevel) -> Void)?
    private var devices: [AudioDevice]
    private var canCapture: Bool
    private let image = NSImageView()
    private static let fallbackIcon = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
    private var canRoute = false
    private var currentDestination: AudioDevice?
    private struct MenuSnapshot: Equatable {
        let devices: [AudioDevice]
        let destination: AudioDevice?
        let canRoute: Bool
        let expanded: Bool
    }
    private var menuSnapshot: MenuSnapshot?
    private var actualMenuItem: NSMenuItem?
    var onSelection: ((AudioProcess, AppOutputSelection) -> Void)?
    var onMenuOpen: ((ApplicationAudioRow) -> Void)?
    var onMenuClose: ((NSMenu) -> Void)?

    init(client: AudioProcess, name: String, icon: NSImage?, devices: [AudioDevice], canCapture: Bool) {
        self.client = client
        self.devices = devices // shared, prefiltered inventory from the controller
        self.canCapture = canCapture
        nameLabel = AudioPopover.label(name)
        super.init(frame: .zero)
        orientation = .horizontal
        distribution = .fill
        alignment = .centerY
        spacing = 10
        heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        image.image = icon ?? Self.fallbackIcon
        image.imageScaling = .scaleProportionallyDown
        image.widthAnchor.constraint(equalToConstant: 26).isActive = true
        image.heightAnchor.constraint(equalToConstant: 26).isActive = true
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.maximumNumberOfLines = 2
        gainSlider.isContinuous = true
        gainSlider.target = self
        gainSlider.action = #selector(changeLevel(_:))
        gainSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        gainLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        muteButton.target = self
        muteButton.action = #selector(changeLevel(_:))
        levelControls = NSStackView(views: [gainSlider, gainLabel, muteButton])
        levelControls.spacing = 6
        levelControls.isHidden = true
        levelControls.toolTip = "Replacement audio only; original output and hardware volume are unchanged."
        let text = NSStackView(views: [nameLabel, statusLabel, levelControls!])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        for label in [nameLabel, statusLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        addArrangedSubview(image)
        addArrangedSubview(text)
        addArrangedSubview(destinationPicker)
        destinationPicker.widthAnchor.constraint(equalToConstant: 230).isActive = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        destinationPicker.autoenablesItems = false
        destinationPicker.menu?.delegate = self
        destinationPicker.target = self
        destinationPicker.action = #selector(selectDestination(_:))
        updateAccessibility(name: name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updateInventory(client: AudioProcess, name: String, icon: NSImage?, devices: [AudioDevice], canCapture: Bool) {
        precondition(self.client.hasSameIdentity(as: client))
        self.client = client // same lifetime; preserve fresh parsed output metadata
        self.devices = devices
        self.canCapture = canCapture
        if nameLabel.stringValue != name { nameLabel.stringValue = name }
        let displayedIcon = icon ?? Self.fallbackIcon
        if image.image !== displayedIcon { image.image = displayedIcon }
        updateAccessibility(name: name)
    }

    private func updateAccessibility(name: String) {
        destinationPicker.setAccessibilityLabel("\(name) output, starts exclusive routing, does not change system default")
        gainSlider.setAccessibilityLabel("\(name) replacement audio gain")
        muteButton.setAccessibilityLabel("Mute \(name) replacement audio")
    }

    func update(isOwner: Bool, canStart: Bool, canChangeDestination: Bool, destination: AudioDevice?, state: RoutePresentation,
                level: PlaybackLevel = .unity, canAdjustLevel: Bool = false) {
        updatePlaybackLevel(level, canAdjust: canAdjustLevel)
        levelControls.isHidden = !isOwner || destination == nil
        // Render owned facts, not the last attempted menu choice. Failed setup,
        // disconnection or partial cleanup cannot masquerade as a new route.
        canRoute = canCapture && (isOwner ? canChangeDestination : canStart)
        currentDestination = isOwner ? destination : nil
        populateMenu(includeChoices: false)
        // Original output is also the restoration/cleanup retry action for an
        // owned row, even if the client is no longer active or fully identified.
        destinationPicker.isEnabled = isOwner || (canRoute && !devices.isEmpty)
        let status: String
        if isOwner { status = state.title }
        else if !canCapture { status = "Capture unavailable · identity or feedback risk" }
        else if !canStart { status = "Route capacity reached or process already captured" }
        else { status = "" }
        if statusLabel.stringValue != status { statusLabel.stringValue = status }
        statusLabel.isHidden = status.isEmpty
    }

    func updatePlaybackLevel(_ level: PlaybackLevel, canAdjust: Bool) {
        displayedLevel = level
        gainSlider.doubleValue = Double(level.gain)
        gainLabel.stringValue = "\(Int((level.gain * 100).rounded()))%"
        muteButton.state = level.muted ? .on : .off
        gainSlider.isEnabled = canAdjust
        muteButton.isEnabled = canAdjust
    }

    func menuWillOpen(_ menu: NSMenu) {
        onMenuOpen?(self)
        populateMenu(includeChoices: true)
    }

    func menuDidClose(_ menu: NSMenu) { onMenuClose?(menu) }

    func collapseChoices() { populateMenu(includeChoices: false) }

    private func populateMenu(includeChoices: Bool) {
        let snapshot = MenuSnapshot(devices: devices, destination: currentDestination, canRoute: canRoute, expanded: includeChoices)
        guard menuSnapshot != snapshot else {
            destinationPicker.select(actualMenuItem) // rejected Stop/start must not display the attempted choice
            return
        }
        menuSnapshot = snapshot
        destinationPicker.removeAllItems()
        destinationPicker.addItem(withTitle: "Original output")
        destinationPicker.lastItem!.representedObject = AppOutputSelection.original
        if includeChoices {
            for device in devices {
                destinationPicker.addItem(withTitle: device.name)
                let item = destinationPicker.lastItem!
                item.representedObject = AppOutputSelection.hardware(device)
                item.isEnabled = canRoute
                if let currentDestination, device.hasSameIdentity(as: currentDestination) { destinationPicker.select(item) }
            }
        }
        if let currentDestination {
            let available = devices.contains { $0.hasSameIdentity(as: currentDestination) }
            if !includeChoices || !available {
                destinationPicker.addItem(withTitle: currentDestination.name + (available ? "" : " · unavailable"))
                let item = destinationPicker.lastItem!
                item.representedObject = AppOutputSelection.hardware(currentDestination)
                item.isEnabled = canRoute && available
                destinationPicker.select(item)
            }
        }
        actualMenuItem = destinationPicker.selectedItem
    }

    @objc private func changeLevel(_ sender: NSControl) {
        guard gainSlider.isEnabled, muteButton.isEnabled,
              let level = PlaybackLevel(gain: Float(gainSlider.doubleValue), muted: muteButton.state == .on) else { return }
        onLevel?(client, level)
        // Render authoritative state through the controller, not an optimistic
        // policy cached by this view.
        gainSlider.doubleValue = Double(displayedLevel.gain)
        muteButton.state = displayedLevel.muted ? .on : .off
    }

    @objc private func selectDestination(_ sender: NSPopUpButton) {
        guard let selection = sender.selectedItem?.representedObject as? AppOutputSelection else { return }
        onSelection?(client, selection)
    }
}

private final class FlippedAudioView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class AudioPopover: NSViewController, NSMenuDelegate {
    let systemRows = SystemAudioRole.allCases.map { SystemAudioRow(role: $0) }
    private(set) var applicationRows: [ApplicationAudioRow] = []
    let applicationsHint = AudioPopover.label("Play audio in an app, then Refresh.", secondary: true)
    let noticeLabel = AudioPopover.label("", secondary: true)
    let diagnosticsToggle = NSButton(checkboxWithTitle: "Show diagnostics", target: nil, action: nil)
    let monitorPicker = NSPopUpButton()
    let monitorButton = NSButton(title: "Monitor app only", target: nil, action: nil)
    let diagnosticsLabel = AudioPopover.label("", secondary: true)
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    let applicationScroll = NSScrollView()
    private let content = NSStackView()
    private let applications = NSStackView()
    private weak var expandedApplicationRow: ApplicationAudioRow?
    private let diagnostics = NSStackView()
    private weak var trackedMenu: NSMenu?
    var isTrackingMenu: Bool { trackedMenu != nil }
    var onMenuTrackingEnded: (() -> Void)?
    private var applicationHeight: NSLayoutConstraint!
    private var maximumHeight: CGFloat = 740

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 700))
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        let outerScroll = NSScrollView()
        outerScroll.hasVerticalScroller = true
        outerScroll.autohidesScrollers = true
        outerScroll.drawsBackground = false
        outerScroll.setAccessibilityLabel("AudioRouter controls")
        let document = FlippedAudioView()
        outerScroll.documentView = document
        view.addSubview(outerScroll)
        outerScroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            outerScroll.topAnchor.constraint(equalTo: view.topAnchor),
            outerScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            outerScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outerScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            document.widthAnchor.constraint(equalTo: outerScroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
        ])
        let header = Self.label("AudioRouter")
        header.font = .systemFont(ofSize: 20, weight: .semibold)
        add(header)
        let system = Self.section(title: "System · macOS defaults", views: systemRows)
        add(system)
        let applicationDocument = FlippedAudioView()
        applicationScroll.documentView = applicationDocument
        applicationScroll.hasVerticalScroller = true
        applicationScroll.autohidesScrollers = true
        applicationScroll.drawsBackground = false
        applicationScroll.borderType = .noBorder
        applicationScroll.setAccessibilityLabel("Active audio applications")
        applicationScroll.isHidden = true
        applications.orientation = .vertical
        applications.alignment = .leading
        applications.spacing = 0
        applications.translatesAutoresizingMaskIntoConstraints = false
        applicationDocument.addSubview(applications)
        applicationDocument.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            applicationDocument.widthAnchor.constraint(equalTo: applicationScroll.contentView.widthAnchor),
            applications.topAnchor.constraint(equalTo: applicationDocument.topAnchor),
            applications.leadingAnchor.constraint(equalTo: applicationDocument.leadingAnchor),
            applications.trailingAnchor.constraint(equalTo: applicationDocument.trailingAnchor),
            applications.bottomAnchor.constraint(equalTo: applicationDocument.bottomAnchor),
        ])
        applicationHeight = applicationScroll.heightAnchor.constraint(equalToConstant: 60)
        applicationHeight.isActive = true
        add(Self.section(title: "Application", views: [applicationScroll, applicationsHint]))
        noticeLabel.maximumNumberOfLines = 0
        add(noticeLabel)
        noticeLabel.isHidden = true
        add(diagnosticsToggle)
        diagnostics.orientation = .vertical
        diagnostics.alignment = .leading
        diagnostics.spacing = 6
        diagnostics.addArrangedSubview(diagnosticsLabel)
        diagnostics.addArrangedSubview(Self.row([monitorPicker, monitorButton]))
        add(diagnostics)
        diagnosticsLabel.maximumNumberOfLines = 0
        diagnosticsLabel.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsLabel.widthAnchor.constraint(equalTo: diagnostics.widthAnchor).isActive = true
        diagnostics.isHidden = true
        monitorPicker.setAccessibilityLabel("Audio client to monitor without redirecting")
        add(Self.row([refreshButton, quitButton]))
        for button in [monitorButton, refreshButton, quitButton] { button.bezelStyle = .rounded }
        for picker in systemRows.map(\.picker) + [monitorPicker] { picker.menu?.delegate = self }
    }

    func menuWillOpen(_ menu: NSMenu) { trackedMenu = menu }
    func menuDidClose(_ menu: NSMenu) {
        guard trackedMenu === menu else { return }
        trackedMenu = nil
        onMenuTrackingEnded?()
    }
    func cancelMenuTracking() { trackedMenu?.cancelTracking() }

    func setApplicationRows(_ rows: [ApplicationAudioRow]) {
        precondition(!isTrackingMenu)
        guard applicationRows.count != rows.count || !zip(applicationRows, rows).allSatisfy({ $0 === $1 }) else { return }
        let focused = view.window?.firstResponder as? NSView
        let retained = Set(rows.map(ObjectIdentifier.init))
        let removedFocus = applicationRows.contains { old in
            !retained.contains(ObjectIdentifier(old)) && focused?.isDescendant(of: old) == true
        }
        for old in applicationRows where !retained.contains(ObjectIdentifier(old)) {
            if expandedApplicationRow === old { expandedApplicationRow = nil }
            applications.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        applicationRows = rows
        var arranged = applications.arrangedSubviews
        for (index, row) in rows.enumerated() {
            row.onMenuOpen = { [weak self] openedRow in
                guard let self else { return }
                // Keep full choices for only the tracked (or last closed) row.
                // Releasing a previous row here cannot race its selection action.
                if let previous = self.expandedApplicationRow, previous !== openedRow { previous.collapseChoices() }
                self.expandedApplicationRow = openedRow
                self.menuWillOpen(openedRow.destinationPicker.menu!)
            }
            row.onMenuClose = { [weak self] menu in self?.menuDidClose(menu) }
            if arranged.indices.contains(index), arranged[index] === row { continue }
            let isNew = row.superview == nil
            if !isNew {
                // Removing an arranged slot, not the view, keeps a reused
                // control in its window and preserves its first responder.
                applications.removeArrangedSubview(row)
                arranged.removeAll { $0 === row }
            }
            applications.insertArrangedSubview(row, at: index)
            arranged.insert(row, at: index)
            if isNew {
                row.translatesAutoresizingMaskIntoConstraints = false
                row.widthAnchor.constraint(equalTo: applications.widthAnchor).isActive = true
            }
        }
        applicationScroll.isHidden = rows.isEmpty
        resizeToFit()
        view.window?.recalculateKeyViewLoop()
        if removedFocus {
            let next = rows.first { $0.destinationPicker.isEnabled }?.destinationPicker ?? refreshButton
            view.window?.makeFirstResponder(next)
            next.scrollToVisible(next.bounds)
        }
    }

    func setDiagnosticsVisible(_ visible: Bool) {
        diagnostics.isHidden = !visible
        resizeToFit()
        view.window?.recalculateKeyViewLoop()
    }

    func resizeToFit(maximumHeight: CGFloat? = nil) {
        if let maximumHeight { self.maximumHeight = maximumHeight }
        view.layoutSubtreeIfNeeded()
        let nonListHeight = content.fittingSize.height + 32 - (applicationScroll.isHidden ? 0 : applicationHeight.constant)
        applicationHeight.constant = min(CGFloat(max(1, applicationRows.count)) * ApplicationAudioRow.rowHeight, ApplicationAudioRow.rowHeight * 4, max(ApplicationAudioRow.rowHeight, self.maximumHeight - nonListHeight))
        view.layoutSubtreeIfNeeded()
        // The app list normally absorbs growth. On short screens or expanded
        // diagnostics, the outer viewport keeps every control reachable too.
        preferredContentSize = NSSize(width: 580, height: min(self.maximumHeight, content.fittingSize.height + 32))
    }

    private func add(_ child: NSView) {
        content.addArrangedSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private static func section(title: String, views: [NSView]) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 10
        let heading = label(title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // Pin the stack to the box itself. NSBox's frame-managed contentView
        // does not propagate an Auto Layout fitting height to its parent.
        box.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
        ])
        for child in stack.arrangedSubviews {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return box
    }

    private static func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.distribution = .fillEqually
        return stack
    }

    fileprivate static func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.maximumNumberOfLines = 2
        return label
    }
}
