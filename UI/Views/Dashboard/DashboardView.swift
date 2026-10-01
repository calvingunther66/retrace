import AppKit
import SwiftUI
import Darwin
import Shared
import App

// MARK: - Layout Size

/// Fixed layout size for dashboard stat cards
/// Content stays at a consistent size and centers in the window
private enum LayoutSize {
    case normal

    static func from(width: CGFloat) -> LayoutSize {
        return .normal
    }

    // MARK: - Card Dimensions

    var cardWidth: CGFloat { 280 }
    var graphHeight: CGFloat { 70 }

    // MARK: - Icon Sizes

    var iconCircleSize: CGFloat { 44 }
    var iconSize: CGFloat { 17 }

    // MARK: - Text Fonts

    var titleFont: Font { .retraceLabel }
    var valueFont: Font { .retraceMediumNumber }
    var subtitleFont: Font { .retraceMeta }

    // MARK: - Spacing & Padding

    var iconSpacing: CGFloat { 14 }
    var textSpacing: CGFloat { 2 }
    var cardPadding: CGFloat { 16 }
    var graphHorizontalPadding: CGFloat { 12 }
    var graphBottomPadding: CGFloat { 8 }
}

/// Maximum width for the dashboard content area before it centers
private let dashboardMaxWidth: CGFloat = 1100
/// Shared breakpoint for compact dashboard-style layouts.
let dashboardCompactLayoutThreshold: CGFloat = 850
private let dashboardSettingsStore: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

private struct RecordingIndicatorAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct AppUsageDatePopoverAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Main dashboard view - analytics and statistics
/// Default landing screen
public struct DashboardView: View {

    // MARK: - Properties

    @ObservedObject var viewModel: DashboardViewModel
    @StateObject private var coordinatorWrapper: AppCoordinatorWrapper
    @StateObject private var crashRecoveryBannerModel: CrashRecoveryBannerModel
    @ObservedObject var launchOnLoginReminderManager: LaunchOnLoginReminderManager
    @ObservedObject var milestoneCelebrationManager: MilestoneCelebrationManager
    let debugLaunchOnboarding: (() -> Void)?
    @ObservedObject private var updaterManager = UpdaterManager.shared
    @State private var isPulsing = false
    @State private var showFeedbackSheet = false
    @State private var feedbackLaunchContext: FeedbackLaunchContext?
    @State private var feedbackPresentationID = UUID()
    @AppStorage("dashboardAppUsageViewMode", store: dashboardSettingsStore)
    private var usageViewModeRawValue: String = AppUsageViewMode.list.rawValue
    @State private var selectedApp: AppUsageData? = nil
    @State private var selectedWindow: WindowUsageData? = nil
    @State private var showSessionsSheet = false
    @State private var showSystemMonitor = false
    @State private var showAppUsageDatePopover = false
    @State private var appUsageDateFocusRequestID: UUID?
    @State private var isHoveringAppUsageRangeReset = false
    @State private var appUsageRangeShortcutMonitor: Any?
    @State private var showDiscordFollowup = false
    @State private var currentTheme: MilestoneCelebrationManager.ColorTheme = MilestoneCelebrationManager.getCurrentTheme()
    @Binding var hasLoadedInitialData: Bool
    @AppStorage("timelineShortcutConfig", store: dashboardSettingsStore)
    private var timelineShortcutData = Data()
    @AppStorage("systemMonitorShortcutConfig", store: dashboardSettingsStore)
    private var systemMonitorShortcutData = Data()

    enum AppUsageViewMode: String {
        case list = "list"
        case hardDrive = "squares"
    }

    enum AppUsageSectionBodyState: Equatable {
        case loading
        case empty
        case content
    }

    enum AppUsageRangeKeyboardShortcut: Equatable {
        case previousArrow
        case nextArrow
        case previousLetter
        case nextLetter
        case reset

        var shiftDirection: Int? {
            switch self {
            case .previousArrow, .previousLetter:
                return -1
            case .nextArrow, .nextLetter:
                return 1
            case .reset:
                return nil
            }
        }

        var metricIdentifier: String {
            switch self {
            case .previousArrow:
                return "dashboard.app_usage_date_range.previous_arrow"
            case .nextArrow:
                return "dashboard.app_usage_date_range.next_arrow"
            case .previousLetter:
                return "dashboard.app_usage_date_range.previous_l"
            case .nextLetter:
                return "dashboard.app_usage_date_range.next_semicolon"
            case .reset:
                return "dashboard.app_usage_date_range.reset_command_delete"
            }
        }

        var source: String {
            switch self {
            case .previousArrow, .previousLetter:
                return "dashboard_app_usage_previous_range_shortcut"
            case .nextArrow, .nextLetter:
                return "dashboard_app_usage_next_range_shortcut"
            case .reset:
                return "dashboard_app_usage_reset_range_shortcut"
            }
        }
    }

    struct AppUsageEmptyStateCopy: Equatable {
        let title: String
        let message: String
        let symbolName: String
    }

    private static let pauseMenuWidth: CGFloat = 100
    private static let appUsageDatePopoverWidth: CGFloat = 300

    static func appUsageSectionBodyState(
        isLoading: Bool,
        hasAppUsageData: Bool
    ) -> AppUsageSectionBodyState {
        if isLoading && !hasAppUsageData {
            return .loading
        }

        return hasAppUsageData ? .content : .empty
    }

    static func appUsageEmptyStateCopy(
        rangeLabel: String,
        hasRecordedActivity: Bool
    ) -> AppUsageEmptyStateCopy {
        if hasRecordedActivity {
            return AppUsageEmptyStateCopy(
                title: "No app usage found",
                message: "Nothing was recorded for \(rangeLabel). Use the arrows or date picker above to try another range.",
                symbolName: "tray"
            )
        }

        return AppUsageEmptyStateCopy(
            title: "No activity recorded yet",
            message: "Start using your Mac and Retrace will track your app usage automatically.",
            symbolName: "clock.badge.questionmark"
        )
    }

    static func appUsageRangeControlLabel(
        selectedRangeLabel: String,
        isDefaultLastSevenDays: Bool
    ) -> String {
        isDefaultLastSevenDays ? "Last 7 Days" : selectedRangeLabel
    }

    static func isAppUsageRangeResetEnabled(isDefaultLastSevenDays: Bool) -> Bool {
        !isDefaultLastSevenDays
    }

    static func shouldResetAppUsageRangeOnEscape(
        isDatePopoverPresented: Bool,
        isDefaultLastSevenDays: Bool
    ) -> Bool {
        !isDatePopoverPresented && !isDefaultLastSevenDays
    }

    static func appUsageRangeKeyboardShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags,
        isDatePopoverPresented: Bool,
        isFeedbackPresented: Bool,
        isSessionsPresented: Bool,
        isTextInputFocused: Bool
    ) -> AppUsageRangeKeyboardShortcut? {
        guard !isDatePopoverPresented,
              !isFeedbackPresented,
              !isSessionsPresented,
              !isTextInputFocused else {
            return nil
        }

        let normalizedModifiers = modifiers.intersection([.command, .shift, .option, .control])
        if normalizedModifiers == [.command] && (keyCode == 51 || keyCode == 117) {
            return .reset
        }
        guard normalizedModifiers.isEmpty else {
            return nil
        }

        switch keyCode {
        case 123:
            return .previousArrow
        case 124:
            return .nextArrow
        default:
            break
        }

        guard let key = charactersIgnoringModifiers?.lowercased(),
              key.count == 1 else {
            return nil
        }

        switch key {
        case "l":
            return .previousLetter
        case ";":
            return .nextLetter
        default:
            return nil
        }
    }

    private var usageViewMode: AppUsageViewMode {
        AppUsageViewMode(rawValue: usageViewModeRawValue) ?? .list
    }

    private func toggleAppUsageDatePopoverFromShortcut() {
        viewModel.recordKeyboardShortcut("cmd+g")
        withAnimation(.easeOut(duration: 0.15)) {
            showAppUsageDatePopover.toggle()
        }
    }

    private func focusAppUsageDateInputFromShortcut() {
        guard showAppUsageDatePopover else { return }
        viewModel.recordKeyboardShortcut("cmd+k")
        appUsageDateFocusRequestID = UUID()
    }

    private func resetAppUsageRangeFromInlineButton() {
        Task {
            await viewModel.resetAppUsageDateRangeToDefault(
                source: "dashboard_app_usage_inline_reset"
            )
        }
    }

    private func resetAppUsageRangeFromEscapeShortcut() {
        guard Self.shouldResetAppUsageRangeOnEscape(
            isDatePopoverPresented: showAppUsageDatePopover,
            isDefaultLastSevenDays: viewModel.isDefaultAppUsageRangeSelected
        ) else {
            return
        }

        viewModel.recordKeyboardShortcut("dashboard.app_usage_date_range.reset_escape")
        Task {
            await viewModel.resetAppUsageDateRangeToDefault(
                source: "dashboard_app_usage_escape_reset"
            )
        }
    }

    private func installAppUsageRangeShortcutMonitorIfNeeded() {
        guard appUsageRangeShortcutMonitor == nil else { return }

        appUsageRangeShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard event.window?.windowNumber == DashboardWindowController.shared.window?.windowNumber else {
                return event
            }

            let shortcut = Self.appUsageRangeKeyboardShortcut(
                keyCode: event.keyCode,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags,
                isDatePopoverPresented: showAppUsageDatePopover,
                isFeedbackPresented: showFeedbackSheet,
                isSessionsPresented: showSessionsSheet,
                isTextInputFocused: Self.isTextInputFocused(event.window?.firstResponder)
            )

            guard let shortcut else {
                return event
            }

            guard isAppUsageRangeShortcutEnabled(shortcut) else {
                return event
            }

            handleAppUsageRangeShortcut(shortcut)
            return nil
        }
    }

    private func removeAppUsageRangeShortcutMonitor() {
        guard let appUsageRangeShortcutMonitor else { return }
        NSEvent.removeMonitor(appUsageRangeShortcutMonitor)
        self.appUsageRangeShortcutMonitor = nil
    }

    private func isAppUsageRangeShortcutEnabled(_ shortcut: AppUsageRangeKeyboardShortcut) -> Bool {
        switch shortcut {
        case .previousArrow, .previousLetter:
            return viewModel.canShiftAppUsageRangeBackward
        case .nextArrow, .nextLetter:
            return viewModel.canShiftAppUsageRangeForward
        case .reset:
            return Self.isAppUsageRangeResetEnabled(
                isDefaultLastSevenDays: viewModel.isDefaultAppUsageRangeSelected
            )
        }
    }

    private func handleAppUsageRangeShortcut(_ shortcut: AppUsageRangeKeyboardShortcut) {
        viewModel.recordKeyboardShortcut(shortcut.metricIdentifier)
        Task {
            switch shortcut {
            case .previousArrow, .previousLetter, .nextArrow, .nextLetter:
                guard let shiftDirection = shortcut.shiftDirection else { return }
                await viewModel.shiftAppUsageDateRange(
                    by: shiftDirection,
                    source: shortcut.source
                )
            case .reset:
                await viewModel.resetAppUsageDateRangeToDefault(
                    source: shortcut.source
                )
            }
        }
    }

    private static func isTextInputFocused(_ responder: NSResponder?) -> Bool {
        responder is NSTextView
    }

    private var hasDashboardBanners: Bool {
        viewModel.showAccessibilityWarning
            || viewModel.showScreenRecordingWarning
            || launchOnLoginReminderManager.shouldShowReminder
            || crashRecoveryBannerModel.state != nil
            || viewModel.unexpectedRecordingStop != nil
            || viewModel.storageHealthBanner != nil
            || viewModel.ocrDegraded
            || viewModel.recentWALFailureCrash != nil
            || viewModel.recentCrashReport != nil
    }

    // MARK: - Initialization

    public init(
        viewModel: DashboardViewModel,
        coordinator: AppCoordinator,
        launchOnLoginReminderManager: LaunchOnLoginReminderManager,
        milestoneCelebrationManager: MilestoneCelebrationManager,
        debugLaunchOnboarding: (() -> Void)? = nil,
        hasLoadedInitialData: Binding<Bool> = .constant(false)
    ) {
        self.viewModel = viewModel
        _coordinatorWrapper = StateObject(wrappedValue: AppCoordinatorWrapper(coordinator: coordinator))
        _crashRecoveryBannerModel = StateObject(
            wrappedValue: CrashRecoveryBannerModel(coordinator: coordinator)
        )
        self.launchOnLoginReminderManager = launchOnLoginReminderManager
        self.milestoneCelebrationManager = milestoneCelebrationManager
        self.debugLaunchOnboarding = debugLaunchOnboarding
        self._hasLoadedInitialData = hasLoadedInitialData
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasDashboardBanners {
                VStack(spacing: 12) {
                    if viewModel.showAccessibilityWarning {
                        PermissionBanner(
                            message: "Retrace needs Accessibility permission to detect display changes and exclude private/incognito windows and excluded apps.",
                            actionTitle: "Open Settings",
                            action: {
                                SystemSettingsOpener.openAccessibilitySettings()
                            },
                            onDismiss: {
                                viewModel.dismissAccessibilityWarning()
                            }
                        )
                    }

                    if viewModel.showScreenRecordingWarning {
                        PermissionBanner(
                            message: "Retrace needs Screen Recording permission to capture your screen.",
                            actionTitle: "Open Settings",
                            action: {
                                SystemSettingsOpener.openScreenRecordingSettings()
                            },
                            onDismiss: {
                                viewModel.dismissScreenRecordingWarning()
                            },
                            isPrimary: true
                        )
                    }

                    if launchOnLoginReminderManager.shouldShowReminder {
                        PermissionBanner(
                            message: "Retrace works best when it launches automatically on login so you never miss a moment.",
                            actionTitle: "Launch on Login",
                            action: {
                                launchOnLoginReminderManager.enableLaunchAtLogin()
                            },
                            onDismiss: {
                                launchOnLoginReminderManager.dismissReminder()
                            }
                        )
                    }

                    if let statusBanner = crashRecoveryBannerModel.state {
                        CrashRecoveryStatusBanner(
                            state: statusBanner,
                            isRetrying: crashRecoveryBannerModel.isRetrying,
                            onOpenSettings: statusBanner.showsOpenSettingsAction ? {
                                crashRecoveryBannerModel.openSettings()
                            } : nil,
                            onRetry: {
                                crashRecoveryBannerModel.retry()
                            },
                            onDismiss: {
                                crashRecoveryBannerModel.dismiss()
                            }
                        )
                    }

                    if let unexpectedRecordingStop = viewModel.unexpectedRecordingStop {
                        UnexpectedRecordingStopBanner(
                            state: unexpectedRecordingStop,
                            onSubmitBugReport: {
                                viewModel.recordUnexpectedRecordingStopFeedbackOpened()
                                presentFeedbackSheet(
                                    launchContext: FeedbackLaunchContext(
                                        feedbackType: .bug,
                                        prefilledDescription: DashboardViewModel.makeUnexpectedRecordingStopFeedbackDescription(
                                            for: unexpectedRecordingStop
                                        ),
                                        preferredFocusField: .email
                                    )
                                )
                            },
                            onDismiss: {
                                viewModel.dismissUnexpectedRecordingStop()
                            }
                        )
                    }

                    if let storageHealthBanner = viewModel.storageHealthBanner {
                        StorageHealthBanner(
                            state: storageHealthBanner,
                            onDismiss: {
                                viewModel.dismissStorageHealthBanner()
                            }
                        )
                    }

                    if viewModel.ocrDegraded {
                        OCRDegradedBanner(
                            restartInFlight: viewModel.ocrRestartInFlight,
                            likelyRequiresRelaunch: viewModel.ocrRestartLikelyRequiresRelaunch,
                            onRestart: {
                                Task { await viewModel.restartOCR() }
                            },
                            onRelaunch: {
                                viewModel.relaunchAppForOCRRecovery()
                            },
                            isPrimary: !viewModel.showScreenRecordingWarning
                        )
                    }

                    if let recentWALFailureCrash = viewModel.recentWALFailureCrash {
                        WALFailureCrashBanner(
                            report: recentWALFailureCrash,
                            onSubmitBugReport: {
                                presentFeedbackSheet(
                                    launchContext: DashboardViewModel.makeWALFailureFeedbackLaunchContext(
                                        for: recentWALFailureCrash
                                    )
                                )
                            },
                            onDetails: {
                                viewModel.recordRecentWALFailureCrashDetailsOpened()
                                NSWorkspace.shared.selectFile(
                                    recentWALFailureCrash.fileURL.path,
                                    inFileViewerRootedAtPath: recentWALFailureCrash.fileURL.deletingLastPathComponent().path
                                )
                            },
                            onDismiss: {
                                viewModel.dismissRecentWALFailureCrash()
                            }
                        )
                    }

                    if let recentCrashReport = viewModel.recentCrashReport {
                        CrashReportBanner(
                            report: recentCrashReport,
                            onSubmitBugReport: {
                                presentFeedbackSheet(
                                    launchContext: DashboardViewModel.makeCrashFeedbackLaunchContext(
                                        for: recentCrashReport
                                    )
                                )
                            },
                            onDetails: {
                                viewModel.recordRecentCrashReportDetailsOpened()
                                NSWorkspace.shared.selectFile(
                                    recentCrashReport.fileURL.path,
                                    inFileViewerRootedAtPath: recentCrashReport.fileURL.deletingLastPathComponent().path
                                )
                            },
                            onDismiss: {
                                viewModel.dismissRecentCrashReport()
                            }
                        )
                    }
                }
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 20)
            }

            // Header
            header
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 32)

            // Two-column layout: metrics on left, app usage on right
            // This section expands to fill remaining height
            GeometryReader { geometry in
                let layoutSize = LayoutSize.from(width: geometry.size.width)
                let isCompactLayout = geometry.size.width < dashboardCompactLayoutThreshold

                HStack(alignment: .top, spacing: isCompactLayout ? 0 : 24) {
                    if !isCompactLayout {
                        // Left column: Stats cards (single column, fixed width)
                        ZStack {
                            ScrollView(showsIndicators: false) {
                                VStack(spacing: 16) {
                                    ForEach(statsCards) { card in
                                        statCard(
                                            icon: card.icon,
                                            title: card.title,
                                            value: card.value,
                                            subtitle: card.subtitle,
                                            graphData: card.graphData,
                                            graphColor: card.graphColor,
                                            theme: currentTheme,
                                            valueFormatter: card.valueFormatter,
                                            layoutSize: layoutSize
                                        )
                                    }
                                }
                                .padding(.top, 2)
                                .padding(.bottom, 20) // Extra padding for scroll affordance
                            }

                            ScrollAffordance(height: 32, color: themeScrollAffordanceColor)
                        }
                        .frame(width: layoutSize.cardWidth)
                    }

                    // Right column: App usage (scrolls internally)
                    appUsageSection(layoutSize: layoutSize)
                }
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            // Footer
            footer
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .sheet(
            isPresented: $showFeedbackSheet,
            onDismiss: {
                feedbackLaunchContext = nil
            }
        ) {
            FeedbackFormView(launchContext: feedbackLaunchContext)
                .id(feedbackPresentationID)
            .environmentObject(coordinatorWrapper)
        }
        .background(
            Color.retracePage
                .ignoresSafeArea()
        )
        .background(
            Button("") {
                Task { await viewModel.loadStatistics() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
        )
        .onAppear {
            installAppUsageRangeShortcutMonitorIfNeeded()
        }
        .onDisappear {
            removeAppUsageRangeShortcutMonitor()
        }
        .task {
            viewModel.isWindowVisible = true
            crashRecoveryBannerModel.refresh()
            if !hasLoadedInitialData {
                hasLoadedInitialData = true
                Log.debug("[Dashboard] Initial load - first appearance", category: .ui)
                await viewModel.loadStatistics()
            } else {
                Log.debug("[Dashboard] Tab switch - skipping reload", category: .ui)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardDidBecomeKey)) { _ in
            Log.debug("[Dashboard] Window became key - refreshing", category: .ui)
            Task { await viewModel.loadStatistics() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardDidOpen)) { _ in
            viewModel.isWindowVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardDidClose)) { _ in
            viewModel.isWindowVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .colorThemeDidChange)) { notification in
            if let newTheme = notification.object as? MilestoneCelebrationManager.ColorTheme {
                currentTheme = newTheme
            }
        }
        .overlayPreferenceValue(RecordingIndicatorAnchorPreferenceKey.self) { anchor in
            GeometryReader { proxy in
                if showPauseOptionsPopover, let anchor {
                    let anchorRect = proxy[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    showPauseOptionsPopover = false
                                }
                            }

                        pauseRecordingMenu
                            .frame(width: Self.pauseMenuWidth)
                            .offset(
                                x: pauseMenuOriginX(
                                    anchorRect: anchorRect,
                                    containerWidth: proxy.size.width,
                                    menuWidth: Self.pauseMenuWidth
                                ),
                                y: anchorRect.maxY + 6
                            )
                            .transition(
                                .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .zIndex(showPauseOptionsPopover ? 20 : 0)
        }
        .overlayPreferenceValue(AppUsageDatePopoverAnchorPreferenceKey.self) { anchor in
            GeometryReader { proxy in
                if showAppUsageDatePopover, let anchor {
                    let anchorRect = proxy[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    showAppUsageDatePopover = false
                                    appUsageDateFocusRequestID = nil
                                }
                            }

                        appUsageDatePopover
                            .retraceElevation(.lg)
                            .offset(
                                x: max(anchorRect.maxX - Self.appUsageDatePopoverWidth, 0),
                                y: anchorRect.maxY + 8
                            )
                            .transition(
                                .opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing))
                            )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .zIndex(showAppUsageDatePopover ? 15 : 0)
        }
        .overlay {
            // Sessions detail overlay (replaces .sheet for faster presentation)
            if showSessionsSheet, let app = selectedApp {
                ZStack {
                    // Dimmed background
                    Color.retraceDynamic(light: 0x3B352D, dark: 0x000000, lightAlpha: 0.4, darkAlpha: 0.6)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showSessionsSheet = false
                            }
                        }

                    // Sessions detail dialog
                    Group {
                        if let window = selectedWindow {
                            // Window-filtered sessions
                            AppSessionsDetailView(
                                app: app,
                                onOpenInTimeline: { date in
                                    showSessionsSheet = false
                                    openTimelineAt(date: date)
                                },
                                loadSessions: { offset, limit in
                                    await viewModel.getSessionsForAppWindow(
                                        bundleID: app.appBundleID,
                                        windowNameOrDomain: window.displayName,
                                        offset: offset,
                                        limit: limit
                                    )
                                },
                                subtitle: window.displayName,
                                onDismiss: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        showSessionsSheet = false
                                    }
                                }
                            )
                        } else {
                            // All sessions for app
                            AppSessionsDetailView(
                                app: app,
                                onOpenInTimeline: { date in
                                    showSessionsSheet = false
                                    openTimelineAt(date: date)
                                },
                                loadSessions: { offset, limit in
                                    await viewModel.getSessionsForApp(
                                        bundleID: app.appBundleID,
                                        offset: offset,
                                        limit: limit
                                    )
                                },
                                onDismiss: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        showSessionsSheet = false
                                    }
                                }
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: .radiusLg, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusLg, style: .continuous)
                            .stroke(Color.retraceBorder, lineWidth: 1)
                    )
                    .retraceElevation(.lg)
                    .transition(.scale.combined(with: .opacity))
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showSessionsSheet)
            }
        }
        .overlay {
            ZStack {
                // Milestone celebration dialog
                if let milestone = milestoneCelebrationManager.currentMilestone {
                    ZStack {
                        // Dimmed background
                        Color.retraceDynamic(light: 0x3B352D, dark: 0x000000, lightAlpha: 0.4, darkAlpha: 0.6)
                            .ignoresSafeArea()
                            .onTapGesture {
                                // Dismiss on background tap
                                milestoneCelebrationManager.dismissCurrentMilestone()
                            }

                        // Celebration dialog
                        MilestoneCelebrationView(
                            milestone: milestone,
                            onDismiss: {
                                milestoneCelebrationManager.dismissCurrentMilestone()
                            },
                            onMaybeLater: {
                                milestoneCelebrationManager.dismissCurrentMilestone()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showDiscordFollowup = true
                                }
                            },
                            onSupport: {
                                milestoneCelebrationManager.openSupportLink()
                            }
                        )
                        .transition(.scale.combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: milestone)
                }

                if showDiscordFollowup {
                    ZStack {
                        Color.retraceDynamic(light: 0x3B352D, dark: 0x000000, lightAlpha: 0.4, darkAlpha: 0.6)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showDiscordFollowup = false
                                }
                            }

                        DiscordFollowupView(
                            onJoin: {
                                milestoneCelebrationManager.openDiscordLink()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showDiscordFollowup = false
                                }
                            },
                            onMaybeLater: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showDiscordFollowup = false
                                }
                            }
                        )
                        .transition(.scale.combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showDiscordFollowup)
                }
            }
        }
    }

    // MARK: - App Session Actions

    private func handleAppTapped(_ app: AppUsageData) {
        selectedApp = app
        selectedWindow = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showSessionsSheet = true
        }
    }

    private func handleWindowTapped(_ app: AppUsageData, _ window: WindowUsageData) {
        let clickStartTime = CFAbsoluteTimeGetCurrent()
        let selectedRange = viewModel.appUsageQueryRange

        // Launch filtered timeline instantly instead of showing sessions dialog
        TimelineWindowController.shared.showWithFilter(
            bundleID: app.appBundleID,
            windowName: window.windowName,
            browserUrl: window.browserUrl,
            startDate: selectedRange.start,
            endDate: selectedRange.end,
            clickStartTime: clickStartTime
        )
    }

    private func openTimelineAt(date: Date) {
        // Show the timeline and navigate to the specific date
        TimelineWindowController.shared.showAndNavigate(to: date)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                // Retrace logo + Dashboard text
                HStack(spacing: 8) {
                    RetraceMarkView(size: 22)

                    Text("Dashboard")
                        .font(.retraceTitle)
                        .foregroundColor(.retraceInk)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                // Recording status indicator
                recordingIndicator

                // Action buttons
                openTimelineButton
                monitorButton
                if updaterManager.shouldShowWhatsNew {
                    changelogButton
                }
                settingsButton
            }
        }
    }

    private func actionButton(icon: String, label: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RetraceSymbol(icon, size: 13.5)
                if let label = label {
                    Text(label)
                        .font(.retraceCaptionMedium)
                }
            }
            .foregroundColor(.retraceInk2)
            .padding(.horizontal, label != nil ? 14 : 10)
            .padding(.vertical, label != nil ? 8 : 10)
            .background(Color.retraceSurface)
            .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .stroke(Color.retraceBorderStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Action Button States

    @State private var isHoveringTimeline = false
    @State private var isHoveringSettings = false
    @State private var settingsRotation: Double = 0

    private var timelineTooltipText: String {
        tooltipText(
            title: "Open Timeline",
            shortcut: decodedShortcut(from: timelineShortcutData, fallback: .defaultTimeline)
        )
    }

    private var systemMonitorTooltipText: String {
        tooltipText(
            title: "Open System Monitor",
            shortcut: decodedShortcut(from: systemMonitorShortcutData, fallback: .defaultSystemMonitor)
        )
    }

    private var settingsTooltipText: String {
        tooltipText(title: "Open Settings", shortcutText: "⌘,")
    }

    // MARK: - Footer Hover States

    @State private var isHoveringHaseab = false
    @State private var isHoveringSupportMe = false
    @State private var isHoveringFeedback = false

    // MARK: - Timeline Button

    private var openTimelineButton: some View {
        Button(action: {
            TimelineWindowController.shared.show()
        }) {
            RetraceSymbol("clock.arrow.circlepath", size: 13.5)
                .foregroundColor(.retraceInk2)
                .padding(10)
                .background(Color.retraceSurface)
                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .stroke(Color.retraceBorderStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open timeline")
        .contentShape(Rectangle())
        .scaleEffect(isHoveringTimeline ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHoveringTimeline)
        .compactTopTooltip(timelineTooltipText, isVisible: $isHoveringTimeline)
        .onHover { hovering in
            isHoveringTimeline = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Monitor Button

    private var monitorButton: some View {
        MonitorButton(
            isProcessing: viewModel.ocrQueueDepth > 0,
            tooltipText: systemMonitorTooltipText
        )
    }

    // MARK: - Changelog Button

    private var changelogButton: some View {
        actionButton(icon: "sparkles", label: "What's New") {
            NotificationCenter.default.post(
                name: .openDashboard,
                object: nil,
                userInfo: ["target": "changelog"]
            )
        }
    }

    // MARK: - Settings Button

    private var settingsButton: some View {
        Button(action: {
            // Quick spin on click
            withAnimation(.easeInOut(duration: 0.3)) {
                settingsRotation += 90
            }
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }) {
            RetraceSymbol("gearshape", size: 13.5)
                .foregroundColor(.retraceInk2)
                .rotationEffect(.degrees(settingsRotation + (isHoveringSettings ? 30 : 0)))
                .animation(.easeInOut(duration: 0.2), value: isHoveringSettings)
                .padding(10)
                .background(Color.retraceSurface)
                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .stroke(Color.retraceBorderStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open settings")
        .contentShape(Rectangle())
        .scaleEffect(isHoveringSettings ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHoveringSettings)
        .compactTopTooltip(settingsTooltipText, isVisible: $isHoveringSettings)
        .onHover { hovering in
            isHoveringSettings = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func decodedShortcut(from data: Data, fallback: ShortcutConfig) -> ShortcutConfig {
        guard !data.isEmpty,
              let shortcut = try? JSONDecoder().decode(ShortcutConfig.self, from: data) else {
            return fallback
        }
        return shortcut
    }

    private func tooltipText(title: String, shortcut: ShortcutConfig) -> String {
        guard !shortcut.key.isEmpty else { return title }
        return tooltipText(title: title, shortcutText: formattedShortcut(shortcut))
    }

    private func tooltipText(title: String, shortcutText: String) -> String {
        "\(title)\n(\(shortcutText))"
    }

    private func formattedShortcut(_ shortcut: ShortcutConfig) -> String {
        shortcut.modifiers.displaySymbols.joined() + shortcut.key
    }

    // MARK: - Recording Indicator

    @State private var isHoveringRecordingIndicator = false
    @State private var showPauseOptionsPopover = false

    private var recordingIndicator: some View {
        Button(action: {
            if viewModel.isRecording {
                withAnimation(.easeOut(duration: 0.12)) {
                    showPauseOptionsPopover.toggle()
                }
            } else {
                Task {
                    await viewModel.toggleRecording(to: true)
                }
            }
        }) {
            HStack(spacing: 6) {
                if viewModel.isRecording && isHoveringRecordingIndicator {
                    RetraceSymbol("pause.fill", size: 8, weight: .regular)
                        .foregroundColor(.retraceInk2)
                        .frame(width: 6)
                        .transition(.opacity)
                } else if viewModel.recordingPauseRemainingSeconds != nil {
                    RetraceSymbol("timer", size: 9, weight: .semibold)
                        .foregroundColor(.retraceInk2)
                        .frame(width: 8)
                        .transition(.opacity)
                } else if viewModel.isRecordingPaused {
                    RetraceSymbol("pause.circle", size: 9, weight: .semibold)
                        .foregroundColor(.retraceInk2)
                        .frame(width: 8)
                        .transition(.opacity)
                } else {
                    Circle()
                        .fill(viewModel.isRecording ? Color.retraceCritical : Color.retraceMuted)
                        .frame(width: 6, height: 6)
                        .transition(.opacity)
                }

                Text(recordingIndicatorLabel)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceInk2)
                    .contentTransition(.interpolate)
                    .frame(width: 74, alignment: .center)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.retraceSurface)
            .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .stroke(Color.retraceBorderStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isHoveringRecordingIndicator)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isRecording)
        .anchorPreference(key: RecordingIndicatorAnchorPreferenceKey.self, value: .bounds) { $0 }
        // .instantTooltip("Toggle Recording  ⌘⇧R", isVisible: $isHoveringRecordingIndicator)
        .onHover { hovering in
            isHoveringRecordingIndicator = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var recordingIndicatorLabel: String {
        if viewModel.isRecording {
            return isHoveringRecordingIndicator ? "Pause" : "Recording"
        } else if let seconds = viewModel.recordingPauseRemainingSeconds {
            return isHoveringRecordingIndicator ? "Start Rec." : formatPauseCountdown(seconds)
        } else if viewModel.isRecordingPaused {
            return isHoveringRecordingIndicator ? "Start Rec." : "Paused"
        } else {
            return isHoveringRecordingIndicator ? "Start Rec." : "Off"
        }
    }

    private func formatPauseCountdown(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let remainingSeconds = clamped % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private var pauseRecordingMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            PauseMenuOptionRow(title: "5 min") {
                handlePauseSelection(duration: 5 * 60)
            }
            PauseMenuOptionRow(title: "30 min") {
                handlePauseSelection(duration: 30 * 60)
            }
            PauseMenuOptionRow(title: "60 min") {
                handlePauseSelection(duration: 60 * 60)
            }

            Rectangle().fill(Color.retraceBorder).frame(height: 1)
                .padding(.vertical, 1)

            PauseMenuOptionRow(title: "Turn Off") {
                handlePauseSelection(duration: nil)
            }
        }
        .padding(4)
        .retraceMenuContainer(addPadding: false)
    }

    private func handlePauseSelection(duration: TimeInterval?) {
        withAnimation(.easeOut(duration: 0.12)) {
            showPauseOptionsPopover = false
        }
        Task {
            await viewModel.pauseRecording(for: duration)
        }
    }

    private func pauseMenuOriginX(anchorRect: CGRect, containerWidth: CGFloat, menuWidth: CGFloat) -> CGFloat {
        let horizontalPadding: CGFloat = 16
        let desiredX = anchorRect.minX
        return min(
            max(horizontalPadding, desiredX),
            max(horizontalPadding, containerWidth - menuWidth - horizontalPadding)
        )
    }

    private struct PauseMenuOptionRow: View {
        let title: String
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(RetraceFont.font(size: 12.5, weight: .medium))
                        .foregroundColor(isHovering ? .retraceInk : .retraceInk2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .fill(isHovering ? Color.retraceSurfaceHover : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    isHovering = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
    }

    // MARK: - Stats Cards Row

    private struct StatCardData: Identifiable {
        let id: String
        let icon: String
        let title: String
        let value: String
        let subtitle: String
        let graphData: [DailyDataPoint]?
        let graphColor: Color
        let valueFormatter: ((Int64) -> String)?

        init(icon: String, title: String, value: String, subtitle: String, graphData: [DailyDataPoint]? = nil, graphColor: Color = .retraceAccent, valueFormatter: ((Int64) -> String)? = nil) {
            self.id = title
            self.icon = icon
            self.title = title
            self.value = value
            self.subtitle = subtitle
            self.graphData = graphData
            self.graphColor = graphColor
            self.valueFormatter = valueFormatter
        }
    }

    private var statsCards: [StatCardData] {
        let selectedRangeLabel = viewModel.appUsageRangeLabel
        let isDefaultLastSevenDays = viewModel.isDefaultAppUsageRangeSelected
        let activitySubtitle = isDefaultLastSevenDays ? "Last 7 days" : selectedRangeLabel
        let daysRecordedTitle = isDefaultLastSevenDays ? "Total Days Recorded" : "Days Selected"
        let daysRecordedSubtitle = formatRecordedHoursSubtitle(
            isDefaultLastSevenDays ? viewModel.totalCapturedDuration : viewModel.totalWeeklyTime
        )
        let storageTitle = isDefaultLastSevenDays ? "Total Storage Used" : "Storage Used"
        let storageValue = formatStorageSize(isDefaultLastSevenDays ? viewModel.totalStorageBytes : viewModel.weeklyStorageBytes)
        let storageSubtitle = isDefaultLastSevenDays ? formatStoragePerMonth() : selectedRangeLabel
        let totalDaysValue = isDefaultLastSevenDays ? viewModel.daysRecorded : viewModel.appUsageRangeDaySpan

        return [
            StatCardData(
                icon: "calendar",
                title: daysRecordedTitle,
                value: "\(totalDaysValue) days",
                subtitle: daysRecordedSubtitle
            ),
            StatCardData(
                icon: "clock.fill",
                title: "Screen Time",
                value: formatScreenTimeFromDaily(viewModel.dailyScreenTimeData),
                subtitle: activitySubtitle,
                graphData: viewModel.dailyScreenTimeData.isEmpty ? nil : viewModel.dailyScreenTimeData,
                graphColor: .retraceSeries1,
                valueFormatter: { milliseconds in
                    let hours = Double(milliseconds) / 1000.0 / 3600.0
                    return String(format: "%.1fh", hours)
                }
            ),
            StatCardData(
                icon: "externaldrive.fill",
                title: storageTitle,
                value: storageValue,
                subtitle: storageSubtitle,
                graphData: viewModel.dailyStorageData.isEmpty ? nil : viewModel.dailyStorageData,
                graphColor: .retraceSeries1
            ),
            StatCardData(
                icon: "timelapse",
                title: "Timeline Opens",
                value: "\(viewModel.timelineOpensThisWeek)",
                subtitle: activitySubtitle,
                graphData: viewModel.dailyTimelineOpensData.isEmpty ? nil : viewModel.dailyTimelineOpensData,
                graphColor: .retraceSeries1
            ),
            StatCardData(
                icon: "magnifyingglass",
                title: "Searches",
                value: "\(viewModel.searchesThisWeek)",
                subtitle: activitySubtitle,
                graphData: viewModel.dailySearchesData.isEmpty ? nil : viewModel.dailySearchesData,
                graphColor: .retraceSeries1
            ),
            StatCardData(
                icon: "doc.on.doc",
                title: "Text Copies",
                value: "\(viewModel.textCopiesThisWeek)",
                subtitle: activitySubtitle,
                graphData: viewModel.dailyTextCopiesData.isEmpty ? nil : viewModel.dailyTextCopiesData,
                graphColor: .retraceSeries1
            ),
        ]
    }

    private func statCard(
        icon: String,
        title: String,
        value: String,
        subtitle: String,
        graphData: [DailyDataPoint]?,
        graphColor: Color,
        theme: MilestoneCelebrationManager.ColorTheme,
        valueFormatter: ((Int64) -> String)?,
        layoutSize: LayoutSize = .normal
    ) -> some View {
        // One accent color for all icons
        let iconColor = Color.retraceAccent

        return VStack(spacing: 0) {
            HStack(spacing: layoutSize.iconSpacing) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.retraceAccentWash)
                        .frame(width: layoutSize.iconCircleSize, height: layoutSize.iconCircleSize)

                    RetraceSymbol(icon, size: layoutSize.iconSize, weight: .semibold, label: "")
                        .foregroundColor(iconColor)
                }

                VStack(alignment: .leading, spacing: layoutSize.textSpacing) {
                    Text(title)
                        .font(layoutSize.titleFont)
                        .retraceLabelTracking()
                        .foregroundColor(.retraceInk2)

                    Text(value)
                        .font(layoutSize.valueFont)
                        .monospacedDigit()
                        .foregroundColor(.retraceInk)

                    Text(subtitle)
                        .font(layoutSize.subtitleFont)
                        .foregroundColor(.retraceMuted)
                }

                Spacer()
            }
            .padding(layoutSize.cardPadding)

            // Mini line graph (if data is available)
            if let data = graphData, !data.isEmpty {
                MiniLineGraphView(
                    dataPoints: data,
                    lineColor: graphColor,
                    showGradientFill: true,
                    valueFormatter: valueFormatter
                )
                .frame(height: layoutSize.graphHeight)
                .padding(.horizontal, layoutSize.graphHorizontalPadding)
                .padding(.bottom, layoutSize.graphBottomPadding)
            }
        }
        .frame(maxWidth: .infinity)
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

    private func formatStorageSize(_ bytes: Int64) -> String {
        // Use decimal (SI) units to match Finder
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else {
            let mb = Double(bytes) / 1_000_000
            return String(format: "%.0f MB", mb)
        }
    }

    private func formatStoragePerMonth() -> String {
        let dailyData = viewModel.dailyStorageData
        guard !dailyData.isEmpty else { return "est. 0 GB/month" }

        // Estimate based on current loaded daily storage series.
        let totalBytes = dailyData.reduce(0) { $0 + $1.value }
        let daysWithData = dailyData.count
        let bytesPerDay = Double(totalBytes) / Double(daysWithData)
        let bytesPerMonth = bytesPerDay * 30.0
        let gbPerMonth = bytesPerMonth / 1_000_000_000
        return String(format: "est. %.1f GB/month", gbPerMonth)
    }

    // MARK: - App Usage Section

    private func appUsageSection(layoutSize: LayoutSize) -> some View {
        let appUsageLayout: AppUsageLayoutSize = .normal

        return VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Text("App Usage")
                    .font(.retraceHeadline)
                    .foregroundColor(.retraceInk)

                Spacer()

                appUsageRangeControls
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .zIndex(showAppUsageDatePopover ? 10 : 1)

            Rectangle().fill(Color.retraceBorder).frame(height: 1)
                .zIndex(showAppUsageDatePopover ? 9 : 0)

            appUsageSectionBody(layoutSize: appUsageLayout)
        }
        .background(
            RoundedRectangle(cornerRadius: .radiusLg, style: .continuous)
                .fill(Color.retraceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusLg, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
        .retraceElevation(.sm)
    }

    @ViewBuilder
    private func appUsageSectionBody(layoutSize: AppUsageLayoutSize) -> some View {
        switch Self.appUsageSectionBodyState(
            isLoading: viewModel.isLoading,
            hasAppUsageData: !viewModel.weeklyAppUsage.isEmpty
        ) {
        case .loading:
            appUsageLoadingBody
        case .empty:
            appUsageEmptyBody
        case .content:
            switch usageViewMode {
            case .list:
                AppUsageListView(
                    apps: viewModel.weeklyAppUsage,
                    totalTime: viewModel.totalWeeklyTime,
                    layoutSize: layoutSize,
                    scrollAffordanceColor: themeScrollAffordanceColor,
                    loadWindowUsage: { bundleID, visibleCount in
                        await viewModel.getWindowUsageForApp(bundleID: bundleID, limit: visibleCount)
                    },
                    loadTabsForDomain: { bundleID, domain in
                        await viewModel.getBrowserTabsForDomain(bundleID: bundleID, domain: domain)
                    },
                    onWindowTapped: { app, window in
                        handleWindowTapped(app, window)
                    }
                )
                .id(
                    "app-usage-list-\(Int(viewModel.appUsageRangeStart.timeIntervalSince1970))-\(Int(viewModel.appUsageRangeEnd.timeIntervalSince1970))"
                )
                .zIndex(0)
            case .hardDrive:
                AppUsageHardDriveView(
                    apps: viewModel.weeklyAppUsage,
                    totalTime: viewModel.totalWeeklyTime,
                    onAppTapped: { app in
                        handleAppTapped(app)
                    }
                )
                .id(
                    "app-usage-hard-drive-\(Int(viewModel.appUsageRangeStart.timeIntervalSince1970))-\(Int(viewModel.appUsageRangeEnd.timeIntervalSince1970))"
                )
                .zIndex(0)
            }
        }
    }

    /// Scroll-edge fades match the page surface.
    private var themeScrollAffordanceColor: Color {
        Color.retracePage
    }

    private var appUsageRangeControls: some View {
        let rangeControlLabel = Self.appUsageRangeControlLabel(
            selectedRangeLabel: viewModel.appUsageRangeLabel,
            isDefaultLastSevenDays: viewModel.isDefaultAppUsageRangeSelected
        )
        let isResetEnabled = Self.isAppUsageRangeResetEnabled(
            isDefaultLastSevenDays: viewModel.isDefaultAppUsageRangeSelected
        )

        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                rangeShiftButton(
                    icon: "chevron.left",
                    position: .leading,
                    isEnabled: viewModel.canShiftAppUsageRangeBackward
                ) {
                    Task {
                        await viewModel.shiftAppUsageDateRange(
                            by: -1,
                            source: "dashboard_app_usage_previous_range"
                        )
                    }
                }

                Rectangle()
                    .fill(Color.retraceBorder)
                    .frame(width: 1, height: 30)

                HStack(spacing: 2) {
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showAppUsageDatePopover.toggle()
                        }
                    }) {
                        HStack(spacing: 6) {
                            RetraceSymbol("calendar", size: 12)
                            Text(rangeControlLabel)
                                .font(.retraceCaptionMedium)
                        }
                        .foregroundColor(.retraceInk2)
                        .padding(.leading, 12)
                        .padding(.trailing, isResetEnabled ? 4 : 12)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }

                    if isResetEnabled {
                        Button(action: {
                            resetAppUsageRangeFromInlineButton()
                        }) {
                            RetraceSymbol("arrow.counterclockwise", size: 10, weight: .semibold)
                                .foregroundColor(.retraceInk2)
                                .padding(.leading, 2)
                                .padding(.trailing, 12)
                                .frame(height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reset date range")
                        .onHover { hovering in
                            isHoveringAppUsageRangeReset = hovering
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .instantTooltip(
                            "Reset Range (⌘⌫)",
                            isVisible: $isHoveringAppUsageRangeReset,
                            placement: .bottom
                        )
                        .zIndex(isHoveringAppUsageRangeReset ? 2 : 0)
                    }
                }
                .frame(height: 30)
                .background(showAppUsageDatePopover ? Color.retraceSurfaceHover : Color.clear)
                .anchorPreference(
                    key: AppUsageDatePopoverAnchorPreferenceKey.self,
                    value: .bounds
                ) { $0 }
                .background {
                    Group {
                        Button(action: {
                            toggleAppUsageDatePopoverFromShortcut()
                        }) {
                            EmptyView()
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("g", modifiers: .command)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                        Button(action: {
                            focusAppUsageDateInputFromShortcut()
                        }) {
                            EmptyView()
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("k", modifiers: .command)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                        if Self.shouldResetAppUsageRangeOnEscape(
                            isDatePopoverPresented: showAppUsageDatePopover,
                            isDefaultLastSevenDays: viewModel.isDefaultAppUsageRangeSelected
                        ) {
                            Button(action: {
                                resetAppUsageRangeFromEscapeShortcut()
                            }) {
                                EmptyView()
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.escape, modifiers: [])
                            .frame(width: 0, height: 0)
                            .opacity(0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                }

                Rectangle()
                    .fill(Color.retraceBorder)
                    .frame(width: 1, height: 30)

                rangeShiftButton(
                    icon: "chevron.right",
                    position: .trailing,
                    isEnabled: viewModel.canShiftAppUsageRangeForward
                ) {
                    Task {
                        await viewModel.shiftAppUsageDateRange(
                            by: 1,
                            source: "dashboard_app_usage_next_range"
                        )
                    }
                }
            }
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: .radiusSm,
                    bottomLeadingRadius: .radiusSm,
                    bottomTrailingRadius: .radiusSm,
                    topTrailingRadius: .radiusSm
                )
                .fill(Color.retraceSurface)
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: .radiusSm,
                    bottomLeadingRadius: .radiusSm,
                    bottomTrailingRadius: .radiusSm,
                    topTrailingRadius: .radiusSm
                )
                .stroke(showAppUsageDatePopover ? Color.retraceAccent : Color.retraceBorderStrong, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var appUsageDatePopover: some View {
        let isResetEnabled = Self.isAppUsageRangeResetEnabled(
            isDefaultLastSevenDays: viewModel.isDefaultAppUsageRangeSelected
        )

        DateRangeFilterPopover(
            dateRanges: [viewModel.appUsageDateRange],
            onApply: { ranges in
                withAnimation(.easeOut(duration: 0.15)) {
                    showAppUsageDatePopover = false
                    appUsageDateFocusRequestID = nil
                }
                guard let selectedRange = ranges.first else { return }
                Task {
                    await viewModel.setAppUsageDateRange(
                        from: selectedRange,
                        source: "dashboard_app_usage_calendar_apply"
                    )
                }
            },
            onClear: {
                withAnimation(.easeOut(duration: 0.15)) {
                    showAppUsageDatePopover = false
                    appUsageDateFocusRequestID = nil
                }
                Task {
                    await viewModel.resetAppUsageDateRangeToDefault(
                        source: "dashboard_app_usage_calendar_clear"
                    )
                }
            },
            width: Self.appUsageDatePopoverWidth,
            enableKeyboardNavigation: true,
            allowMultipleRanges: false,
            maxRangeDays: DashboardViewModel.maxAppUsageRangeDays,
            onQuickPresetShortcut: { preset in
                viewModel.recordKeyboardShortcut("dashboard.app_usage_date_range.\(preset.rawValue)")
            },
            onClearShortcut: {
                viewModel.recordKeyboardShortcut("dashboard.app_usage_date_range.clear")
            },
            focusPrimaryInputRequestID: appUsageDateFocusRequestID,
            isResetEnabled: isResetEnabled,
            onDismiss: {
                withAnimation(.easeOut(duration: 0.15)) {
                    showAppUsageDatePopover = false
                    appUsageDateFocusRequestID = nil
                }
            }
        )
    }

    private enum RangeShiftButtonPosition {
        case leading
        case trailing
    }

    private func rangeShiftButton(
        icon: String,
        position: RangeShiftButtonPosition,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            RetraceSymbol(icon, size: 10, weight: .semibold)
                .foregroundColor(.retraceInk2)
                .opacity(isEnabled ? 1 : 0.5)
                .frame(width: 30, height: 30)
                .background(
                    Group {
                        if position == .leading {
                            UnevenRoundedRectangle(
                                topLeadingRadius: .radiusSm,
                                bottomLeadingRadius: .radiusSm,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: 0
                            )
                            .fill(Color.clear)
                        } else {
                            UnevenRoundedRectangle(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: 0,
                                bottomTrailingRadius: .radiusSm,
                                topTrailingRadius: .radiusSm
                            )
                            .fill(Color.clear)
                        }
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(position == .leading ? "Previous date range" : "Next date range")
        .disabled(!isEnabled)
        .onHover { hovering in
            guard isEnabled else { return }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var appUsageLoadingBody: some View {
        return VStack(spacing: 16) {
            SpinnerView(size: 32, lineWidth: 3)

            Text("Loading activity...")
                .font(.retraceMeta)
                .foregroundColor(.retraceMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
    }

    private var appUsageEmptyBody: some View {
        let copy = Self.appUsageEmptyStateCopy(
            rangeLabel: viewModel.appUsageRangeLabel,
            hasRecordedActivity: viewModel.daysRecorded > 0
        )

        return VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.retraceAccentWash)
                    .frame(width: 80, height: 80)

                RetraceSymbol(copy.symbolName, size: 32, weight: .semibold)
                    .foregroundColor(.retraceAccent)
            }

            VStack(spacing: 8) {
                Text(copy.title)
                    .font(.retraceHeadline)
                    .foregroundColor(.retraceInk)

                Text(copy.message)
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://retrace.to/l/haseab-twitter")!) {
                    HStack(spacing: 4) {
                        Text("Made with")
                            .foregroundColor(.retraceInk2)
                        Text("❤️")
                        Text("by")
                            .foregroundColor(.retraceInk2)
                        Text("@haseab")
                            .foregroundColor(.retraceAccent)
                            .scaleEffect(isHoveringHaseab ? 1.05 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: isHoveringHaseab)
                    }
                    .font(.retraceCaption2Medium)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringHaseab = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                Circle()
                    .fill(Color.retraceMuted)
                    .frame(width: 3, height: 3)

                Link(destination: URL(string: "https://retrace.to/l/support-haseab")!) {
                    HStack(spacing: 6) {
                        RetraceSymbol("cup.and.saucer.fill", size: 12)
                        Text("Support Me")
                    }
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceInk2)
                    .scaleEffect(isHoveringSupportMe ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHoveringSupportMe)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringSupportMe = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                Circle()
                    .fill(Color.retraceMuted)
                    .frame(width: 3, height: 3)

                Button(action: {
                    presentFeedbackSheet()
                }) {
                    HStack(spacing: 6) {
                        RetraceSymbol("questionmark.circle", size: 13.5)
                        Text("Help")
                            .font(.retraceCaptionMedium)
                    }
                    .foregroundColor(.retraceInk2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.retraceSurface)
                    .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .stroke(Color.retraceBorderStrong, lineWidth: 1)
                    )
                    .scaleEffect(isHoveringFeedback ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHoveringFeedback)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .onHover { hovering in
                    isHoveringFeedback = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                Circle()
                    .fill(Color.retraceMuted)
                    .frame(width: 3, height: 3)

                Group {
                    if let url = BuildInfo.commitURL {
                        Text(BuildInfo.displayVersion)
                            .onTapGesture { NSWorkspace.shared.open(url) }
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                    } else {
                        Text(BuildInfo.displayVersion)
                    }
                }
                .font(.retraceCaption2)
                .foregroundColor(.retraceMuted)

                #if DEBUG
                Circle()
                    .fill(Color.retraceMuted)
                    .frame(width: 3, height: 3)

                Menu {
                    Button("Show 10h Milestone") {
                        milestoneCelebrationManager.currentMilestone = .tenHours
                    }
                    Button("Show 100h Milestone") {
                        milestoneCelebrationManager.currentMilestone = .hundredHours
                    }
                    Button("Show 1000h Milestone") {
                        milestoneCelebrationManager.currentMilestone = .thousandHours
                    }
                    Button("Show 10000h Milestone 🐐") {
                        milestoneCelebrationManager.currentMilestone = .tenThousandHours
                    }
                    Divider()
                    Button("Show Launch on Login Banner") {
                        launchOnLoginReminderManager.shouldShowReminder = true
                    }
                    Button("Show Low Storage Banner") {
                        viewModel.showDebugStorageHealthBanner(
                            severity: .warning,
                            availableGB: 4.25,
                            shouldStop: false
                        )
                    }
                    Button("Show Critical Storage Banner") {
                        viewModel.showDebugStorageHealthBanner(
                            severity: .critical,
                            availableGB: 1.10,
                            shouldStop: false
                        )
                    }
                    Button("Show Storage Stop Banner") {
                        viewModel.showDebugStorageHealthBanner(
                            severity: .critical,
                            availableGB: 0.28,
                            shouldStop: true
                        )
                    }
                    Button("Show OCR Degraded Banner") {
                        viewModel.showDebugOCRDegradedBanner(requiresRelaunch: false)
                    }
                    Button("Show OCR Degraded Banner (Needs Relaunch)") {
                        viewModel.showDebugOCRDegradedBanner(requiresRelaunch: true)
                    }
                    Divider()
                    if let debugLaunchOnboarding {
                        Button("Relaunch Onboarding") {
                            debugLaunchOnboarding()
                        }
                        Divider()
                    }
                    Menu("Set Color Theme") {
                        Button("Blue") {
                            MilestoneCelebrationManager.setDebugThemeOverride(.blue)
                        }
                        Button("Gold") {
                            MilestoneCelebrationManager.setDebugThemeOverride(.gold)
                        }
                        Button("Purple") {
                            MilestoneCelebrationManager.setDebugThemeOverride(.purple)
                        }
                        Divider()
                        Button("Reset to Saved Theme") {
                            MilestoneCelebrationManager.setDebugThemeOverride(nil)
                        }
                    }
                    Divider()
                    Button("Trigger Crash (SIGABRT)") {
                        triggerDebugCrash()
                    }
                    Button("Trigger Forced Termination (SIGKILL)") {
                        triggerDebugForcedTermination()
                    }
                    Button("Trigger Watchdog Hang (15s)") {
                        triggerDebugWatchdogHang()
                    }
                    Button("Interrupt Capture") {
                        triggerDebugCaptureInterruption()
                    }
                    .disabled(!viewModel.isRecording)
                    Button("Interrupt Encoding") {
                        triggerDebugEncodingInterruption()
                    }
                    .disabled(!viewModel.isRecording)
                } label: {
                    HStack(spacing: 6) {
                        RetraceSymbol("ant.fill", size: 12)
                        Text("Debug")
                    }
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceWarningText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                #endif
            }

            Spacer()
        }
        .padding(.vertical, 12)
    }

    // MARK: - Formatting Helpers

    private func formatTotalTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private func formatRecordedHoursSubtitle(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0 hours on Retrace" }

        let roundedHours = Int((seconds / 3600).rounded())
        let hours = max(0, roundedHours)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0

        let hoursText = formatter.string(from: NSNumber(value: hours))
            ?? String(hours)

        return "\(hoursText) \(hours == 1 ? "hour" : "hours") on Retrace"
    }

    private func formatScreenTimeFromDaily(_ data: [DailyDataPoint]) -> String {
        // Data is in milliseconds, sum and convert to hours/minutes
        let totalMs = data.reduce(0) { $0 + $1.value }
        let totalMinutes = Int(totalMs / 1000 / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private func triggerDebugWatchdogHang() {
        DashboardViewModel.recordDebugWatchdogHangTriggered(coordinator: coordinatorWrapper.coordinator)
        Log.warning("[DEBUG] Scheduling intentional main-thread hang to exercise watchdog auto-quit", category: .ui)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            // DEBUG-only: intentionally block the main thread long enough to trigger
            // the watchdog auto-quit/relaunch path and generate a watchdog report.
            Thread.sleep(forTimeInterval: 15)
        }
    }

    private func triggerDebugCrash() {
        DashboardViewModel.recordDebugCrashTriggered(coordinator: coordinatorWrapper.coordinator)
        Log.warning("[DEBUG] Scheduling intentional SIGABRT to exercise crash-report generation and crash recovery", category: .ui)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            Darwin.abort()
        }
    }

    private func triggerDebugForcedTermination() {
        DashboardViewModel.recordDebugForcedTerminationTriggered(coordinator: coordinatorWrapper.coordinator)
        Log.warning("[DEBUG] Scheduling intentional SIGKILL to exercise forced-termination recovery without crash diagnostics", category: .ui)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            Darwin.kill(getpid(), SIGKILL)
        }
    }

    #if DEBUG
    private func triggerDebugCaptureInterruption() {
        DashboardViewModel.recordDebugCaptureInterruptionTriggered(
            coordinator: coordinatorWrapper.coordinator
        )
        Log.warning("[DEBUG] Interrupting capture underneath the coordinator to exercise unexpected-stop detection", category: .ui)

        Task {
            await coordinatorWrapper.coordinator.debugInterruptCapturePipeline()
        }
    }

    private func triggerDebugEncodingInterruption() {
        DashboardViewModel.recordDebugEncodingInterruptionTriggered(
            coordinator: coordinatorWrapper.coordinator
        )
        Log.warning("[DEBUG] Arming writer interruption for the next frame append to exercise unexpected-stop detection", category: .ui)

        Task {
            await coordinatorWrapper.coordinator.debugInterruptEncodingPipeline()
        }
    }
    #endif

    private func presentFeedbackSheet(launchContext: FeedbackLaunchContext? = nil) {
        Log.info(
            "[FeedbackSheet] dashboard presentFeedbackSheet source=\(launchContext?.source.rawValue ?? FeedbackLaunchContext.Source.manual.rawValue) " +
            "showFeedbackSheet(before)=\(showFeedbackSheet)",
            category: .ui
        )
        feedbackLaunchContext = launchContext
        feedbackPresentationID = UUID()
        if launchContext?.source == .crashBanner {
            viewModel.recordRecentCrashReportFeedbackOpened()
        } else if launchContext?.source == .walFailureCrashBanner {
            viewModel.recordRecentWALFailureCrashFeedbackOpened()
        } else if launchContext == nil {
            DashboardViewModel.recordHelpOpened(
                coordinator: coordinatorWrapper.coordinator,
                source: "dashboard_footer"
            )
        }
        showFeedbackSheet = true
        Log.info(
            "[FeedbackSheet] dashboard presentFeedbackSheet showFeedbackSheet(after)=\(showFeedbackSheet) " +
            "feedbackPresentationID=\(feedbackPresentationID)",
            category: .ui
        )
    }

}

// MARK: - Preview

private struct UnexpectedRecordingStopBanner: View {
    let state: UnexpectedRecordingStopState
    let onSubmitBugReport: () -> Void
    let onDismiss: () -> Void

    private var messageText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Recording stopped unexpectedly at \(formatter.string(from: state.stoppedAt)). Please submit a bug report."
    }

    var body: some View {
        HStack(spacing: 10) {
            RetraceSymbol("record.circle", size: 17, weight: .semibold)
                .foregroundColor(.retraceWarningText)

            Text(messageText)
                .font(.retraceCaption)
                .foregroundColor(.retraceInk)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button("Submit Bug Report", action: onSubmitBugReport)
                    .buttonStyle(RetraceButtonStyle(.secondary, size: .sm))
            }

            Button(action: onDismiss) {
                RetraceSymbol("xmark.circle.fill", size: 17, weight: .semibold)
                    .foregroundColor(.retraceInk2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.retraceWarningBg)
        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
    }
}

private struct CrashReportBanner: View {
    let report: DashboardCrashReportSummary
    let onSubmitBugReport: () -> Void
    let onDetails: () -> Void
    let onDismiss: () -> Void

    private var messageText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let timestamp = formatter.string(from: report.capturedAt)
        switch report.source {
        case .watchdogAutoQuit:
            return "Retrace auto-quit after a recent freeze at \(timestamp). Please submit a bug report."
        case .macOSDiagnosticReport:
            return "macOS saved a recent Retrace crash report at \(timestamp). Please submit a bug report."
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            RetraceSymbol("exclamationmark.arrow.trianglehead.2.clockwise.rotate.90", size: 17, weight: .semibold)
                .foregroundColor(.retraceWarningText)

            Text(messageText)
                .font(.retraceCaption)
                .foregroundColor(.retraceInk)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button("Details", action: onDetails)
                    .buttonStyle(RetraceButtonStyle(.ghost, size: .sm))

                Button("Submit Bug Report", action: onSubmitBugReport)
                    .buttonStyle(RetraceButtonStyle(.secondary, size: .sm))
            }

            Button(action: onDismiss) {
                RetraceSymbol("xmark.circle.fill", size: 17, weight: .semibold)
                    .foregroundColor(.retraceInk2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.retraceWarningBg)
        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
    }
}

private struct CrashRecoveryStatusBanner: View {
    let state: CrashRecoveryStatusBannerState
    let isRetrying: Bool
    let onOpenSettings: (() -> Void)?
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RetraceSymbol("arrow.trianglehead.2.clockwise.rotate.90.circle.fill", size: 17, weight: .semibold)
                .foregroundColor(.retraceWarningText)

            Text(state.messageText)
                .font(.retraceCaption)
                .foregroundColor(.retraceInk)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                if let onOpenSettings {
                    Button("Open Settings", action: onOpenSettings)
                        .buttonStyle(RetraceButtonStyle(.secondary, size: .sm))
                }

                Button(action: onRetry) {
                    HStack(spacing: 6) {
                        if isRetrying {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 10, height: 10)
                        }
                        Text(isRetrying ? "Retrying…" : "Retry")
                    }
                }
                    .buttonStyle(RetraceButtonStyle(.secondary, size: .sm))
                    .disabled(isRetrying)
            }

            Button(action: onDismiss) {
                RetraceSymbol("xmark.circle.fill", size: 17, weight: .semibold)
                    .foregroundColor(.retraceInk2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.retraceWarningBg)
        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
    }
}

private struct WALFailureCrashBanner: View {
    let report: WALFailureCrashReportSummary
    let onSubmitBugReport: () -> Void
    let onDetails: () -> Void
    let onDismiss: () -> Void

    private var messageText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Retrace couldn't complete recovery at \(formatter.string(from: report.capturedAt)). New recordings may fail until storage is repaired."
    }

    var body: some View {
        HStack(spacing: 10) {
            RetraceSymbol("externaldrive.badge.exclamationmark", size: 17, weight: .semibold)
                .foregroundColor(.retraceWarningText)

            Text(messageText)
                .font(.retraceCaption)
                .foregroundColor(.retraceInk)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button("Details", action: onDetails)
                    .buttonStyle(RetraceButtonStyle(.ghost, size: .sm))

                Button("Submit Bug Report", action: onSubmitBugReport)
                    .buttonStyle(RetraceButtonStyle(.secondary, size: .sm))
            }

            Button(action: onDismiss) {
                RetraceSymbol("xmark.circle.fill", size: 17, weight: .semibold)
                    .foregroundColor(.retraceInk2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.retraceWarningBg)
        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
    }
}

private struct StorageHealthBanner: View {
    let state: StorageHealthBannerState
    let onDismiss: () -> Void

    private var accentColor: Color {
        state.shouldStop ? .retraceCritical : .retraceWarningText
    }

    var body: some View {
        HStack(spacing: 10) {
            RetraceSymbol(state.shouldStop ? "externaldrive.fill.badge.xmark" : "externaldrive.badge.exclamationmark", size: 17, weight: .semibold)
                .foregroundColor(accentColor)

            Text(state.messageText)
                .font(.retraceCaption)
                .foregroundColor(.retraceInk)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            Button(action: onDismiss) {
                RetraceSymbol("xmark.circle.fill", size: 17, weight: .semibold)
                    .foregroundColor(.retraceInk2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(state.shouldStop ? Color.retraceCriticalBg : Color.retraceWarningBg)
        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
    }
}

// MARK: - OCR Degraded Banner

private struct OCRDegradedBanner: View {
    let restartInFlight: Bool
    let likelyRequiresRelaunch: Bool
    let onRestart: () -> Void
    let onRelaunch: () -> Void
    /// Primary only when no higher-urgency (permission) banner is showing.
    var isPrimary: Bool = true

    private var messageText: String {
        if restartInFlight {
            return "Restarting OCR…"
        }
        if likelyRequiresRelaunch {
            return "OCR is still stuck after restarting — text capture won't recover until the app is relaunched."
        }
        return "OCR has stopped responding (repeated hangs in the system text-recognition engine). Screenshots keep capturing, but text search won't be up to date until this recovers."
    }

    var body: some View {
        HStack(spacing: 10) {
            RetraceSymbol("text.viewfinder", size: 17, weight: .semibold)
                .foregroundColor(.retraceWarningText)

            Text(messageText)
                .font(.retraceCaption)
                .foregroundColor(.retraceInk)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            if restartInFlight {
                ProgressView()
                    .scaleEffect(0.6)
            } else if likelyRequiresRelaunch {
                Button("Relaunch App", action: onRelaunch)
                    .buttonStyle(RetraceButtonStyle(isPrimary ? .primary : .secondary, size: .sm))
            } else {
                Button("Restart OCR", action: onRestart)
                    .buttonStyle(RetraceButtonStyle(isPrimary ? .primary : .secondary, size: .sm))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.retraceWarningBg)
        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
    }
}

// MARK: - Scroll Affordance

/// A subtle fade (functional scroll-edge mask) at the bottom of a container that suggests scrollable content continues
private struct ScrollAffordance: View {
    var height: CGFloat = 24
    var color: Color = .retracePage

    var body: some View {
        VStack {
            Spacer()
            LinearGradient(
                colors: [
                    color.opacity(0),
                    color.opacity(0.4),
                    color.opacity(0.6)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Logo Triangle Shape

/// Triangle shape pointing right (like a play button) for the Retrace logo
private struct LogoTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Points: left-top, left-bottom, right-center
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Monitor Button (isolated to prevent parent re-renders)

/// Extracted to its own view so animation state changes don't cause DashboardView to re-render
private struct MonitorButton: View {
    let isProcessing: Bool
    let tooltipText: String

    @State private var heartbeatScale: CGFloat = 1.0
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            NotificationCenter.default.post(name: .openSystemMonitor, object: nil)
        }) {
            ZStack {
                RetraceSymbol("waveform.path.ecg", size: 13.5)
                    .foregroundColor(isProcessing ? .retraceGood : .retraceInk2)
                    .scaleEffect(isProcessing ? heartbeatScale : 1.0)
            }
            .padding(10)
            .background(Color.retraceSurface)
            .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .stroke(Color.retraceBorderStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open system monitor")
        .contentShape(Rectangle())
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .compactTopTooltip(tooltipText, isVisible: $isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .task(id: isProcessing) {
            // Heartbeat animation - quick expand then contract like a health monitor
            while !Task.isCancelled {
                if isProcessing {
                    // Beat 1: quick expand
                    withAnimation(.easeOut(duration: 0.1)) {
                        heartbeatScale = 1.25
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(100_000_000)), clock: .continuous)

                    // Contract back
                    withAnimation(.easeIn(duration: 0.15)) {
                        heartbeatScale = 1.05
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(150_000_000)), clock: .continuous)

                    // Beat 2: smaller secondary beat
                    withAnimation(.easeOut(duration: 0.08)) {
                        heartbeatScale = 1.15
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(80_000_000)), clock: .continuous)

                    // Contract and rest
                    withAnimation(.easeIn(duration: 0.2)) {
                        heartbeatScale = 1.05
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(600_000_000)), clock: .continuous)
                } else {
                    heartbeatScale = 1.0
                    try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous)
                }
            }
        }
    }
}

// MARK: - Compact Tooltip

private struct CompactTopTooltip: ViewModifier {
    let text: String
    @Binding var isVisible: Bool

    private var isMultiline: Bool {
        text.contains("\n")
    }

    private var verticalOffset: CGFloat {
        isMultiline ? -34 : -26
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isVisible {
                    Text(text)
                        .font(RetraceFont.font(size: 10, weight: .semibold))
                        .foregroundColor(.retracePage)
                        .lineLimit(isMultiline ? 2 : 1)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, isMultiline ? 5 : 3)
                        .background(
                            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                                .fill(Color.retraceInk)
                        )
                        .offset(y: verticalOffset)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}

private extension View {
    func compactTopTooltip(_ text: String, isVisible: Binding<Bool>) -> some View {
        modifier(CompactTopTooltip(text: text, isVisible: isVisible))
    }
}

#if DEBUG
struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        let launchOnLoginManager = LaunchOnLoginReminderManager(coordinator: coordinator)
        let milestoneManager = MilestoneCelebrationManager(coordinator: coordinator)

        DashboardView(
            viewModel: DashboardViewModel(coordinator: coordinator),
            coordinator: coordinator,
            launchOnLoginReminderManager: launchOnLoginManager,
            milestoneCelebrationManager: milestoneManager
        )
        .frame(width: 1200, height: 900)
    }
}
#endif
