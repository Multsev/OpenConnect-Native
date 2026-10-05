import AppKit
import Observation
import SwiftUI

/// Owns the native status item and NSPopover. NSPopover supplies the standard
/// macOS pointer that tracks the status-bar icon without custom geometry.
@MainActor
final class MenuBarPopoverController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?

    var isShown: Bool { popover.isShown }
    var hasLoadedContent: Bool { popover.contentViewController != nil }

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        super.init()
        configureStatusItem()
        configurePopover()
        observeTunnelState()
    }

    deinit {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        updateStatusItem()
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
    }

    private func loadPopoverContent() {
        guard popover.contentViewController == nil else { return }
        let controller = ContentSizedHostingController(
            rootView: MenuBarPopoverContent(model: model)
        ) { [weak self] size in
            guard let self, self.popover.contentSize != size else { return }
            self.popover.contentSize = size
        }
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
    }

    private func updateStatusItem() {
        let appearance = MenuBarIconAppearance(tunnelState: model.status.state)
        statusItem.button?.image = MenuBarStatusIcon.image(for: model.status.state)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = appearance.accessibilityLabel
        statusItem.button?.setAccessibilityLabel(appearance.accessibilityLabel)
    }

    private func observeTunnelState() {
        withObservationTracking {
            _ = model.status.state
        } onChange: { [weak self] in
            DispatchQueue.main.async { @MainActor [weak self] in
                self?.updateStatusItem()
                self?.observeTunnelState()
            }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            loadPopoverContent()
            updateStatusItem()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        installCloseHandlers()
    }

    func closePopover() {
        popover.close()
        popover.contentViewController = nil
        removeCloseHandlers()
        statusItem.button?.highlight(false)
    }

    private func installCloseHandlers() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalEvent(event)
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePopover() }
        }
    }

    func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            if event.keyCode == 53 { closePopover(); return nil }
        } else if event.window !== statusItem.button?.window,
                  !containsPopoverWindow(event.window) {
            closePopover()
        }
        return event
    }

    private func containsPopoverWindow(_ window: NSWindow?) -> Bool {
        guard let window, let panel = popover.contentViewController?.view.window else { return false }
        return window === panel || window.sheetParent === panel || window.parent === panel
    }

    private func removeCloseHandlers() {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        localEventMonitor = nil
        globalEventMonitor = nil
        deactivationObserver = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        removeCloseHandlers()
        statusItem.button?.highlight(false)
    }
}

@MainActor
private struct MenuBarPopoverContent: View {
    @Bindable var model: AppModel

    var body: some View {
        RootView(model: model)
    }
}

/// Propagates SwiftUI's fitted size after every AppKit layout, including
/// observation-driven changes while the popover is already open.
@MainActor
final class ContentSizedHostingController<Content: View>: NSHostingController<Content> {
    private let onSizeChange: (CGSize) -> Void
    private var lastSize: CGSize = .zero
    private var sizeUpdateScheduled = false

    init(rootView: Content, onSizeChange: @escaping (CGSize) -> Void) {
        self.onSizeChange = onSizeChange
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:onSizeChange:)") }

    override func viewDidLayout() {
        super.viewDidLayout()
        let size = view.fittingSize
        guard size.width > 0, size.height > 0, size != lastSize else { return }
        lastSize = size
        guard !sizeUpdateScheduled else { return }
        sizeUpdateScheduled = true
        // Coalesce changes after layout returns; resizing during layout can
        // recursively trigger AppKit/SwiftUI geometry updates.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeUpdateScheduled = false
            self.onSizeChange(self.lastSize)
        }
    }
}
