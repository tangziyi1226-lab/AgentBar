import AgentBarCore
import AppKit
import QuartzCore
import SwiftUI

final class FloatingGlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ClearGlassHostView: NSView {
    private let shadowCasterLayer = CALayer()
    private let cutoutMaskLayer = CAShapeLayer()
    weak var glassSubView: NSView?
    let cornerRadius: CGFloat

    init(frame: NSRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        shadowCasterLayer.backgroundColor = NSColor.clear.cgColor
        shadowCasterLayer.shadowColor = NSColor.black.cgColor
        shadowCasterLayer.shadowOpacity = 0.22
        shadowCasterLayer.shadowRadius = 16
        shadowCasterLayer.shadowOffset = CGSize(width: 0, height: -6)
        cutoutMaskLayer.fillRule = .evenOdd
        shadowCasterLayer.mask = cutoutMaskLayer
        layer?.addSublayer(shadowCasterLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard let glass = glassSubView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowCasterLayer.frame = bounds
        let glassRect = glass.frame
        let roundedPath = CGPath(
            roundedRect: glassRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        shadowCasterLayer.shadowPath = roundedPath

        let maskPath = CGMutablePath()
        maskPath.addRect(bounds.insetBy(dx: -80, dy: -80))
        maskPath.addPath(roundedPath)
        cutoutMaskLayer.frame = bounds
        cutoutMaskLayer.path = maskPath
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let glass = glassSubView else { return nil }
        let inSelf = superview != nil ? convert(point, from: superview) : point
        guard bounds.contains(inSelf), glass.frame.contains(inSelf) else {
            return nil
        }
        return super.hitTest(point)
    }
}

private struct PanelHostRootView: View {
    let model: AppModel
    let onOpenSettings: () -> Void

    var body: some View {
        if model.isPanelVisible {
            PanelView(model: model, onOpenSettings: onOpenSettings)
        } else {
            Color.clear
                .frame(width: PanelView.panelWidth, height: 200)
        }
    }
}

@MainActor
final class StatusBarController: NSObject {
    private struct StatusBadgeRenderKey: Equatable {
        var counts: MenuBarCounts
        var totalSessionCount: Int
        var style: MenuBarIconStyle
        var isDarkMenuBar: Bool
    }

    private static let shadowInset: CGFloat = 28
    private static let glassCornerRadius: CGFloat = 22

    private let statusItem: NSStatusItem
    private let panel: FloatingGlassPanel
    private var containerView: ClearGlassHostView?
    private var glassView: NSGlassEffectView?
    private let model: AppModel
    private var settingsWindow: NSWindow?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var anchorTopY: CGFloat?
    private var anchorMidX: CGFloat?
    private weak var anchorScreen: NSScreen?
    private var resizeScheduled = false
    private var lastBadgeKey: StatusBadgeRenderKey?

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let pad = Self.shadowInset
        let rect = NSRect(x: 0, y: 0, width: PanelView.panelWidth + pad * 2, height: 600 + pad * 2)
        self.panel = FloatingGlassPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        configurePanel()
        configureStatusItem()

        model.onStatusBarNeedsUpdate = { [weak self] in
            self?.updateStatusButtonImage()
        }
        model.onPreferredHeightChanged = { [weak self] in
            self?.scheduleResizeVisiblePanel()
        }
        JumpService.onBeforeJump = { [weak self] in
            self?.closePanel()
        }
        updateStatusButtonImage()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePanel() {
        let pad = Self.shadowInset
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let outerFrame = NSRect(x: 0, y: 0, width: PanelView.panelWidth + pad * 2, height: 600 + pad * 2)
        let hostContainer = ClearGlassHostView(frame: outerFrame, cornerRadius: Self.glassCornerRadius)
        hostContainer.autoresizingMask = [.width, .height]

        let glassView = NSGlassEffectView(frame: NSRect(x: pad, y: pad, width: PanelView.panelWidth, height: 600))
        glassView.style = .regular
        glassView.cornerRadius = Self.glassCornerRadius
        glassView.autoresizingMask = [.width, .height]

        let rootView = PanelHostRootView(model: model) { [weak self] in
            self?.openSettingsWindow()
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.focusRingType = .none
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView = hostingView
        if let content = glassView.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
                content.topAnchor.constraint(equalTo: glassView.topAnchor),
                content.bottomAnchor.constraint(equalTo: glassView.bottomAnchor)
            ])
        }
        hostContainer.addSubview(glassView)
        hostContainer.glassSubView = glassView
        self.containerView = hostContainer
        self.glassView = glassView
        panel.contentView = hostContainer
    }

