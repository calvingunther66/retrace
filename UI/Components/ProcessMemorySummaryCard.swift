import Foundation
import SwiftUI
import Shared

struct ProcessMemorySummaryCard: View {
    private static let memoryRowsPageSize = 10
    private static let memoryRowsContainerHeight: CGFloat = 268
    private static let tableLeadingPadding: CGFloat = 6
    private static let tableTrailingPadding: CGFloat = 10
    private static let tableVerticalPadding: CGFloat = 10
    private static let compactRankColumnWidth: CGFloat = 34
    private static let expandedRankColumnWidth: CGFloat = 42
    private static let processRowSpacing: CGFloat = 4
    private static let retraceExpansionScrollAnchorY: CGFloat = 0
    private static let retraceExpansionScrollDelayMilliseconds = 40

    typealias MemoryProcessScrollTarget = ProcessMemoryCardScrollTarget
    private typealias DisplayedMemoryRow = ProcessMemoryCardDisplayedRow

    private let onRowsHoverChanged: ((Bool) -> Void)?
    private let onRetraceRowToggle: ((Bool) -> Void)?
    private let isRowsScrollEnabled: Bool
    private let showsOCRBacklogAttribution: Bool

    @ObservedObject private var processCPUMonitor = ProcessCPUMonitor.shared
    @StateObject private var appMetadataCache = AppMetadataCache.shared
    @StateObject private var cardController = ProcessMemoryCardController()

    init(
        onRowsHoverChanged: ((Bool) -> Void)? = nil,
        onRetraceRowToggle: ((Bool) -> Void)? = nil,
        isRowsScrollEnabled: Bool = true,
        showsOCRBacklogAttribution: Bool = false
    ) {
        self.onRowsHoverChanged = onRowsHoverChanged
        self.onRetraceRowToggle = onRetraceRowToggle
        self.isRowsScrollEnabled = isRowsScrollEnabled
        self.showsOCRBacklogAttribution = showsOCRBacklogAttribution
    }

