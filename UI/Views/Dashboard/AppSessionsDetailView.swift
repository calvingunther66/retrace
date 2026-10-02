import SwiftUI
import Shared

/// Detail sheet showing all sessions for a specific app with links to open in timeline
struct AppSessionsDetailView: View {
    let app: AppUsageData
    let onOpenInTimeline: (Date) -> Void
    let loadSessions: (Int, Int) async -> [AppSessionDetail]  // (offset, limit) -> sessions
    let subtitle: String?  // Optional subtitle (e.g., window name filter)
    let initialSessionCount: Int?  // Optional override for initial session count
    let onDismiss: (() -> Void)?  // Optional dismiss callback for overlay presentation

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [AppSessionDetail] = []
    @State private var hoveredSessionID: Int64? = nil
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMoreToLoad = true
    @State private var totalSessionCount: Int

    private let pageSize = 10

    init(
        app: AppUsageData,
        onOpenInTimeline: @escaping (Date) -> Void,
        loadSessions: @escaping (Int, Int) async -> [AppSessionDetail],
        subtitle: String? = nil,
        initialSessionCount: Int? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.app = app
        self.onOpenInTimeline = onOpenInTimeline
        self.loadSessions = loadSessions
        self.subtitle = subtitle
        self.initialSessionCount = initialSessionCount
        self.onDismiss = onDismiss
        // When filtering (subtitle provided), start with 0 and update after loading
        // Otherwise use the provided count or app's count
        let startCount = initialSessionCount ?? (subtitle != nil ? 0 : app.uniqueItemCount)
        self._totalSessionCount = State(initialValue: startCount)
    }

    /// Dismisses the view using the provided callback or environment dismiss
    private func dismissView() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Rectangle().fill(Color.retraceBorder).frame(height: 1)

