import SwiftUI
import Shared
import AppKit
import App
import Database
import Carbon.HIToolbox
import ScreenCaptureKit
import SQLCipher
import ServiceManagement
import Darwin
import Carbon
import UniformTypeIdentifiers

extension SettingsView {
    var generalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            updatesCard
            keyboardShortcutsCard
            startupCard
            appearanceCard
        }
    }

    // MARK: - General Cards (extracted for search)

    @ViewBuilder
    var keyboardShortcutsCard: some View {
        ModernSettingsCard(title: "Keyboard Shortcuts (Global)", icon: "command") {
            VStack(spacing: 12) {
                settingsShortcutRecorderRow(
                    label: "Open Timeline",
                    kind: .timeline,
                    shortcut: $timelineShortcut,
                    isRecording: $isRecordingTimelineShortcut,
                    otherShortcuts: [dashboardShortcut, recordingShortcut, systemMonitorShortcut, commentShortcut]
                )

                Divider().overlay(Color.retraceBorder)

                settingsShortcutRecorderRow(
                    label: "Open Dashboard",
                    kind: .dashboard,
                    shortcut: $dashboardShortcut,
                    isRecording: $isRecordingDashboardShortcut,
                    otherShortcuts: [timelineShortcut, recordingShortcut, systemMonitorShortcut, commentShortcut]
                )

                Divider().overlay(Color.retraceBorder)

                settingsShortcutRecorderRow(
                    label: "Toggle Recording",
                    kind: .recording,
                    shortcut: $recordingShortcut,
                    isRecording: $isRecordingRecordingShortcut,
                    otherShortcuts: [timelineShortcut, dashboardShortcut, systemMonitorShortcut, commentShortcut]
                )

                Divider().overlay(Color.retraceBorder)

                settingsShortcutRecorderRow(
                    label: "System Monitor",
                    kind: .systemMonitor,
                    shortcut: $systemMonitorShortcut,
                    isRecording: $isRecordingSystemMonitorShortcut,
                    otherShortcuts: [timelineShortcut, dashboardShortcut, recordingShortcut, commentShortcut]
                )

                Divider().overlay(Color.retraceBorder)

                settingsShortcutRecorderRow(
                    label: "Quick Comment",
                    kind: .comment,
                    shortcut: $commentShortcut,
                    isRecording: $isRecordingCommentShortcut,
                    otherShortcuts: [timelineShortcut, dashboardShortcut, recordingShortcut, systemMonitorShortcut]
                )

                if let error = shortcutError {
                    HStack(spacing: 4) {
                        RetraceSymbol("exclamationmark.triangle.fill", size: 11)
                            .foregroundColor(.retraceWarning)
                        Text(error)
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceWarning)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Cancel recording if user clicks outside
            if isRecordingTimelineShortcut || isRecordingDashboardShortcut || isRecordingRecordingShortcut || isRecordingSystemMonitorShortcut || isRecordingCommentShortcut {
                isRecordingTimelineShortcut = false
                isRecordingDashboardShortcut = false
                isRecordingRecordingShortcut = false
                isRecordingSystemMonitorShortcut = false
                isRecordingCommentShortcut = false
                recordingTimeoutTask?.cancel()
            }
        }
        .task {
            // Load saved shortcuts on appear
            await loadSavedShortcuts()
        }
    }

    @ViewBuilder
    var updatesCard: some View {
        ModernSettingsCard(title: "Updates", icon: "arrow.down.circle") {
            // Current version display
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Version")
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)
                    Group {
                        if let url = BuildInfo.commitURL {
                            Text(BuildInfo.fullVersion)
                                .onTapGesture { NSWorkspace.shared.open(url) }
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                }
                        } else {
                            Text(BuildInfo.fullVersion)
                        }
                    }
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)
                    if BuildInfo.isDevBuild && BuildInfo.buildDate != "unknown" {
                        Text("Built \(BuildInfo.buildDate)")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                    }
                }
                Spacer()
            }

            Divider().overlay(Color.retraceBorder)
                .padding(.vertical, 4)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check for Updates")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retracePrimary)

                    if let lastCheck = UpdaterManager.shared.lastUpdateCheckDate {
                        Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                    } else {
                        Text("Automatically checks for updates")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                    }
                }

                Spacer()

                ModernButton(
                    title: UpdaterManager.shared.isCheckingForUpdates ? "Checking..." : "Check Now",
                    icon: "arrow.clockwise",
                    style: .secondary
                ) {
                    UpdaterManager.shared.checkForUpdates()
                }
                .disabled(UpdaterManager.shared.isCheckingForUpdates || !UpdaterManager.shared.canCheckForUpdates)
            }

            ModernToggleRow(
                title: "Automatically Check for Updates",
                subtitle: "Check for new updates in the background",
                isOn: $updaterManager.automaticUpdateChecksEnabled
            )

            ModernToggleRow(
                title: "Automatically Download and Install Updates",
                subtitle: "Download and install updates in the background",
                isOn: $updaterManager.automaticallyDownloadsUpdatesEnabled
            )
        }
    }

    @ViewBuilder
    var startupCard: some View {
        ModernSettingsCard(title: "Startup", icon: "power") {
            ModernToggleRow(
                title: "Launch at Login",
                subtitle: "Start Retrace automatically when you log in",
                isOn: $launchAtLogin
            )
            .onChange(of: launchAtLogin) { newValue in
                setLaunchAtLogin(enabled: newValue)
            }

            ModernToggleRow(
                title: "Show Dock Icon",
                subtitle: "Show Retrace in the Dock and app switcher",
                isOn: $showDockIcon
            )
            .onChange(of: showDockIcon) { newValue in
                setDockIconVisibility(visible: newValue)
            }

            ModernToggleRow(
                title: "Show Menu Bar Icon",
                subtitle: "Quick access from your menu bar",
                isOn: $showMenuBarIcon
            )
            .onChange(of: showMenuBarIcon) { newValue in
                setMenuBarIconVisibility(visible: newValue)
            }
        }
    }

    @ViewBuilder
    var appearanceCard: some View {
        ModernSettingsCard(title: "Appearance", icon: "paintbrush") {
            VStack(alignment: .leading, spacing: 24) {
                // Theme Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Theme")
                                .font(.retraceCallout)
                                .foregroundColor(.retraceInk)

                            Text("Auto follows your Mac's appearance")
                                .font(.retraceMeta)
                                .foregroundColor(.retraceMuted)
                        }

                        Spacer()
                    }

                    ModernSegmentedPicker(
                        selection: $theme,
                        options: ThemePreference.allCases
                    ) { option in
                        Text(option.rawValue)
                    }
                    .onChange(of: theme) { newTheme in
                        applyTheme(newTheme)
                        DashboardViewModel.recordDeveloperSettingToggle(
                            coordinator: coordinatorWrapper.coordinator,
                            source: "settings.appearance",
                            settingKey: "theme",
                            isEnabled: newTheme != .auto
                        )
                    }
                }

                Divider().overlay(Color.retraceBorder)

                // Font Style Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Font Style")
                                .font(.retraceCalloutMedium)
                                .foregroundColor(.retracePrimary)

                            Text("Choose your preferred font style")
                                .font(.retraceMeta)
                                .foregroundColor(.retraceMuted)
                        }

                        Spacer()

                        // Reset to default button
                        if fontStyle != SettingsDefaults.fontStyle {
                            Button(action: {
                                fontStyle = SettingsDefaults.fontStyle
                                RetraceFont.currentStyle = SettingsDefaults.fontStyle
                            }) {
                                HStack(spacing: 4) {
                                    RetraceSymbol("arrow.counterclockwise", size: 10)
                                    Text("Reset to Default")
                                        .font(.retraceCaption2)
                                }
                                .foregroundColor(.retraceInk2)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    FontStylePicker(selection: $fontStyle)
                        .onChange(of: fontStyle) { newStyle in
                            RetraceFont.currentStyle = newStyle
                        }
                }

                Divider().overlay(Color.retraceBorder)

                ModernToggleRow(
                    title: "Timeline colored button borders",
                    subtitle: "Show accent-colored borders on timeline control buttons",
                    isOn: $timelineColoredBorders
                )

                Divider().overlay(Color.retraceBorder)

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Dashboard app usage layout")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)
                        Spacer()
                        RetraceBadge(dashboardAppUsageViewModeSelection.displayName, tone: .accent)
                    }

                    ModernSegmentedPicker(
                        selection: dashboardAppUsageViewModeBinding,
                        options: DashboardAppUsageViewModeSetting.allCases
                    ) { option in
                        Text(option.shortLabel)
                    }

                    HStack {
                        Text("Choose how App Usage appears in Dashboard.")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)

                        Spacer()

                        if dashboardAppUsageViewMode != SettingsDefaults.dashboardAppUsageViewMode {
                            Button(action: {
                                dashboardAppUsageViewMode = SettingsDefaults.dashboardAppUsageViewMode
                                DashboardViewModel.recordDeveloperSettingToggle(
                                    coordinator: coordinatorWrapper.coordinator,
                                    source: "settings.appearance",
                                    settingKey: "dashboardAppUsageViewMode",
                                    isEnabled: false
                                )
                            }) {
                                HStack(spacing: 4) {
                                    RetraceSymbol("arrow.counterclockwise", size: 10)
                                    Text("Reset to Default")
                                        .font(.retraceCaption2)
                                }
                                .foregroundColor(.retraceInk2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider().overlay(Color.retraceBorder)

                // Scrubbing Animation Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Scrubbing animation")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)
                        Spacer()
                        RetraceBadge(scrubbingAnimationDisplayText, tone: .accent)
                    }

                    ModernSlider(value: $scrubbingAnimationDuration, range: 0...0.20, step: 0.01)
                        .onChange(of: scrubbingAnimationDuration) { _ in
                            showScrubbingAnimationUpdateFeedback()
                        }

                    HStack {
                        Text(scrubbingAnimationDescriptionText)
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)

                        Spacer()

                        if scrubbingAnimationDuration != SettingsDefaults.scrubbingAnimationDuration {
                            Button(action: {
                                scrubbingAnimationDuration = SettingsDefaults.scrubbingAnimationDuration
                                showScrubbingAnimationUpdateFeedback()
                            }) {
                                HStack(spacing: 4) {
                                    RetraceSymbol("arrow.counterclockwise", size: 10)
                                    Text("Reset to Default")
                                        .font(.retraceCaption2)
                                }
                                .foregroundColor(.retraceInk2)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                }

                Divider().overlay(Color.retraceBorder)

                // Scroll Sensitivity Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Scroll sensitivity")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)
                        Spacer()
                        RetraceBadge(scrollSensitivityDisplayText, tone: .accent)
                    }

                    ModernSlider(value: $scrollSensitivity, range: 0.1...1.0, step: 0.05)

                    HStack {
                        Text(scrollSensitivityDescriptionText)
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)

                        Spacer()

                        if scrollSensitivity != SettingsDefaults.scrollSensitivity {
                            Button(action: {
                                scrollSensitivity = SettingsDefaults.scrollSensitivity
                            }) {
                                HStack(spacing: 4) {
                                    RetraceSymbol("arrow.counterclockwise", size: 10)
                                    Text("Reset to Default")
                                        .font(.retraceCaption2)
                                }
                                .foregroundColor(.retraceInk2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider().overlay(Color.retraceBorder)

                // Scroll Orientation Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Timeline scroll orientation")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)
                        Spacer()
                        RetraceBadge(timelineScrollOrientation.displayName, tone: .accent)
                    }

                    ModernSegmentedPicker(
                        selection: $timelineScrollOrientation,
                        options: TimelineScrollOrientation.allCases
                    ) { option in
                        Text(option.shortLabel)
                    }

                    HStack {
                        Text(timelineScrollOrientation.description)
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)

                        Spacer()

                        if timelineScrollOrientation != SettingsDefaults.timelineScrollOrientation {
                            Button(action: {
                                timelineScrollOrientation = SettingsDefaults.timelineScrollOrientation
                            }) {
                                HStack(spacing: 4) {
                                    RetraceSymbol("arrow.counterclockwise", size: 10)
                                    Text("Reset to Default")
                                        .font(.retraceCaption2)
                                }
                                .foregroundColor(.retraceInk2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .id(Self.timelineScrollOrientationAnchorID)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                        .fill(
                            shellViewModel.isTimelineScrollOrientationHighlighted
                                ? Color.retraceAccentWash
                                : Color.clear
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                        .stroke(
                            Color.retraceAccent.opacity(shellViewModel.isTimelineScrollOrientationHighlighted ? 1 : 0),
                            lineWidth: shellViewModel.isTimelineScrollOrientationHighlighted ? 2 : 0
                        )
                )
                .animation(.easeInOut(duration: 0.2), value: shellViewModel.isTimelineScrollOrientationHighlighted)
            }
        }
    }

    // MARK: - Shortcut Recorder Row

    func settingsShortcutRecorderRow(
        label: String,
        kind: ManagedShortcutKind,
        shortcut: Binding<SettingsShortcutKey>,
        isRecording: Binding<Bool>,
        otherShortcuts: [SettingsShortcutKey]
    ) -> some View {
        let defaultShortcut = Self.defaultShortcut(for: kind)
        let isUsingDefaultShortcut = Self.usesDefaultShortcut(shortcut.wrappedValue, for: kind)
        let canClearShortcut = Self.canClearShortcut(shortcut.wrappedValue)

        return HStack {
            Text(label)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retracePrimary)

            Spacer()

            // Shortcut display/recorder button
            Button(action: {
                // Cancel any other recording first
                isRecordingTimelineShortcut = false
                isRecordingDashboardShortcut = false
                isRecordingRecordingShortcut = false
                isRecordingSystemMonitorShortcut = false
                isRecordingCommentShortcut = false
                shortcutError = nil
                recordingTimeoutTask?.cancel()

                // Then start this one
                isRecording.wrappedValue = true

                // Start 10 second timeout
                recordingTimeoutTask = Task {
                    try? await Task.sleep(for: .nanoseconds(Int64(10_000_000_000)), clock: .continuous)
                    if !Task.isCancelled {
                        await MainActor.run {
                            isRecording.wrappedValue = false
                        }
                    }
                }
            }) {
                Group {
                    if isRecording.wrappedValue {
                        Text("Press keys...")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceInk)
                            .frame(minWidth: 100, minHeight: 24)
                    } else if shortcut.wrappedValue.isEmpty {
                        Text("None")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceInk2)
                            .frame(minWidth: 60, minHeight: 24)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(shortcut.wrappedValue.modifierSymbols, id: \.self) { symbol in
                                Text(symbol)
                                    .font(.retraceMonoSmall)
                                    .foregroundColor(.retraceInk)
                                    .frame(width: 22, height: 22)
                                    .background(Color.retraceSurfaceSunken)
                                    .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                            }

                            if !shortcut.wrappedValue.modifierSymbols.isEmpty {
                                Text("+")
                                    .font(.retraceMeta)
                                    .foregroundColor(.retraceInk2)
                            }

                            Text(shortcut.wrappedValue.key)
                                .font(RetraceFont.mono(size: 12, weight: .medium))
                                .foregroundColor(.retraceInk)
                                .frame(minWidth: 28, minHeight: 22)
                                .padding(.horizontal, 6)
                                .background(Color.retraceSurfaceSunken)
                                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isRecording.wrappedValue ? Color.retraceAccentWash : Color.retraceSurface)
                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .stroke(isRecording.wrappedValue ? Color.retraceAccent : Color.retraceBorderStrong, lineWidth: isRecording.wrappedValue ? 2 : 1)
                )
                .retraceFocusRing(cornerRadius: .radiusSm)
            }
            .buttonStyle(.plain)
            .background(
                SettingsShortcutCaptureField(
                    isRecording: isRecording,
                    capturedShortcut: shortcut,
                    otherShortcuts: otherShortcuts,
                    onDuplicateAttempt: {
                        shortcutError = "This shortcut is already in use"
                    },
                    onShortcutCaptured: {
                        persistShortcutChange(kind)
                    }
                )
                .frame(width: 0, height: 0)
            )

            if !isRecording.wrappedValue {
                HStack(spacing: 6) {
                    shortcutControlButton(
                        systemName: "arrow.counterclockwise",
                        isEnabled: !isUsingDefaultShortcut,
                        helpText: isUsingDefaultShortcut ? "Already using default shortcut" : "Reset to default shortcut"
                    ) {
                        shortcut.wrappedValue = defaultShortcut
                        persistShortcutChange(kind)
                    }

                    shortcutControlButton(
                        systemName: "xmark",
                        isEnabled: canClearShortcut,
                        helpText: canClearShortcut ? "Clear shortcut" : "Shortcut is already cleared"
                    ) {
                        shortcut.wrappedValue = .empty
                        persistShortcutChange(kind)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func shortcutControlButton(
        systemName: String,
        isEnabled: Bool,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            RetraceSymbol(systemName, size: 10, weight: .semibold)
                .foregroundColor(isEnabled ? .retraceInk2 : .retraceMuted)
                .frame(width: 18, height: 18)
                .background(isEnabled ? Color.retraceSurfaceSunken : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    func loadSavedShortcuts() async {
        let timeline = await onboardingManager.timelineShortcut
        let dashboard = await onboardingManager.dashboardShortcut
        let recording = await onboardingManager.recordingShortcut
        let systemMonitor = await onboardingManager.systemMonitorShortcut
        let comment = await onboardingManager.commentShortcut

        let timelineValue = SettingsShortcutKey(from: timeline)
        let dashboardValue = SettingsShortcutKey(from: dashboard)
        let recordingValue = SettingsShortcutKey(from: recording)
        let systemMonitorValue = SettingsShortcutKey(from: systemMonitor)
        let commentValue = SettingsShortcutKey(from: comment)

        timelineShortcut = timelineValue
        dashboardShortcut = dashboardValue
        recordingShortcut = recordingValue
        systemMonitorShortcut = systemMonitorValue
        commentShortcut = commentValue
    }

    func saveShortcut(_ kind: ManagedShortcutKind) async {
        switch kind {
        case .timeline:
            await onboardingManager.setTimelineShortcut(timelineShortcut.toConfig)
        case .dashboard:
            await onboardingManager.setDashboardShortcut(dashboardShortcut.toConfig)
        case .recording:
            await onboardingManager.setRecordingShortcut(recordingShortcut.toConfig)
        case .systemMonitor:
            await onboardingManager.setSystemMonitorShortcut(systemMonitorShortcut.toConfig)
        case .comment:
            await onboardingManager.setCommentShortcut(commentShortcut.toConfig)
        }

        recordShortcutDefaultStateMetric(for: kind)
        MenuBarManager.shared?.reloadShortcuts()
    }

    func saveAllShortcuts() async {
        await onboardingManager.setTimelineShortcut(timelineShortcut.toConfig)
        await onboardingManager.setDashboardShortcut(dashboardShortcut.toConfig)
        await onboardingManager.setRecordingShortcut(recordingShortcut.toConfig)
        await onboardingManager.setSystemMonitorShortcut(systemMonitorShortcut.toConfig)
        await onboardingManager.setCommentShortcut(commentShortcut.toConfig)
        MenuBarManager.shared?.reloadShortcuts()
    }

    // MARK: - Capture Settings
}