    var body: some View {
        let snapshot = processCPUMonitor.snapshot

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RetraceSymbol("memorychip", size: 13.5)
                    .foregroundColor(.retraceInk2)

                HStack(spacing: 3) {
                    Text("Memory Log")
                        .font(.retraceCalloutBold)
                        .foregroundColor(.retraceInk)
                    Text("*")
                        .font(RetraceFont.font(size: 11, weight: .semibold))
                        .foregroundColor(.retraceInk2)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Rectangle().fill(Color.retraceBorder).frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                Text("Avg and Peak are sampled across the visible 12h window. Now is the latest sample.")
                    .font(RetraceFont.font(size: 11, weight: .medium))
                    .foregroundColor(.retraceInk2)

                if snapshot.hasRenderableMemoryData {
                    let presentation = cardController.presentation(
                        for: snapshot,
                        isRowsScrollEnabled: isRowsScrollEnabled,
                        compactRankColumnWidth: Self.compactRankColumnWidth,
                        expandedRankColumnWidth: Self.expandedRankColumnWidth
                    )

                    Text("Sampled duration: \(formatWindowDuration(snapshot.sampleDurationSeconds)) • Current Total: \(formatMemoryBytes(snapshot.totalTrackedCurrentResidentBytes)) • Avg Total: \(formatMemoryBytes(snapshot.totalTrackedAverageResidentBytes))")
                        .font(RetraceFont.font(size: 10, weight: .medium))
                        .foregroundColor(.retraceInk2)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Top memory owners")
                                .font(RetraceFont.font(size: 10, weight: .semibold))
                                .foregroundColor(.retraceInk2)
                            Spacer()
                            Text("Now")
                            .font(RetraceFont.font(size: 10, weight: .semibold))
                            .foregroundColor(.retraceInk2)
                            .frame(width: 66, alignment: .trailing)
                            Text("Avg")
                            .font(RetraceFont.font(size: 10, weight: .bold))
                            .foregroundColor(.retraceAccent)
                            .frame(width: 66, alignment: .trailing)
                            Text("Peak")
                            .font(RetraceFont.font(size: 10, weight: .semibold))
                            .foregroundColor(.retraceInk2)
                            .frame(width: 66, alignment: .trailing)
                        }
                        .padding(.bottom, 6)

                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: true) {
                                // Use a non-lazy stack + slot-based identity to avoid stale row reuse
                                // when process ranks reshuffle every second.
                                VStack(spacing: 0) {
                                    ForEach(Array(presentation.displayedRows.enumerated()), id: \.offset) { index, displayedRow in
                                        memoryProcessRowView(
                                            displayedRow: displayedRow,
                                            rankColumnWidth: presentation.rankColumnWidth
                                        )
                                        .id(displayedRow.rank.map(Self.memoryProcessRowAnchorID) ?? displayedRow.id)

                                        if index < presentation.displayedRows.count - 1 {
                                            Rectangle().fill(Color.retraceBorder).frame(height: 1)
                                        }
                                    }
                                }
                            }
                            .scrollDisabled(!presentation.allowsInnerScroll)
                            .frame(height: Self.memoryRowsContainerHeight)
                            .clipped()
                            .onHover { hovering in
                                cardController.handleRowsHoverChanged(hovering)
                                onRowsHoverChanged?(Self.parentHoverState(
                                    isHoveringRows: hovering,
                                    allowsInnerScroll: presentation.allowsInnerScroll
                                ))
                            }
                            .onChange(of: presentation.allowsInnerScroll) { enabled in
                                onRowsHoverChanged?(Self.parentHoverState(
                                    isHoveringRows: cardController.isHoveringRows,
                                    allowsInnerScroll: enabled
                                ))
                            }
                            .onChange(of: cardController.scrollTarget) { target in
                                guard let target else { return }
                                Task { @MainActor in
                                    try? await Task.sleep(
                                        for: .milliseconds(Self.retraceExpansionScrollDelayMilliseconds)
                                    )
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        proxy.scrollTo(
                                            target.id,
                                            anchor: UnitPoint(x: 0.5, y: target.anchorY)
                                        )
                                    }
                                    cardController.clearScrollTarget()
                                }
                            }
                        }

                        if presentation.hasMoreRows {
                            HStack {
                                Spacer()
                                Button("Load 10 more") {
                                    cardController.loadMore(totalRows: presentation.totalRows)
                                }
                                .buttonStyle(.plain)
                                .font(RetraceFont.font(size: 11, weight: .semibold))
                                .foregroundColor(.retraceAccent)

                                Text("(\(presentation.visibleRows) / \(presentation.totalRows))")
                                    .font(RetraceFont.font(size: 10, weight: .medium))
                                    .foregroundColor(.retraceInk2)
                                Spacer()
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.leading, Self.tableLeadingPadding)
                    .padding(.trailing, Self.tableTrailingPadding)
                    .padding(.vertical, Self.tableVerticalPadding)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .fill(Color.retraceSurface)
                    )

                    memoryUsageGuidePanel
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("No recent process memory history yet. Sampling now...")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceInk2)
                    }
                }
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(Color.retraceSurfaceSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
        .onAppear {
            cardController.handleAppear()
        }
        .onDisappear {
            onRowsHoverChanged?(false)
            cardController.handleDisappear()
        }
    }

    private func formatMemoryBytes(_ bytes: UInt64) -> String {
        Self.formatMemoryBytesForDisplay(bytes)
    }

    static func formatMemoryBytesForDisplay(_ bytes: UInt64) -> String {
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0
        let tb = gb * 1024.0
        let value = Double(bytes)
        let megabytes = value / mb

        if value >= tb {
            return String(format: "%.2f TB", value / tb)
        }
        if (megabytes * 10).rounded() >= 10_000 {
            return String(format: "%.2f GB", value / gb)
        }
        if value >= mb {
            return String(format: "%.1f MB", megabytes)
        }
        if value >= kb {
            return String(format: "%.0f KB", value / kb)
        }
        return "\(bytes) B"
    }

    private static func memoryProcessRowAnchorID(_ rowNumber: Int) -> String {
        ProcessMemoryCardPresentation.memoryProcessRowAnchorID(rowNumber)
    }

    static func retraceExpansionScrollTarget(firstCategoryID: String?) -> MemoryProcessScrollTarget? {
        ProcessMemoryCardController.retraceExpansionScrollTarget(
            firstCategoryID: firstCategoryID,
            anchorY: retraceExpansionScrollAnchorY
        )
    }

    static func shouldEnableInnerScroll(
        isRowsScrollEnabled: Bool,
        visibleRows: Int,
        displayedRowsCount: Int
    ) -> Bool {
        ProcessMemoryCardController.shouldEnableInnerScroll(
            isRowsScrollEnabled: isRowsScrollEnabled,
            visibleRows: visibleRows,
            displayedRowsCount: displayedRowsCount,
            pageSize: Self.memoryRowsPageSize
        )
    }

    static func parentHoverState(isHoveringRows: Bool, allowsInnerScroll: Bool) -> Bool {
        ProcessMemoryCardController.parentHoverState(
            isHoveringRows: isHoveringRows,
            allowsInnerScroll: allowsInnerScroll
        )
    }

    @ViewBuilder
    private func memoryProcessRowView(
        displayedRow: DisplayedMemoryRow,
        rankColumnWidth: CGFloat
    ) -> some View {
        let row = displayedRow.row

        HStack(spacing: Self.processRowSpacing) {
            rankIndicatorView(for: displayedRow, rankColumnWidth: rankColumnWidth)
            rowToggleIndicatorView(for: displayedRow)

            memoryRowIconView(for: displayedRow)

            Text(row.name)
                .font(RetraceFont.font(size: 12, weight: .regular))
                .foregroundColor(textColor(for: displayedRow))
                .lineLimit(1)

            if displayedRow.isPinnedRetrace && showsOCRBacklogAttribution {
                RetraceBadge("OCR running", tone: .accent)
            }

            Spacer(minLength: 2)

            memoryValueView(bytes: row.currentBytes, weight: .medium, color: .retraceInk2)
            memoryValueView(bytes: row.averageBytes, weight: .semibold, color: .retraceInk)
            memoryValueView(bytes: row.peakBytes, weight: .medium, color: .retraceInk2)
        }
        .padding(.vertical, 3)
        .padding(.leading, leadingPadding(for: displayedRow))
        .background(backgroundColor(for: displayedRow))
        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            cardController.handleRowTap(
                displayedRow,
                snapshot: processCPUMonitor.snapshot,
                onRetraceRowToggle: onRetraceRowToggle
            )
        }
    }

    @ViewBuilder
    private func rankIndicatorView(
        for displayedRow: DisplayedMemoryRow,
        rankColumnWidth: CGFloat
    ) -> some View {
        Group {
            if let rowNumber = displayedRow.rank {
                Text("\(rowNumber).")
                    .font(RetraceFont.mono(size: 12, weight: .medium))
                    .foregroundColor(.retraceInk2)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }
        }
        .lineLimit(1)
        .frame(width: rankColumnWidth, alignment: .leading)
    }

    @ViewBuilder
    private func rowToggleIndicatorView(for displayedRow: DisplayedMemoryRow) -> some View {
        Group {
            if displayedRow.isPinnedRetrace {
                RetraceSymbol(cardController.isRetraceExpanded ? "chevron.down" : "chevron.right", size: 10, weight: .semibold)
                    .foregroundColor(.retraceInk2)
            } else if displayedRow.isRetraceCategory {
                let isExpanded = displayedRow.retraceCategoryID.map {
                    cardController.expandedAttributionCategoryIDs.contains($0)
                } ?? false
                RetraceSymbol(isExpanded ? "chevron.down" : "chevron.right", size: 10, weight: .semibold)
                    .foregroundColor(.retraceInk2)
            } else if displayedRow.isRetraceFamily {
                let isExpanded = displayedRow.retraceFamilyExpansionKey.map {
                    cardController.expandedAttributionFamilyIDs.contains($0)
                } ?? false
                RetraceSymbol(isExpanded ? "chevron.down" : "chevron.right", size: 10, weight: .semibold)
                    .foregroundColor(.retraceInk2)
            } else {
                Color.clear
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: 10, height: 10, alignment: .center)
    }

    private func memoryValueView(bytes: UInt64, weight: Font.Weight, color: Color) -> some View {
        Text(formatMemoryBytes(bytes))
            .font(RetraceFont.mono(size: 12, weight: weight))
            .foregroundColor(color)
            .frame(width: 66, alignment: .trailing)
    }

    private func backgroundColor(for displayedRow: DisplayedMemoryRow) -> Color {
        if displayedRow.isPinnedRetrace {
            return Color.retraceAccentWash
        }
        if displayedRow.isRetraceCategory {
            return Color.retraceAccentWash
        }
        if displayedRow.isRetraceFamily {
            return Color.retraceSurfaceHover
        }
        if displayedRow.isRetraceComponent {
            return Color.retraceSurfaceSunken
        }
        return .clear
    }

    private var memoryUsageGuidePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Avg Memory Usage Guide")
                .font(RetraceFont.font(size: 11, weight: .semibold))
                .foregroundColor(.retraceInk)
                .padding(.bottom, 4)

            memoryUsageScaleBar
                .padding(.top, 4)
            memoryBoundaryValueRow

            Text("Retrace expands into explicit, inferred, and unattributed memory. Each category expands into families, then individual ledger components.")
                .font(RetraceFont.font(size: 10, weight: .regular))
                .foregroundColor(.retraceInk2)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            Text("However Retrace's process should be consistent across different process tools")
                .font(RetraceFont.font(size: 10, weight: .regular))
                .foregroundColor(.retraceInk2)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .fill(Color.retraceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
    }

    private var memoryUsageScaleBar: some View {
        Capsule(style: .continuous)
            .fill(Color.retraceSurfaceSunken)
            .frame(height: 10)
            .overlay {
                // Three solid bands: good, caution, bad (thresholds at 33% and 66% of the bar).
                GeometryReader { geometry in
                    let width = geometry.size.width
                    HStack(spacing: 1) {
                        Rectangle().fill(Color.retraceGood).frame(width: width * 0.33)
                        Rectangle().fill(Color.retraceWarningText).frame(width: width * 0.33)
                        Rectangle().fill(Color.retraceCritical)
                    }
                    .background(Color.retraceSurface)
                }
                .clipShape(Capsule(style: .continuous))
                .allowsHitTesting(false)
            }
            .overlay {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .stroke(Color.retraceBorder, lineWidth: 1)
                        Rectangle()
                            .fill(Color.retraceInk2)
                            .frame(width: 1, height: 12)
                            .offset(x: max(0, (width * 0.33) - 0.5), y: -1)
                        Rectangle()
                            .fill(Color.retraceInk2)
                            .frame(width: 1, height: 12)
                            .offset(x: max(0, (width * 0.66) - 0.5), y: -1)
                    }
                }
                .allowsHitTesting(false)
            }
            .accessibilityLabel("Memory usage guide scale")
            .accessibilityValue("Thresholds at 1 and 2 gigabytes, with lower memory usage better")
    }

    private var memoryBoundaryValueRow: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                HStack {
                    Text("Good")
                        .font(RetraceFont.font(size: 10, weight: .semibold))
                    Spacer()
                    Text("Bad")
                        .font(RetraceFont.font(size: 10, weight: .semibold))
                }

                Text("Caution")
                    .font(RetraceFont.font(size: 10, weight: .semibold))
                    .frame(width: 50, alignment: .center)
                    .offset(x: max(0, (width * 0.495) - 25))

                Text("1.0 GB")
                    .font(RetraceFont.mono(size: 10, weight: .semibold))
                    .frame(width: 52, alignment: .center)
                    .offset(x: max(0, (width * 0.33) - 26))
                Text("2.0 GB")
                    .font(RetraceFont.mono(size: 10, weight: .semibold))
                    .frame(width: 52, alignment: .center)
                    .offset(x: max(0, (width * 0.66) - 26))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 14)
        .foregroundColor(.retraceInk2)
    }

    @ViewBuilder
    private func memoryRowIconView(for displayedRow: DisplayedMemoryRow) -> some View {
        switch displayedRow.kind {
        case .primary:
            processIconView(for: displayedRow.row)
                .frame(width: 17, height: 17)
        case .retraceCategory:
            RetraceSymbol("square.split.2x1.fill", size: 11, weight: .semibold)
                .foregroundColor(.retraceAccent)
                .frame(width: 17, height: 17)
        case .retraceFamily:
            RetraceSymbol("square.stack.3d.up.fill", size: 11, weight: .semibold)
                .foregroundColor(.retraceAccent)
                .frame(width: 17, height: 17)
        case .retraceComponent:
            RetraceSymbol("circle.hexagongrid.fill", size: 10, weight: .medium)
                .foregroundColor(.retraceInk2)
                .frame(width: 17, height: 17)
        }
    }

    private func textColor(for displayedRow: DisplayedMemoryRow) -> Color {
        if displayedRow.isRetraceCategory {
            return .retraceInk
        }
        if displayedRow.isRetraceFamily {
            return .retraceInk
        }
        if displayedRow.isRetraceComponent {
            return .retraceInk2
        }
        return .retraceInk
    }

    private func leadingPadding(for displayedRow: DisplayedMemoryRow) -> CGFloat {
        if displayedRow.isRetraceComponent {
            return 42
        }
        if displayedRow.isRetraceFamily {
            return 28
        }
        if displayedRow.isRetraceCategory {
            return 14
        }
        return 0
    }

    @ViewBuilder
    private func processIconView(for row: ProcessMemoryRow) -> some View {
        Group {
            if let icon = cachedProcessIcon(for: row) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: .radiusSm / 2, style: .continuous))
            } else {
                RetraceSymbol("app.fill", size: 12)
                    .foregroundColor(.retraceInk2)
            }
        }
        .onAppear {
            requestProcessIconIfNeeded(for: row)
        }
    }

    private func cachedProcessIcon(for row: ProcessMemoryRow) -> NSImage? {
        if let bundleID = processBundleID(for: row),
           let icon = appMetadataCache.icon(for: bundleID) {
            return icon
        }

        if row.id.hasPrefix("retrace-proc:") {
            return appMetadataCache.icon(forAppPath: preferredRetraceIconAppPath())
        }

        if isRetraceProcess(row),
           let icon = appMetadataCache.icon(forAppPath: preferredRetraceIconAppPath()) {
            return icon
        }

        if row.id == "app:retrace" {
            return appMetadataCache.icon(forAppPath: preferredRetraceIconAppPath())
        }

        if let appPath = processAppPath(from: row.id),
           let icon = appMetadataCache.icon(forAppPath: appPath) {
            return icon
        }

        if let icon = appMetadataCache.icon(forProcessName: row.name) {
            return icon
        }

        return nil
    }

    private func requestProcessIconIfNeeded(for row: ProcessMemoryRow) {
        if let bundleID = processBundleID(for: row) {
            appMetadataCache.requestMetadata(for: bundleID)
            if isRetraceProcess(row) {
                appMetadataCache.requestIcon(forAppPath: preferredRetraceIconAppPath())
            }
            appMetadataCache.requestIcon(forProcessName: row.name)
            return
        }

        if row.id.hasPrefix("retrace-proc:") {
            appMetadataCache.requestIcon(forAppPath: preferredRetraceIconAppPath())
            return
        }

        if row.id == "app:retrace" {
            appMetadataCache.requestIcon(forAppPath: preferredRetraceIconAppPath())
            return
        }

        if let appPath = processAppPath(from: row.id) {
            appMetadataCache.requestIcon(forAppPath: appPath)
            return
        }

        appMetadataCache.requestIcon(forProcessName: row.name)
    }

    private func isRetraceProcess(_ row: ProcessMemoryRow) -> Bool {
        if row.id == "app:retrace" || row.id.hasPrefix("retrace-proc:") {
            return true
        }

        guard let retraceBundleID = Bundle.main.bundleIdentifier?.lowercased(),
              let bundleID = processBundleID(for: row)?.lowercased() else {
            return false
        }
        return retraceBundleID == bundleID
    }

    private func processBundleID(for row: ProcessMemoryRow) -> String? {
        if row.id.hasPrefix("bundle:") {
            return String(row.id.dropFirst("bundle:".count))
        }
        if row.id == "app:retrace" {
            return Bundle.main.bundleIdentifier
        }
        return nil
    }

    private func processAppPath(from processGroupID: String) -> String? {
        guard processGroupID.hasPrefix("app:") else { return nil }
        let rawValue = String(processGroupID.dropFirst(4))
        guard rawValue.contains("/"), rawValue.hasSuffix(".app") else { return nil }
        return rawValue
    }

    private func preferredRetraceIconAppPath() -> String {
        let installedPath = "/Applications/Retrace.app"
        if FileManager.default.fileExists(atPath: installedPath) {
            return installedPath
        }
        return Bundle.main.bundlePath
    }

    private func formatWindowDuration(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds.rounded()))
        let hours = clamped / 3600
        let minutes = clamped / 60
        let remainingMinutes = (clamped % 3600) / 60
        let remainingSeconds = clamped % 60

        if hours > 0 {
            if remainingMinutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(remainingMinutes)m"
        }
        if minutes == 0 {
            return "\(remainingSeconds)s"
        }
        if remainingSeconds == 0 {
            return "\(minutes)m"
        }
        return "\(minutes)m \(remainingSeconds)s"
    }
}
