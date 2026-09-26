import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class RecordingOverlayModel {
    enum Phase: Equatable {
        case idle
        case recording
        case finishing
        case done
    }

    var phase: Phase = .idle
    var transcript = ""
    var showLiveWords = true
    var deliveryMessage: String?
    var deliveryDebugInfo: String?
}

@MainActor
final class RecordingOverlayWindowController {
    private let model: RecordingOverlayModel
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init(model: RecordingOverlayModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 112),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: RecordingOverlayView(model: model))
        panel.orderOut(nil)
    }

    func show() {
        hideTask?.cancel()
        let desiredHeight: CGFloat = model.deliveryMessage == nil ? 112 : 205
        if panel.frame.height != desiredHeight {
            panel.setContentSize(NSSize(width: 520, height: desiredHeight))
        }
        positionPanel()
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled, let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    private func positionPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        var centerX = screen.frame.midX
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           leftArea.maxX <= rightArea.minX {
            centerX = (leftArea.maxX + rightArea.minX) / 2
        }

        let size = panel.frame.size
        let origin = NSPoint(x: centerX - size.width / 2, y: screen.frame.maxY - size.height)
        panel.setFrameOrigin(origin)
    }
}

private struct RecordingOverlayView: View {
    let model: RecordingOverlayModel

    private var isExpanded: Bool {
        model.phase == .recording || model.phase == .finishing
            || (model.phase == .done && model.deliveryMessage != nil)
    }

    var body: some View {
        accessibleLayout
    }

    private var accessibleLayout: some View {
        baseLayout
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
    }

    private var baseLayout: some View {
        ZStack(alignment: .top) {
            if model.phase != .idle {
                overlayPanel
            }
        }
        .frame(width: 520, height: 205, alignment: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.phase)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.deliveryMessage)
    }

    private var overlayPanel: some View {
        Group {
            if isExpanded {
                expandedContent.transition(.opacity)
            } else {
                Circle()
                    .fill(model.phase == .done ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, isExpanded ? 22 : 0)
        .padding(.vertical, isExpanded ? 15 : 12)
        .frame(width: isExpanded ? 520 : 180, height: panelHeight)
        .background { panelBackground }
    }

    private var panelHeight: CGFloat {
        guard isExpanded else { return 32 }
        return model.deliveryMessage == nil ? 112 : 205
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: isExpanded ? 28 : 16, style: .continuous)
            .fill(Color.black)
            .overlay {
                if isExpanded {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(isExpanded ? 0.24 : 0), radius: 18, y: 6)
    }

    private var accessibilityLabel: String {
        var components = ["EchoFlow \\(title)."]
        if model.showLiveWords && !model.transcript.isEmpty {
            components.append(model.transcript)
        }
        if let deliveryMessage = model.deliveryMessage, !deliveryMessage.isEmpty {
            components.append(deliveryMessage)
        }
        if let deliveryDebugInfo = model.deliveryDebugInfo, !deliveryDebugInfo.isEmpty {
            components.append(deliveryDebugInfo)
        }
        return components.joined(separator: " ")
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.phase == .recording ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                if model.phase == .recording {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                } else if model.phase == .finishing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if model.showLiveWords && !model.transcript.isEmpty {
                Text(model.transcript)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.phase == .recording {
                Text(model.showLiveWords ? "Listening…" : "Live words hidden")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.68))
            }

            if let deliveryMessage = model.deliveryMessage {
                Text(deliveryMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let deliveryDebugInfo = model.deliveryDebugInfo {
                Text(deliveryDebugInfo)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        switch model.phase {
        case .idle: "EchoFlow"
        case .recording: "Listening"
        case .finishing: "Finishing transcription"
        case .done: "Dictation complete"
        }
    }
}