            // Sessions list
            if isLoading && sessions.isEmpty {
                loadingState
            } else if sessions.isEmpty {
                emptyState
            } else {
                sessionsList
            }
        }
        .frame(width: 680, height: 500)
        .background(Color.retracePage)
        .task {
            await loadInitialSessions()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            // App icon
            AppIconView(bundleID: app.appBundleID, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(app.appName)
                        .font(.retraceTitle2)
                        .foregroundColor(.retraceInk)

                    if let subtitle = subtitle {
                        Text("·")
                            .font(.retraceTitle2)
                            .foregroundColor(.retraceMuted)
                        Text(subtitle)
                            .font(.retraceCallout)
                            .foregroundColor(.retraceInk2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                HStack(spacing: 12) {
                    if subtitle == nil {
                        HStack(spacing: .space2) {
                            RetraceSymbol("clock", size: 12.5)
                            Text(formatDuration(app.duration))
                        }
                    }
                    HStack(spacing: .space2) {
                        RetraceSymbol("rectangle.stack", size: 12.5)
                        Text("\(totalSessionCount) session\(totalSessionCount == 1 ? "" : "s")")
                    }
                }
                .font(.retraceCaption)
                .monospacedDigit()
                .foregroundColor(.retraceInk2)
            }

            Spacer()

            Button(action: { dismissView() }) {
                RetraceSymbol("xmark.circle.fill", size: 22)
                    .foregroundColor(.retraceMuted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Sessions List

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(sessions) { session in
                    sessionRow(session)
                        .onAppear {
                            // Trigger load more when approaching the end
                            if session.id == sessions.last?.id {
                                Task {
                                    await loadMoreSessions()
                                }
                            }
                        }
                }

                // Loading indicator at bottom
                if isLoadingMore {
                    HStack {
                        SpinnerView(size: 16, lineWidth: 2)
                        Text("Loading more...")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                // End of list indicator
                if !hasMoreToLoad && sessions.count > pageSize {
                    Text("All \(sessions.count) sessions loaded")
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(16)
        }
    }

    private func sessionRow(_ session: AppSessionDetail) -> some View {
        let isHovered = hoveredSessionID == session.id
        let appColor = Color.segmentColor(for: session.appBundleID)

        return HStack(spacing: 14) {
            // Time indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(formatTime(session.startDate))
                    .font(.retraceMono)
                    .foregroundColor(.retraceInk)

                Text(formatDate(session.startDate))
                    .font(.retraceMeta)
                    .foregroundColor(.retraceInk2)
            }
            .frame(width: 80, alignment: .leading)

            // Duration pill
            HStack(spacing: 4) {
                Circle()
                    .fill(appColor)
                    .frame(width: 6, height: 6)

                Text(formatDuration(session.duration))
                    .font(.retraceMonoSmall)
                    .monospacedDigit()
                    .foregroundColor(.retraceInk)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(appColor.opacity(0.15)))

            // Window name (if available)
            if let windowName = session.windowName, !windowName.isEmpty {
                Text(windowName)
                    .font(.retraceCaption)
                    .foregroundColor(.retraceInk2)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }

            // Open in Timeline button
            Button(action: {
                onOpenInTimeline(session.startDate)
                dismissView()
            }) {
                HStack(spacing: 6) {
                    RetraceSymbol("play.circle.fill", size: 13.5)
                    Text("View")
                        .font(.retraceCaption2)
                }
                .foregroundColor(isHovered ? .retraceInk : .retraceInk2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .fill(isHovered ? Color.retraceAccentWash : Color.retraceSurfaceSunken)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .stroke(isHovered ? Color.retraceAccent : Color.retraceBorderStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(isHovered ? Color.retraceSurfaceHover : Color.retraceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredSessionID = hovering ? session.id : nil
            }
        }
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 16) {
            SpinnerView(size: 24, lineWidth: 3)

            Text("Loading sessions...")
                .font(.retraceMeta)
                .foregroundColor(.retraceMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            RetraceSymbol("clock.badge.questionmark", size: 48)
                .foregroundColor(.retraceMuted)

            Text("No sessions found")
                .font(.retraceMeta)
                .foregroundColor(.retraceMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadInitialSessions() async {
        let loaded = await loadSessions(0, pageSize)

        await MainActor.run {
            sessions = loaded
            hasMoreToLoad = loaded.count >= pageSize
            isLoading = false
            // Update total count if we got more than expected
            if loaded.count > totalSessionCount {
                totalSessionCount = loaded.count
            }
        }
    }

    private func loadMoreSessions() async {
        guard !isLoadingMore && hasMoreToLoad else { return }

        isLoadingMore = true
        let offset = sessions.count
        let loaded = await loadSessions(offset, pageSize)

        await MainActor.run {
            // Filter out duplicates by ID
            let existingIDs = Set(sessions.map { $0.id })
            let newSessions = loaded.filter { !existingIDs.contains($0.id) }

            sessions.append(contentsOf: newSessions)
            hasMoreToLoad = loaded.count >= pageSize
            isLoadingMore = false

            // Update total count
            totalSessionCount = max(totalSessionCount, sessions.count)
        }
    }

    // MARK: - Formatting Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, MMM d"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AppSessionsDetailView_Previews: PreviewProvider {
    static func mockLoadSessions(offset: Int, limit: Int) async -> [AppSessionDetail] {
        let totalMockSessions = 50
        let availableCount = max(0, totalMockSessions - offset)
        let count = min(limit, availableCount)

        return (0..<count).map { i in
            let index = offset + i
            return AppSessionDetail(
                id: Int64(index),
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                startDate: Date().addingTimeInterval(Double(-3600 * index)),
                endDate: Date().addingTimeInterval(Double(-3600 * index + 1800)),
                windowName: index % 3 == 0 ? nil : "Window Title \(index)"
            )
        }
    }

    static var previews: some View {
        AppSessionsDetailView(
            app: AppUsageData(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                duration: 7200,
                uniqueItemCount: 50,
                percentage: 0.35
            ),
            onOpenInTimeline: { _ in },
            loadSessions: mockLoadSessions
        )
    }
}
#endif
