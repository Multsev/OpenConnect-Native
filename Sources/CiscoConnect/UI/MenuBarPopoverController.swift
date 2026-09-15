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
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
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
        } onChange: { [self] in
            DispatchQueue.main.async { @MainActor in
                self.updateStatusItem()
                self.observeTunnelState()
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updateStatusItem()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            button.highlight(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }
}

@MainActor
private struct MenuBarPopoverContent: View {
    @Bindable var model: AppModel
    @AppStorage(AppPresentationPreferences.menuBarOnlyKey) private var menuBarOnly = false

    var body: some View {
        RootView(
            model: model,
            menuBarOnly: $menuBarOnly,
            presentation: .menuBar
        )
    }
}

/// Propagates SwiftUI's fitted size after every AppKit layout, including
/// observation-driven changes while the popover is already open.
@MainActor
final class ContentSizedHostingController<Content: View>: NSHostingController<Content> {
    private let onSizeChange: (CGSize) -> Void
    private var lastSize: CGSize = .zero

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
        onSizeChange(size)
    }
}
