import SwiftUI
import AppKit

struct ExcludedAppChip: View {
    let app: ExcludedAppInfo
    let onRemove: () -> Void

    @StateObject private var metadata = AppMetadataCache.shared
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon = resolvedIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
            } else {
                RetraceSymbol("app.fill", size: 12, weight: .medium)
                    .foregroundColor(.retraceSecondary)
                    .frame(width: 20, height: 20)
            }

            Text(app.name)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retracePrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: onRemove) {
                RetraceSymbol("xmark", size: 11, weight: .semibold)
                    .foregroundColor(.retraceSecondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(app.name)")
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(isHovered ? Color.retraceSurfaceHover : Color.retraceSurfaceSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(isHovered ? Color.retraceBorderStrong : Color.retraceBorder, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .task(id: "\(app.bundleID)|\(app.iconPath ?? "")") {
            if let iconPath = app.iconPath {
                metadata.requestIcon(forAppPath: iconPath)
            }
            metadata.requestMetadata(for: app.bundleID)
        }
    }

    private var resolvedIcon: NSImage? {
        if let iconPath = app.iconPath,
           let icon = metadata.icon(forAppPath: iconPath) {
            return icon
        }
        return metadata.icon(for: app.bundleID)
    }
}

struct ExcludedAppsAddButton: View {
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RetraceSymbol("plus", size: 13, weight: .medium)
                    .foregroundColor(.retraceInk2)

                Text("Add App...")
                    .font(.retraceMeta)
                    .foregroundColor(.retraceInk2)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                    .fill((isHovered || isOpen) ? Color.retraceSurfaceHover : Color.retraceSurfaceSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                    .stroke(
                        isOpen ? RetraceMenuStyle.filterStrokeStrong : Color.retraceBorderStrong,
                        lineWidth: isOpen ? 1.2 : 1
                    )
            )
            .retraceFocusRing(cornerRadius: .radiusMd)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