    func updateStatusButtonImage() {
        guard let button = statusItem.button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = StatusBadgeRenderKey(
            counts: model.menuBarCounts,
            totalSessionCount: model.sessions.count,
            style: model.menuBarStyle,
            isDarkMenuBar: isDark
        )
        if key == lastBadgeKey, button.image != nil {
            return
        }
        lastBadgeKey = key
        let img = MenuBarBadgeRenderer.renderStatusImage(
            counts: key.counts,
            totalSessionCount: key.totalSessionCount,
            style: key.style,
            isDarkMenuBar: key.isDarkMenuBar
        )
        button.image = img
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if panel.isVisible {
            closePanel()
        } else {
            showPanelRelativeToButton(sender)
        }
    }

    private func showPanelRelativeToButton(_ button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrameInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        self.anchorMidX = buttonFrameInScreen.midX
        self.anchorTopY = buttonFrameInScreen.minY - 6.0
        self.anchorScreen = buttonWindow.screen ?? NSScreen.main

        model.panelDidOpen()
        let initialFrame = computeTargetPanelFrame()
        panel.setFrame(initialFrame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        let finalFrame = computeTargetPanelFrame()
        panel.setFrame(finalFrame, display: true)
        panel.makeKeyAndOrderFront(nil)
        installDismissMonitors()

        scheduleResizeVisiblePanel()

        Task {
            await model.refreshOnPanelOpen()
        }
    }

    private func scheduleResizeVisiblePanel() {
        guard panel.isVisible, !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resizeVisiblePanelToFitContent()
        }
    }

    private func resizeVisiblePanelToFitContent() {
        guard panel.isVisible else { return }
        let target = computeTargetPanelFrame()
        if abs(panel.frame.height - target.height) > 1.0 || abs(panel.frame.origin.y - target.origin.y) > 1.0 {
            panel.setFrame(target, display: true, animate: false)
        }
    }

    private func computeTargetPanelFrame() -> NSRect {
        let pad = Self.shadowInset
        let panelWidth = PanelView.panelWidth
        let screenFrame = anchorScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topY = anchorTopY ?? (screenFrame.maxY - 6.0)
        let midX = anchorMidX ?? (screenFrame.maxX - panelWidth)

        let maxSpaceBelow = max(320, topY - screenFrame.minY - 12.0)
        let maxAllowedHeight = min(960, maxSpaceBelow)
        let panelHeight = round(min(maxAllowedHeight, max(200, model.preferredPanelHeight)))

        let glassOriginX = round(max(screenFrame.minX + 8, min(midX - panelWidth / 2.0, screenFrame.maxX - panelWidth - 8)))
        let glassOriginY = round(topY - panelHeight)
        return NSRect(
            x: glassOriginX - pad,
            y: glassOriginY - pad,
            width: panelWidth + pad * 2,
            height: panelHeight + pad * 2
        )
    }

    func closePanel() {
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        removeDismissMonitors()
        if wasVisible {
            model.panelDidClose()
        }
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePanel()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 { // Escape
                self.closePanel()
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    func openSettingsWindow() {
        closePanel()
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsWindowView(model: model))
        let win = NSWindow(contentViewController: hosting)
        win.title = "AgentBar 设置"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = win
    }
}
