import SwiftUI
import Shared

// MARK: - Migration Source Model

/// Represents a third-party app data source for migration
public struct MigrationSource: Identifiable {
    public let id: String
    public let name: String
    public let isInstalled: Bool
    public let dataPath: String?
    public let estimatedSize: Int64?

    public init(id: String, name: String, isInstalled: Bool, dataPath: String?, estimatedSize: Int64?) {
        self.id = id
        self.name = name
        self.isInstalled = isInstalled
        self.dataPath = dataPath
        self.estimatedSize = estimatedSize
    }
}

/// Migration panel for importing data from other apps
public struct MigrationPanel: View {

    // MARK: - Properties

    let sources: [MigrationSource]
    let importProgress: MigrationProgress?
    let isImporting: Bool
    let onStartImport: (MigrationSource) -> Void
    let onPauseImport: () -> Void
    let onCancelImport: () -> Void
    let onScanSources: () -> Void

    @State private var selectedSource: MigrationSource?

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: .spacingL) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import from Third-Party Apps")
                        .font(.retraceTitle2)
                        .foregroundColor(.retraceInk)

                    Text("Import your screen history from other apps")
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)
                }

                Spacer()

                Button("Scan for Data") {
                    onScanSources()
                }
                .buttonStyle(RetraceSecondaryButtonStyle())
            }

            Rectangle().fill(Color.retraceBorder).frame(height: 1)

            // Available sources
            VStack(alignment: .leading, spacing: .spacingM) {
                Text("Available Sources")
                    .font(.retraceHeadline)
                    .foregroundColor(.retraceInk)

                ForEach(sources) { source in
                    sourceRow(source: source)
                }
            }

            // Import progress (if importing)
            if isImporting, let progress = importProgress {
                Rectangle().fill(Color.retraceBorder).frame(height: 1)
                importProgressView(progress: progress)
            }
        }
        .padding(.spacingL)
        .background(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(Color.retraceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
        .retraceElevation(.sm)
    }

    // MARK: - Source Row

    private func sourceRow(source: MigrationSource) -> some View {
        HStack(spacing: .spacingM) {
            // Checkbox
            RetraceSymbol(source.isInstalled ? "checkmark.square.fill" : "square", size: 17, weight: .semibold)
                .foregroundColor(source.isInstalled ? .retraceGood : .retraceInk2)

            // Source info
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.retraceBody)
                    .foregroundColor(.retraceInk)

                if source.isInstalled, let size = source.estimatedSize {
                    Text("\(formatBytes(size)) found")
                        .font(.retraceMonoSmall)
                        .monospacedDigit()
                        .foregroundColor(.retraceInk2)
                } else {
                    Text("Not installed")
                        .font(.retraceMeta)
                        .foregroundColor(.retraceInk2)
                }
            }

            Spacer()

            // Import button
            if source.isInstalled {
                Button(isImporting && selectedSource?.id == source.id ? "Importing..." : "Import") {
                    selectedSource = source
                    onStartImport(source)
                }
                .buttonStyle(RetraceSecondaryButtonStyle())
                .disabled(isImporting)
            }
        }
        .padding(.spacingM)
        .background(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(source.isInstalled ? Color.retraceSurfaceSunken : Color.clear)
        )
    }

    // MARK: - Import Progress

    private func importProgressView(progress: MigrationProgress) -> some View {
        VStack(alignment: .leading, spacing: .spacingM) {
            Text("Importing from \(selectedSource?.name ?? "source")...")
                .font(.retraceHeadline)
                .foregroundColor(.retraceInk)

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    Capsule(style: .continuous)
                        .fill(Color.retraceSurface)
                        .frame(height: 8)
                        .overlay(Capsule(style: .continuous).stroke(Color.retraceBorder, lineWidth: 1))

                    // Progress
                    Capsule(style: .continuous)
                        .fill(Color.retraceAccent)
                        .frame(
                            width: geometry.size.width * CGFloat(progress.percentComplete),
                            height: 8
                        )
                }
            }
            .frame(height: 8)

            // Stats
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(progress.percentComplete * 100))% complete")
                        .font(.retraceMono)
                        .monospacedDigit()
                        .foregroundColor(.retraceInk)

                    HStack(spacing: 4) {
                        Text("\(formatNumber(progress.videosProcessed)) videos processed")
                        Text("·")
                        Text("\(formatNumber(progress.framesImported)) frames imported")
                    }
                    .font(.retraceMeta)
                    .monospacedDigit()
                    .foregroundColor(.retraceInk2)
                }

                Spacer()

                if let estimatedTime = progress.estimatedSecondsRemaining {
                    Text("Est. \(formatDuration(estimatedTime)) remaining")
                        .font(.retraceMeta)
                        .monospacedDigit()
                        .foregroundColor(.retraceInk2)
                }
            }

            // Actions
            HStack(spacing: .spacingM) {
                Button("Pause Import") {
                    onPauseImport()
                }
                .buttonStyle(RetraceSecondaryButtonStyle())

                Button("Cancel") {
                    onCancelImport()
                }
                .buttonStyle(RetraceDangerButtonStyle())
            }
        }
        .padding(.spacingM)
        .background(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(Color.retraceAccentWash)
        )
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = Int(seconds) / 60 % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes) minutes"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MigrationPanel_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: .spacingL) {
            // Without import
            MigrationPanel(
                sources: [
                    MigrationSource(
                        id: "rewind",
                        name: "Rewind AI",
                        isInstalled: true,
                        dataPath: "/path/to/rewind",
                        estimatedSize: 46_170_898_432 // 43 GB
                    ),
                    MigrationSource(
                        id: "screenmemory",
                        name: "ScreenMemory",
                        isInstalled: false,
                        dataPath: nil,
                        estimatedSize: nil
                    ),
                    MigrationSource(
                        id: "timescroll",
                        name: "TimeScroll",
                        isInstalled: false,
                        dataPath: nil,
                        estimatedSize: nil
                    )
                ],
                importProgress: nil,
                isImporting: false,
                onStartImport: { _ in },
                onPauseImport: {},
                onCancelImport: {},
                onScanSources: {}
            )

            // With import in progress
            MigrationPanel(
                sources: [
                    MigrationSource(
                        id: "rewind",
                        name: "Rewind AI",
                        isInstalled: true,
                        dataPath: "/path/to/rewind",
                        estimatedSize: 46_170_898_432
                    )
                ],
                importProgress: MigrationProgress(
                    state: .importing,
                    source: .rewind,
                    totalVideos: 6324,
                    videosProcessed: 2847,
                    totalFrames: 1_550_000,
                    framesImported: 1_200_000,
                    framesDeduplicated: 350_000,
                    currentVideoPath: "/path/to/video.mov",
                    bytesProcessed: 30_000_000_000,
                    totalBytes: 46_170_898_432,
                    startTime: Date().addingTimeInterval(-7200),
                    estimatedSecondsRemaining: 11520
                ),
                isImporting: true,
                onStartImport: { _ in },
                onPauseImport: {},
                onCancelImport: {},
                onScanSources: {}
            )
        }
        .padding()
        .background(Color.retraceBackground)
    }
}
#endif
