import SwiftUI
import AppKit

/// Banner view for displaying permission-related warnings with action buttons
struct PermissionBanner: View {
    let message: String
    let actionTitle: String
    let action: () -> Void
    let onDismiss: () -> Void
    /// Only the most urgent banner in a stack should be primary; the rest stay secondary.
    var isPrimary: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Warning icon
            RetraceSymbol("exclamationmark.triangle.fill", size: 17)
                .foregroundColor(.retraceWarningText)

            // Message
            Text(message)
                .font(.retraceCaption)
                .foregroundColor(.retraceInk)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            // Action button
            Button(action: action) {
                Text(actionTitle)
            }
            .buttonStyle(RetraceButtonStyle(isPrimary ? .primary : .secondary, size: .sm))

            // Dismiss button
            Button(action: onDismiss) {
                RetraceSymbol("xmark.circle.fill", size: 17)
                    .foregroundColor(.retraceInk2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .fill(Color.retraceWarningBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .stroke(Color.retraceWarningText.opacity(0.3), lineWidth: 1)
        )
    }
}

/// Helper to open System Settings to specific panes
struct SystemSettingsOpener {
    /// Open the main System Settings app.
    static func openSystemSettingsApp() {
        let url = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(url)
    }

    /// Open Accessibility privacy settings
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Open Screen Recording privacy settings
    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        PermissionBanner(
            message: "Retrace needs Accessibility permission to detect which display you're working on.",
            actionTitle: "Open Settings",
            action: {},
            onDismiss: {}
        )
        .padding()

        PermissionBanner(
            message: "Screen recording permission is required to capture your screen.",
            actionTitle: "Grant Permission",
            action: {},
            onDismiss: {}
        )
        .padding()
    }
    .frame(width: 500)
}
