import AppKit
import SwiftUI

/// The round buttons floating around the open notch, like Vorssaint's: each
/// one is its own tiny window, so the empty space between them never steals
/// clicks from the apps underneath.
final class AccessoryButtons {
    struct Item {
        let symbol: String
        let title: String
        let selected: Bool
        let action: () -> Void
    }

    static let size: CGFloat = 34
    static let gap: CGFloat = 8

    var onHover: (Bool) -> Void = { _ in }

    private var panels: [NSPanel] = []
    private var items: [(item: Item, isLeft: Bool)] = []
    /// Tooltips don't show in non-activating panels, so Denny draws its own.
    private lazy var tooltip: NSPanel = makeTooltip()

    /// Shows `left` stacked down the island's left side and `right` down its right side.
    /// `topInset` is the menu bar / camera band, so the first button sits just below it.
    func show(around island: CGRect, topInset: CGFloat, left: [Item], right: [Item]) {
        let items = left.map { ($0, true) } + right.map { ($0, false) }
        self.items = items.map { (item: $0.0, isLeft: $0.1) }
        while panels.count < items.count { panels.append(makePanel()) }
        for (index, panel) in panels.enumerated() {
            guard index < items.count else {
                panel.orderOut(nil)
                continue
            }
            let (item, isLeft) = items[index]
            let row = isLeft ? index : index - left.count
            let x = isLeft ? island.minX - Self.gap - Self.size : island.maxX + Self.gap
            let y = island.maxY - topInset - 10 - CGFloat(row + 1) * Self.size - CGFloat(row) * Self.gap
            panel.setFrame(CGRect(x: x, y: y, width: Self.size, height: Self.size), display: true)
            (panel.contentView as? NSHostingView<FloatingRoundButton>)?.rootView = FloatingRoundButton(
                symbol: item.symbol, title: item.title, selected: item.selected, action: item.action,
                onHover: { [weak self] hovering in
                    self?.onHover(hovering)
                    self?.showTooltip(hovering ? index : nil)
                }
            )
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            // Also cancels a fade-out still running from a quick close and reopen.
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        }
    }

    private func showTooltip(_ index: Int?) {
        guard let index, index < items.count, index < panels.count else {
            tooltip.orderOut(nil)
            return
        }
        let (item, isLeft) = items[index]
        let label = TooltipLabel(text: item.title)
        let hosting = NSHostingView(rootView: label)
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        tooltip.contentView = hosting
        let button = panels[index].frame
        let x = isLeft ? button.minX - 6 - size.width : button.maxX + 6
        tooltip.setFrame(CGRect(x: x, y: button.midY - size.height / 2, width: size.width, height: size.height), display: true)
        tooltip.orderFrontRegardless()
    }

    func hide() {
        tooltip.orderOut(nil)
        for panel in panels where panel.isVisible {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) {
                if panel.alphaValue < 0.01 { panel.orderOut(nil) }
            }
        }
    }

    private func makeTooltip() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: Self.size, height: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        let hosting = FirstClickHostingView(rootView: FloatingRoundButton(symbol: "circle", title: "", selected: false,
                                                                          action: {}, onHover: { _ in }))
        hosting.frame = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        panel.contentView = hosting
        return panel
    }
}

struct TooltipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.9)))
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
            .fixedSize()
    }
}

struct FloatingRoundButton: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selected ? .black : .white)
                .frame(width: AccessoryButtons.size, height: AccessoryButtons.size)
                .background(
                    Circle()
                        .fill(selected ? Color.white : Color.black.opacity(0.88))
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .onHover(perform: onHover)
    }
}
