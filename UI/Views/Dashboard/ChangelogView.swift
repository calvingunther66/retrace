import SwiftUI
import Shared

/// Dashboard-native changelog view backed by appcast.xml.
/// Presents versions as expandable cards in a modern, readable layout.
struct ChangelogView: View {
    @ObservedObject private var updaterManager = UpdaterManager.shared

    @State private var expandedEntryID: String?
    @State private var openStartTime: CFAbsoluteTime?
    @State private var didRecordOpenLatency = false

    private let contentMaxWidth: CGFloat = 1100
    private let headerHorizontalPadding: CGFloat = 32
    private let cardsHorizontalPadding: CGFloat = 100

    var body: some View {
        VStack(spacing: 0) {
            header

            if updaterManager.changelogEntries.isEmpty {
                emptyState
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, headerHorizontalPadding)
                    .padding(.bottom, 32)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 14) {
                        ForEach(updaterManager.changelogEntries) { entry in
                            ChangelogEntryCard(
                                entry: entry,
                                isExpanded: expandedEntryID == entry.id,
                                isInstalledVersion: isInstalledVersion(entry)
                            ) {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                    expandedEntryID = expandedEntryID == entry.id ? nil : entry.id
                                }
                            }
                        }
                    }
                    .padding(.horizontal, cardsHorizontalPadding)
                    .padding(.bottom, 30)
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            Color.retracePage
                .ignoresSafeArea()
        )
        .onAppear {
            openStartTime = CFAbsoluteTimeGetCurrent()
            didRecordOpenLatency = false
            ensureExpandedEntryIsValid()
            scheduleOpenLatencyMeasurement(trigger: "on_appear")
        }
        .onChange(of: updaterManager.changelogEntries.map(\.id)) { _ in
            ensureExpandedEntryIsValid()
            scheduleOpenLatencyMeasurement(trigger: "entries_changed")
        }
        .onChange(of: expandedEntryID) { _ in
            scheduleOpenLatencyMeasurement(trigger: "expanded_changed")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Button(action: {
                            NotificationCenter.default.post(name: .openDashboard, object: nil)
                        }) {
                            RetraceSymbol("chevron.left", size: 12, weight: .semibold)
                                .foregroundColor(.retraceInk2)
                                .frame(width: 28, height: 28)
                                .background(Color.retraceSurfaceSunken)
                                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                                        .stroke(Color.retraceBorderStrong, lineWidth: 1)
                                )
                                .retraceFocusRing(cornerRadius: .radiusSm)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .keyboardShortcut("[", modifiers: .command)
                        .accessibilityLabel("Back to dashboard")

                        Text("Changelog")
                            .font(.retraceTitle)
                            .foregroundColor(.retraceInk)
                    }

                    Text("Release notes synced from appcast.xml, refreshed when a new update is downloaded.")
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 10) {
                    if let refreshedAt = updaterManager.changelogLastRefreshDate {
                        HStack(spacing: .space2) {
                            RetraceSymbol("clock", size: 12.5)
                            Text(refreshedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        .font(.retraceCaption)
                        .foregroundColor(.retraceInk2)
                    }

                    Text("Updates when a new app version is downloaded")
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)
                }
            }
        }
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, headerHorizontalPadding)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            RetraceSymbol(updaterManager.changelogIsRefreshing ? "arrow.clockwise.circle" : "text.book.closed", size: 30, weight: .medium)
                .foregroundColor(.retraceAccent)

            Text(updaterManager.changelogIsRefreshing ? "Refreshing changelog..." : "No changelog entries yet")
                .font(.retraceHeadline)
                .foregroundColor(.retraceInk)

            Text("Changelog sync runs when a new app update is downloaded.")
                .font(.retraceMeta)
                .foregroundColor(.retraceMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 34)
        .background(
            RoundedRectangle(cornerRadius: .radiusLg, style: .continuous)
                .fill(Color.retraceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusLg, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
    }

    private func ensureExpandedEntryIsValid() {
        guard !updaterManager.changelogEntries.isEmpty else {
            expandedEntryID = nil
            return
        }

        if let expandedEntryID,
           updaterManager.changelogEntries.contains(where: { $0.id == expandedEntryID }) {
            return
        }

        expandedEntryID = updaterManager.changelogEntries.first?.id
    }

    private func scheduleOpenLatencyMeasurement(trigger: String) {
        guard !didRecordOpenLatency else { return }
        guard !updaterManager.changelogEntries.isEmpty else { return }
        guard expandedEntryID != nil else { return }
        guard let openStartTime else { return }

        didRecordOpenLatency = true
        let entryCount = updaterManager.changelogEntries.count
        let expandedID = expandedEntryID ?? "none"

        Task { @MainActor in
            // Let SwiftUI complete one frame before recording open latency.
            await Task.yield()
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - openStartTime) * 1000

            Log.recordLatency(
                "dashboard.changelog.open_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 1,
                warningThresholdMs: 300,
                criticalThresholdMs: 900
            )
            Log.info(
                "[ChangelogLatency] open completed trigger=\(trigger) entries=\(entryCount) expandedID=\(expandedID) elapsedMs=\(formatMs(elapsedMs))",
                category: .ui
            )
        }
    }

    private func formatMs(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func isInstalledVersion(_ entry: UpdaterManager.ChangelogEntry) -> Bool {
        var hasVersionSignal = false

        if let shortVersion = entry.shortVersion, !shortVersion.isEmpty {
            hasVersionSignal = true
            if shortVersion != updaterManager.currentVersion {
                return false
            }
        }

        if let buildVersion = entry.buildVersion, !buildVersion.isEmpty {
            hasVersionSignal = true
            if buildVersion != updaterManager.currentBuild {
                return false
            }
        }

        return hasVersionSignal
    }
}

