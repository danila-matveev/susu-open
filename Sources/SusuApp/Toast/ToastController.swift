// Shows one toast at a time above the pill. Never takes focus; a new toast replaces the old one.
import AppKit
import SwiftUI
import SusuCore

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class ToastHostingView: NSHostingView<ToastView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
public final class ToastController {
    /// Capsule of the pill in screen coordinates; set by `PillController.attach(_:)`.
    public var anchor: () -> NSRect? = { nil }
    /// (visible, wantsPillError): lets the pill follow the toast.
    public var onVisibilityChange: ((Bool, Bool) -> Void)?

    private let model = ToastModel()
    private let panel: ToastPanel
    private let host: ToastHostingView
    private var timer: Timer?
    private var remaining: TimeInterval = 0
    private var started = Date()
    private var hovering = false

    public init() {
        host = ToastHostingView(rootView: ToastView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.title = "SusuToast"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        model.onAction = { [weak self] action in
            action.handler()
            self?.hide()
        }
        model.onHover = { [weak self] inside in self?.hoverChanged(inside) }
    }

    public func show(_ toast: Toast) {
        let wasVisible = model.visible
        model.toast = toast
        model.serial += 1
        model.visible = true
        layout()
        if !wasVisible { panel.alphaValue = 1; panel.orderFrontRegardless() }
        onVisibilityChange?(true, toast.pillError)
        arm(toast.resolvedDuration)
    }

    public func hide() {
        timer?.invalidate(); timer = nil
        guard model.visible else { return }
        model.visible = false
        onVisibilityChange?(false, false)
        // Let the 120 ms fade finish, then take the panel off screen (unless a new toast came).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard let self, !self.model.visible else { return }
            self.panel.orderOut(nil)
        }
    }

    public var isVisible: Bool { model.visible }

    // MARK: timing

    private func arm(_ seconds: TimeInterval) {
        timer?.invalidate()
        remaining = seconds
        started = Date()
        guard !hovering else { return }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    /// The timer waits while the pointer is on the toast, so a button can be reached.
    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        guard model.visible else { return }
        if inside {
            timer?.invalidate(); timer = nil
            remaining = max(0.6, remaining - Date().timeIntervalSince(started))
        } else {
            arm(remaining)
        }
    }

    // MARK: placement

    private func layout() {
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        let size = NSSize(width: ToastMetrics.width + ToastMetrics.sidePad * 2,
                          height: max(40, fit.height))
        let capsule = anchor() ?? NSRect(x: (NSScreen.main?.visibleFrame.midX ?? 400) - 18,
                                         y: (NSScreen.main?.visibleFrame.minY ?? 0) + PillMetrics.dockGap, width: 36, height: 6)
        let vf = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: capsule.midX, y: capsule.midY)) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var cardCenter = capsule.midX
        let half = ToastMetrics.width / 2
        cardCenter = min(vf.maxX - 12 - half, max(vf.minX + 12 + half, cardCenter))
        let origin = NSPoint(x: cardCenter - size.width / 2,
                             y: capsule.maxY + ToastMetrics.gapAbovePill - ToastMetrics.bottomPad)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
