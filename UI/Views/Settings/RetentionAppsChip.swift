import SwiftUI
import AppKit

struct RetentionAppsChip<PopoverContent: View>: View {
    let selectedApps: Set<String>
    @Binding var isPopoverShown: Bool
    @ViewBuilder var popoverContent: () -> PopoverContent

    @StateObject private var metadata = AppMetadataCache.shared
    @State private var isHovered = false

    private let maxVisibleIcons = 5
    private let iconSize: CGFloat = 18

    private var sortedApps: [String] {
        selectedApps.sorted()
    }

    private var isActive: Bool {
        !selectedApps.isEmpty
    }

    var body: some View {
        Button(action: {
            isPopoverShown.toggle()
        }) {
            HStack(spacing: 6) {
                if sortedApps.count == 1 {
                    let bundleID = sortedApps[0]
                    appIcon(for: bundleID)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))

                    Text(appName(for: bundleID))
                        .font(.retraceCaption)
                        .lineLimit(1)
                } else if sortedApps.count > 1 {
                    HStack(spacing: -4) {
                        ForEach(Array(sortedApps.prefix(maxVisibleIcons)), id: \.self) { bundleID in
                            appIcon(for: bundleID)
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                        }
                    }

                    if sortedApps.count > maxVisibleIcons {
                        Text("+\(sortedApps.count - maxVisibleIcons)")
                            .font(.retraceTinyBold)
                            .foregroundColor(.retraceInk2)
                    }
                } else {
                    RetraceSymbol("app.fill", size: 12)
                    Text("None")
                        .font(.retraceCaption)
                }

                RetraceSymbol("chevron.down", size: 10, weight: .semibold)
                    .rotationEffect(.degrees(isPopoverShown ? 180 : 0))
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: sortedApps)
            .foregroundColor(isActive ? .retraceInk : .retraceInk2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .fill(isActive ? Color.retraceAccentWash : (isHovered ? Color.retraceSurfaceHover : Color.retraceSurfaceSunken))
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .stroke(isActive ? Color.retraceAccent : Color.retraceBorderStrong, lineWidth: 1)
                    )
            )
            .retraceFocusRing(cornerRadius: .radiusSm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .task(id: sortedApps.joined(separator: "|")) {
            await preloadAppPresentation(for: sortedApps)
        }
        .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
            popoverContent()
        }
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let icon = metadata.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RetraceSymbol("app.fill", size: 13)
                .foregroundColor(.retraceInk2)
        }
    }

    private func appName(for bundleID: String) -> String {
        if let cachedName = metadata.name(for: bundleID) { return cachedName }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    @MainActor
    private func preloadAppPresentation(for bundleIDs: [String]) async {
        let iconBundleIDs = bundleIDs.count <= 1 ? bundleIDs : Array(bundleIDs.prefix(maxVisibleIcons))
        metadata.prefetch(bundleIDs: Array(Set(iconBundleIDs + (bundleIDs.count == 1 ? bundleIDs : []))))
    }
}
