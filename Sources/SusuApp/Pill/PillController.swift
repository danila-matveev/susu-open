// AppKit host of the pill: a non-activating, click-through panel at the bottom of the screen.
// It never takes focus. Clicks pass through everywhere except on the capsule (the panel flips
// `ignoresMouseEvents` as the pointer enters or leaves the capsule rectangle).
import AppKit
import SwiftUI
import SusuCore

private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Allow the panel to sit partly off-screen (pill snapped to an edge).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class PillHostingView: NSHostingView<PillView> {
    var onRightClick: (NSEvent) -> Void = { _ in }
    override func rightMouseDown(with event: NSEvent) { onRightClick(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor private final class ClosureItem: NSMenuItem {
    var handler: (@MainActor () -> Void)?
    @objc func fire() { handler?() }
}

@MainActor
public final class PillController {
    public var onHandsFreeCancel: () -> Void = {}
    public var onHandsFreeDone: () -> Void = {}
    /// Click on the pill while a call is being recorded (opens the call panel).
    public var onCallClick: () -> Void = {}
    public var menuActions = PillMenuHandlers()
    /// Asked before each tone; wire it to `settings.soundsEnabled`.
    public var soundsEnabled: () -> Bool = { true }
    public var language: InterfaceLanguage = .system {
        didSet { model.language = language }
    }

    /// Reactions for toast buttons produced by `handle(_:)`.
    public var onRetry: () -> Void = {}
    public var onOpenSettings: () -> Void = {}
    public var onOpenHistory: () -> Void = {}
    public var onChooseMicrophone: () -> Void = {}
    private weak var toasts: ToastController?

    private let model = PillModel()
    private let panel: PillPanel
    private let host: PillHostingView
    private let defaults: UserDefaults
    private let sounds = PillSounds()
    private var hideTimer: Timer?
    private var hidden = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var dragStartMouse: CGFloat?
    private var dragStartCenter: CGFloat = 0
    private var dragging = false
    private var errorFromToast = false
    private var screenObserver: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        host = PillHostingView(rootView: PillView(model: model))
        host.sizingOptions = []
        panel = PillPanel(contentRect: NSRect(origin: .zero, size: PillMetrics.panelSize),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.title = "SusuPill"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true

        model.onCancel = { [weak self] in self?.onHandsFreeCancel() }
        model.onDone = { [weak self] in self?.onHandsFreeDone() }
        model.onCallClick = { [weak self] in self?.onCallClick() }
        model.onDragChanged = { [weak self] in self?.dragChanged() }
        model.onDragEnded = { [weak self] in self?.dragEnded() }
        host.onRightClick = { [weak self] e in self?.showMenu(e) }

        place(animated: false)
        panel.alphaValue = 0   // idle at launch: invisible until the first dictation
        panel.orderFrontRegardless()
        installMouseMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.place(animated: false) } }
    }

    // MARK: public API

    public func setState(_ new: PillState) {
        let old = model.state
        guard new != old else { return }
        playSound(from: old, to: new)
        model.state = new
        fadeForState()
        if !new.isListeningLike && new != .processing && new != .agentWorking { model.sampler.reset() }
        refreshHit()
    }

    /// Mic level 0...1, expected about 7 times a second while listening.
    public func setLevel(_ level: Float) { model.sampler.setTarget(level) }

    /// Amber dot while a call is being recorded: part of the thin idle capsule, a small dot beside any other state.
    public func setCallDot(_ on: Bool) { model.callDot = on; fadeForState(); refreshHit() }

    /// Nothing on screen while Susu waits: the pill appears only while it listens, works or shows a call dot.
    private func fadeForState() {
        guard !hidden else { return }
        let visible = !(model.state == .idle || model.state == .hover) || model.callDot
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Text of the hands-free hint bubble; nil restores the default.
    public func setHint(_ text: String?) { model.hintOverride = text }
    /// The dictation key glyph for the hint («⌃», «F18»).
    public func setKeyName(_ name: String) { model.keyName = name }

    /// "Hide for an hour": fades the pill out and brings it back after `interval`.
    public func hide(for interval: TimeInterval) {
        hideTimer?.invalidate()
        hidden = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hidden else { return }
                self.panel.orderOut(nil)
            }
        })
        hideTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.show() }
        }
    }

    /// Brings a hidden pill back ("Show pill" in the menu-bar menu).
    public func show() {
        hideTimer?.invalidate(); hideTimer = nil
        hidden = false
        place(animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        fadeForState()
    }

    public var isHidden: Bool { hidden }

    /// The capsule in screen coordinates (toasts sit above its top edge).
    public var capsuleScreenFrame: NSRect {
        let size = PillMetrics.size(for: model.display, callDot: model.callDot)
        let f = panel.frame
        return NSRect(x: f.midX - size.width / 2, y: f.minY + PillMetrics.bottomInset, width: size.width, height: size.height)
    }

    /// Lets a toast drive the pill: error toasts give the capsule a brick hairline and hide the hint.
    public func attach(_ toast: ToastController) {
        toasts = toast
        toast.anchor = { [weak self] in self?.capsuleScreenFrame }
        toast.onVisibilityChange = { [weak self] visible, pillError in
            guard let self else { return }
            self.model.hasSlot = visible
            if visible, pillError, [.idle, .hover, .error].contains(self.model.state) {
                self.errorFromToast = true
                self.setState(.error)
            } else if !visible, self.errorFromToast {
                self.errorFromToast = false
                if self.model.state == .error { self.setState(.idle) }
            }
        }
    }

    /// Single entry point for the dictation pipeline: maps each event to a pill state and a toast.
    public func handle(_ event: DictationEvent) {
        let l = language
        switch event {
        case .listening(let confirmed): toasts?.hide(); setState(.listening(confirmed: confirmed))
        case .handsFree: toasts?.hide(); setState(.handsFree)
        case .level(let v): setLevel(v)
        case .processing: setState(.processing)
        case .idle, .inserted: setState(.idle)
        case .copiedOnly: setState(.idle); toasts?.show(.windowChanged(language: l))
        case .notInserted:
            setState(.idle)
            toasts?.show(.notPasted(language: l) { [weak self] in self?.menuActions.pasteLast() })
        case .secureInput: setState(.idle); toasts?.show(.secureInput(language: l))
        case .micSilent:
            setState(.idle)
            toasts?.show(.micSilent(language: l, retry: { [weak self] in self?.onRetry() },
                                    chooseMicrophone: { [weak self] in self?.onChooseMicrophone() }))
        case .longRecordingWarning: toasts?.show(.limit19(language: l))
        case .failed(let error):
            setState(.idle)
            let open: @MainActor () -> Void = { [weak self] in self?.onOpenSettings() }
            switch error {
            case .cancelled: break
            case .noNetwork, .modelMissing: toasts?.show(.noNetwork(language: l) { [weak self] in self?.onOpenHistory() })
            case .unauthorized: toasts?.show(.keyInvalid(language: l, openSettings: open))
            case .outOfCredit: toasts?.show(.noMoney(language: l, openSettings: open))
            case .rateLimited, .timeout, .http, .badResponse: toasts?.show(.cloudUnreachable(language: l))
            }
        }
    }

    // MARK: placement

    private var screen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    private var centerFraction: Double {
        get { defaults.object(forKey: PillMetrics.positionKey) as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: PillMetrics.positionKey) }
    }

    private func place(animated: Bool, centerX: CGFloat? = nil) {
        guard let vf = screen?.visibleFrame else { return }
        let cx = centerX ?? (vf.minX + vf.width * centerFraction)
        let clamped = min(vf.maxX - 24, max(vf.minX + 24, cx))
        let frame = NSRect(x: clamped - PillMetrics.panelSize.width / 2,
                           y: vf.minY + PillMetrics.dockGap - PillMetrics.bottomInset,
                           width: PillMetrics.panelSize.width, height: PillMetrics.panelSize.height)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func dragChanged() {
        let mouse = NSEvent.mouseLocation.x
        if dragStartMouse == nil {
            dragStartMouse = mouse
            dragStartCenter = panel.frame.midX
            dragging = true
            model.hovered = false
        }
        place(animated: false, centerX: dragStartCenter + mouse - (dragStartMouse ?? mouse))
    }

    private func dragEnded() {
        defer { dragStartMouse = nil; dragging = false; refreshHit() }
        guard dragStartMouse != nil, let vf = screen?.visibleFrame else { return }
        let cx = panel.frame.midX
        let target: CGFloat
        if cx - vf.minX < vf.width * 0.18 { target = vf.minX + PillMetrics.edgeInset }
        else if vf.maxX - cx < vf.width * 0.18 { target = vf.maxX - PillMetrics.edgeInset }
        else if abs(cx - vf.midX) < 90 { target = vf.midX }
        else { target = cx }
        centerFraction = Double((target - vf.minX) / vf.width)
        place(animated: true, centerX: target)
    }

    // MARK: pointer

    private func installMouseMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.refreshHit() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.refreshHit() }
            return event
        }
    }

    /// The capsule plus a forgiving margin (the idle capsule is only 6 pt tall).
    private var hitRect: NSRect {
        let c = capsuleScreenFrame
        let w = max(c.width, 52) + (model.callDot ? 28 : 0) + 8
        let h = max(c.height, 28) + 8
        return NSRect(x: c.midX - w / 2, y: c.minY - 4, width: w, height: h)
    }

    private func refreshHit() {
        guard !hidden else { return }
        let inside = dragging || hitRect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        let hover = inside && !dragging
        if model.hovered != hover { model.hovered = hover }
    }

    // MARK: menu

    private func showMenu(_ event: NSEvent) {
        let h = menuActions
        let l = language
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ key: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let i = ClosureItem(title: PillL10n.string(key, l), action: #selector(ClosureItem.fire), keyEquivalent: "")
            i.target = i
            i.handler = action
            return i
        }
        menu.addItem(item("pill.menu.paste") { h.pasteLast() })
        menu.addItem(item("pill.menu.history") { h.openHistory() })
        menu.addItem(.separator())
        menu.addItem(submenu("pill.menu.microphone", h.microphones(), pick: h.selectMicrophone))
        menu.addItem(submenu("pill.menu.language", h.languages(), pick: h.selectLanguage))
        menu.addItem(.separator())
        menu.addItem(item("pill.menu.hide") { h.hideForHour() })
        menu.addItem(item("pill.menu.settings") { h.openSettings() })
        NSMenu.popUpContextMenu(menu, with: event, for: host)
    }

    private func submenu(_ key: String, _ choices: [PillMenuChoice], pick: @escaping @MainActor (String) -> Void) -> NSMenuItem {
        let parent = NSMenuItem(title: PillL10n.string(key, language), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for c in choices {
            let i = ClosureItem(title: c.title, action: #selector(ClosureItem.fire), keyEquivalent: "")
            i.target = i
            i.state = c.isSelected ? .on : .off
            let id = c.id
            i.handler = { pick(id) }
            sub.addItem(i)
        }
        parent.submenu = sub
        parent.isEnabled = !choices.isEmpty
        return parent
    }

    // MARK: sounds

    private func playSound(from old: PillState, to new: PillState) {
        guard soundsEnabled() else { return }
        if new.isListeningLike && !old.isListeningLike { sounds.play(.start) }
        else if (new == .processing && old.isListeningLike) { sounds.play(.stop) }
        else if new == .error && old != .error { sounds.play(.error) }
    }
}