private struct ChangelogEntryCard: View {
    let entry: UpdaterManager.ChangelogEntry
    let isExpanded: Bool
    let isInstalledVersion: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(entry.title)
                                .font(.retraceHeadline)
                                .foregroundColor(.retraceInk)
                                .multilineTextAlignment(.leading)

                            versionChip

                            if isInstalledVersion {
                                installedChip
                            }
                        }

                        HStack(spacing: 10) {
                            if let publishedAt = entry.publishedAt {
                                HStack(spacing: .space2) {
                                    RetraceSymbol("calendar", size: 12.5)
                                    Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                                }
                                .font(.retraceCaption)
                                .foregroundColor(.retraceInk2)
                            }

                            if let buildVersion = entry.buildVersion, !buildVersion.isEmpty {
                                Text("build \(buildVersion)")
                                    .font(.retraceMonoSmall)
                                    .foregroundColor(.retraceInk2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.retraceSurfaceSunken)
                                    )
                            }
                        }
                    }

                    Spacer(minLength: 12)

                    RetraceSymbol("chevron.down", size: 12.5, weight: .semibold)
                        .foregroundColor(.retraceInk2)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    Rectangle()
                        .fill(Color.retraceBorder)
                        .frame(height: 1)

                    ChangelogDetailsText(
                        blocks: entry.detailBlocks
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isInstalledVersion {
                        Button(action: {}) {
                            HStack(spacing: 8) {
                                RetraceSymbol("checkmark.circle.fill", size: 12.5, weight: .semibold)
                                Text("You are on this version")
                                    .font(.retraceCaptionBold)
                            }
                            .foregroundColor(.retraceInk2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.retraceSurfaceSunken)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(true)
                    } else if let downloadURL = entry.downloadURL {
                        Link(destination: downloadURL) {
                            HStack(spacing: 8) {
                                RetraceSymbol("arrow.down.circle.fill", size: 12.5, weight: .semibold)
                                Text("Download this release")
                                    .font(.retraceCaptionBold)
                            }
                            .foregroundColor(.retraceOnAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.retraceAccent)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: .radiusLg, style: .continuous)
                .fill(Color.retraceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusLg, style: .continuous)
                .stroke(
                    isExpanded
                        ? Color.retraceAccent
                        : Color.retraceBorder,
                    lineWidth: 1
                )
        )
        .retraceElevation(isExpanded ? .md : .sm)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private var versionChip: some View {
        Text("v\(entry.displayVersion)")
            .font(.retraceMonoSmall)
            .foregroundColor(.retraceInk)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.retraceAccentWash)
            )
    }

    private var installedChip: some View {
        RetraceBadge("Installed", tone: .good)
    }
}

private struct ChangelogDetailsText: View {
    let blocks: [UpdaterManager.ChangelogEntry.DetailBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.bottom, bottomSpacing(for: index))
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: UpdaterManager.ChangelogEntry.DetailBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(level <= 2 ? .retraceTitle2 : .retraceHeadline)
                .fontWeight(.semibold)
                .foregroundColor(.retraceInk)
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .paragraph(text):
            Text(text)
                .font(.retraceBody)
                .foregroundColor(.retraceInk2)
                .lineSpacing(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .bullet(text):
            HStack(alignment: .top, spacing: 12) {
                Text("•")
                    .font(.retraceBodyBold)
                    .foregroundColor(.retraceInk2)
                    .frame(width: 14, alignment: .leading)
                    .padding(.top, 1)

                Text(text)
                    .font(.retraceBody)
                    .foregroundColor(.retraceInk2)
                    .lineSpacing(6)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bottomSpacing(for index: Int) -> CGFloat {
        guard index < blocks.count else { return 0 }
        let current = blocks[index]
        let next = (index + 1 < blocks.count) ? blocks[index + 1] : nil

        switch current {
        case .heading:
            return 10
        case .paragraph:
            return 14
        case .bullet:
            if case .bullet? = next {
                return 7
            }
            return 16
        }
    }
}
