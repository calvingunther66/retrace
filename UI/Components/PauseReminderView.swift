import SwiftUI

/// A floating notification view that appears in the top-right corner
/// when capturing has been paused for 5 minutes
/// Design matches Rewind AI's pause notification style
public struct PauseReminderView: View {

    // MARK: - Properties

    let title: String
    let onResumeCapturing: () -> Void
    let onRemindMeLater: () -> Void
    let onEditIntervalInSettings: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering = false

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    RetraceSymbol("xmark", size: 10, weight: .medium)
                        .foregroundColor(.retraceInk2)
                        .frame(width: 20, height: 20)
                        .background(isHovering ? Color.retraceSurfaceHover : Color.retraceSurfaceSunken)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .onHover { hovering in
                    isHovering = hovering
                }
            }
            .padding(.trailing, 12)
            .padding(.top, 12)

            // Main content
            VStack(spacing: 16) {
                // Status text
                Text(title)
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retraceInk)

                // Primary action button
                Button(action: onResumeCapturing) {
                    Text("Resume Capturing")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RetraceButtonStyle(.primary))

                // Secondary action button
                Button(action: onRemindMeLater) {
                    Text("Remind Me Later")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RetraceButtonStyle(.secondary))

                // Settings shortcut link
                Button(action: onEditIntervalInSettings) {
                    Text("Edit interval in Settings")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceAccent)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(Color.retraceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
        .retraceElevation(.md)
    }
}

// MARK: - Preview

#if DEBUG
struct PauseReminderView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.retracePage
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    PauseReminderView(
                        title: "Retrace is paused.",
                        onResumeCapturing: {},
                        onRemindMeLater: {},
                        onEditIntervalInSettings: {},
                        onDismiss: {}
                    )
                    .padding()
                }
                Spacer()
            }
        }
        .frame(width: 400, height: 300)
    }
}
#endif
