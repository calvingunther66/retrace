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
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with separate back button
            HStack(spacing: 12) {
                // Back button - distinct and easy to click
                Button(action: {
                    NotificationCenter.default.post(name: .openDashboard, object: nil)
                }) {
                    RetraceSymbol("chevron.left", size: 12, weight: .semibold)
                        .foregroundColor(.retraceInk2)
                        .frame(width: 28, height: 28)
                        .background(Color.retraceSurface)
                        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                                .stroke(Color.retraceBorderStrong, lineWidth: 1)
                        )
                        .retraceFocusRing(cornerRadius: .radiusSm)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to dashboard")
                .contentShape(Rectangle())
                .keyboardShortcut("[", modifiers: .command)

                Text("Settings")
                    .font(.retraceTitle2)
                    .foregroundColor(.retraceInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)

            // Search button
            Button(action: {
                openSettingsSearch(source: "sidebar_button")
            }) {
                HStack(spacing: 8) {
                    RetraceSymbol("magnifyingglass", size: 12, label: "")
                        .foregroundColor(.retraceInk2)

                    Text("Search")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceInk2)
                        .lineLimit(1)

                    Spacer()

                    HStack(spacing: 2) {
                        Text("\u{2318}")
                            .font(RetraceFont.mono(size: 10, weight: .medium))
                        Text("K")
                            .font(RetraceFont.mono(size: 10, weight: .medium))
                    }
                    .foregroundColor(.retraceInk2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.retraceSurfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.retraceSurface)
                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .stroke(Color.retraceBorderStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Navigation items
            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarButton(tab: tab)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            // Version info
            VStack(spacing: 2) {
                Text("Retrace")
                    .font(.retraceMeta)
                    .foregroundColor(.retraceInk2)

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
                .font(.retraceMonoSmall)
                .foregroundColor(.retraceInk2)

                if let branch = BuildInfo.displayBranch {
                    Text(branch)
                        .font(RetraceFont.mono(size: 9))
                        .foregroundColor(.retraceInk2)
                }

                #if DEBUG
                Text("Debug Build")
                    .font(RetraceFont.mono(size: 9))
                    .foregroundColor(.retraceWarningText)
                #endif
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 20)
        }
        .background(Color.retraceSurfaceSunken)
    }

    func sidebarButton(tab: SettingsTab) -> some View {
        SettingsSidebarButton(
            tab: tab,
            isSelected: shellViewModel.selectedTab == tab,
            action: { shellViewModel.selectedTab = tab }
        )
    }

    // MARK: - Content

    @ViewBuilder
    var content: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Content header
                    contentHeader

                    // Settings content
                    VStack(alignment: .leading, spacing: 24) {
                        switch shellViewModel.selectedTab {
                        case .general:
                            generalSettings
                        case .capture:
                            captureSettings
                        case .storage:
                            storageSettings
                        case .privacy:
                            privacySettings
                        case .power:
                            powerSettings
                        case .tags:
                            tagManagementSettings
                        case .ai:
                            OpenRouterSettingsView()
                        case .advanced:
                            advancedSettings
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, shellViewModel.selectedTab == .capture ? 108 : 32)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if shellViewModel.selectedTab == .capture {
                    floatingStorageEstimateCard(
                        valueText: storageEstimateValueText,
                        deltaDirection: storageEstimateDeltaDirection
                    )
                        .padding(.trailing, 32)
                        .padding(.bottom, 18)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                synchronizeStorageEstimateTrackingIfNeeded()
                scrollToPendingTarget(using: proxy)
            }
            .onChange(of: shellViewModel.selectedTab) { _ in
                synchronizeStorageEstimateTrackingIfNeeded()
                scrollToPendingTarget(using: proxy)
            }
            .onChange(of: shellViewModel.pendingScrollTargetID) { _ in
                scrollToPendingTarget(using: proxy)
            }
            .onChange(of: storageEstimateRange) { newRange in
                guard shellViewModel.selectedTab == .capture else {
                    lastObservedStorageEstimateRange = newRange
                    storageEstimateDeltaDirection = nil
                    return
                }

                if let previousRange = lastObservedStorageEstimateRange {
                    storageEstimateDeltaDirection = Self.storageEstimateDeltaDirection(
                        previous: previousRange,
                        current: newRange
                    )
                }
                lastObservedStorageEstimateRange = newRange
            }
            .animation(.easeInOut(duration: 0.2), value: shellViewModel.selectedTab)
            .animation(.easeInOut(duration: 0.18), value: storageEstimateDeltaDirection)
        }
    }

    func synchronizeStorageEstimateTrackingIfNeeded() {
        guard shellViewModel.selectedTab == .capture else {
            storageEstimateDeltaDirection = nil
            return
        }

        lastObservedStorageEstimateRange = storageEstimateRange
        storageEstimateDeltaDirection = nil
    }

    func requestNavigation(to targetID: String) {
        switch targetID {
        case Self.pauseReminderIntervalTargetID:
            shellViewModel.selectedTab = .capture
        case Self.timelineScrollOrientationTargetID:
            shellViewModel.selectedTab = .general
        case Self.powerOCRCardTargetID:
            shellViewModel.selectedTab = .power
        case Self.powerOCRPriorityTargetID:
            shellViewModel.selectedTab = .power
        default:
            break
        }
        shellViewModel.pendingScrollTargetID = targetID
    }

    func postSelectedTabNotification(_ tab: SettingsTab) {
        NotificationCenter.default.post(
            name: .settingsSelectedTabDidChange,
            object: nil,
            userInfo: ["tab": tab.rawValue]
        )
    }

    func scrollToPendingTarget(using proxy: ScrollViewProxy) {
        guard let targetID = shellViewModel.pendingScrollTargetID,
              !shellViewModel.isScrollingToTarget else { return }

        // Ensure tab content is visible before scrolling to a row inside it.
        switch targetID {
        case Self.pauseReminderIntervalTargetID:
            guard shellViewModel.selectedTab == .capture else { return }
        case Self.timelineScrollOrientationTargetID:
            guard shellViewModel.selectedTab == .general else { return }
        case Self.powerOCRCardTargetID:
            guard shellViewModel.selectedTab == .power else { return }
        case Self.powerOCRPriorityTargetID:
            guard shellViewModel.selectedTab == .power else { return }
        default:
            shellViewModel.pendingScrollTargetID = nil
            return
        }

        let anchorID: String
        switch targetID {
        case Self.pauseReminderIntervalTargetID:
            anchorID = Self.pauseReminderCardAnchorID
        case Self.timelineScrollOrientationTargetID:
            anchorID = Self.timelineScrollOrientationAnchorID
        case Self.powerOCRCardTargetID:
            anchorID = Self.powerOCRCardAnchorID
        case Self.powerOCRPriorityTargetID:
            anchorID = Self.powerOCRPriorityAnchorID
        default:
            shellViewModel.pendingScrollTargetID = nil
            return
        }

        shellViewModel.isScrollingToTarget = true
        Task { @MainActor in
            // Wait one layout pass so the target row is in the tree.
            try? await Task.sleep(for: .nanoseconds(Int64(60_000_000)), clock: .continuous)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
            if targetID == Self.pauseReminderIntervalTargetID {
                try? await Task.sleep(for: .nanoseconds(Int64(140_000_000)), clock: .continuous)
                shellViewModel.triggerPauseReminderCardHighlight()
            }
            if targetID == Self.timelineScrollOrientationTargetID {
                try? await Task.sleep(for: .nanoseconds(Int64(140_000_000)), clock: .continuous)
                shellViewModel.triggerTimelineScrollOrientationHighlight()
            }
            if targetID == Self.powerOCRCardTargetID {
                try? await Task.sleep(for: .nanoseconds(Int64(140_000_000)), clock: .continuous)
                shellViewModel.triggerOCRCardHighlight()
            }
            if targetID == Self.powerOCRPriorityTargetID {
                try? await Task.sleep(for: .nanoseconds(Int64(140_000_000)), clock: .continuous)
                shellViewModel.triggerOCRPrioritySliderHighlight()
            }
            shellViewModel.pendingScrollTargetID = nil
            shellViewModel.isScrollingToTarget = false
        }
    }

    var contentHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.retraceAccentWash)
                        .frame(width: 44, height: 44)

                    RetraceSymbol(shellViewModel.selectedTab.icon, size: 17, weight: .semibold, label: "")
                        .foregroundColor(.retraceAccent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(shellViewModel.selectedTab.rawValue)
                        .font(.retraceTitle)
                        .foregroundColor(.retraceInk)

                    Text(shellViewModel.selectedTab.description)
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)
                }

                Spacer()

                // System Monitor button (only for Power tab)
                if shellViewModel.selectedTab == .power {
                    Button(action: {
                        NotificationCenter.default.post(name: .openSystemMonitor, object: nil)
                    }) {
                        HStack(spacing: 6) {
                            RetraceSymbol("waveform.path.ecg", size: 12, label: "")
                            Text("System Monitor")
                                .font(.retraceCaption2)
                        }
                    }
                    .buttonStyle(RetraceButtonStyle(.secondary, size: .sm))
                }

                // Reset section button (only for sections with resettable settings)
                if shellViewModel.selectedTab.resetAction(for: self) != nil {
                    Button(action: { shellViewModel.showingSectionResetConfirmation = true }) {
                        HStack(spacing: 6) {
                            RetraceSymbol("arrow.counterclockwise", size: 12, label: "")
                            Text("Reset to Defaults")
                                .font(.retraceCaption2)
                        }
                    }
                    .buttonStyle(RetraceButtonStyle(.secondary, size: .sm))
                    .alert("Reset \(shellViewModel.selectedTab.rawValue) Settings?", isPresented: $shellViewModel.showingSectionResetConfirmation) {
                        Button("Cancel", role: .cancel) {}
                        Button("Reset", role: .destructive) {
                            shellViewModel.selectedTab.resetAction(for: self)?()
                        }
                    } message: {
                        Text("This will reset all \(shellViewModel.selectedTab.rawValue.lowercased()) settings to their defaults.")
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 28)
    }

    // MARK: - General Settings
}


/// One sidebar row. Hover state is local `@State` on purpose: when it lived on the shared settings view
/// model, every enter/exit re-rendered all of `SettingsView`, which rebuilt the hover tracking areas under a
/// stationary cursor and made the highlight flash on/off in a loop.
private struct SettingsSidebarButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let _ = UIDiagnostics.render("SettingsSidebarButton.body")
        Button(action: action) {
            HStack(spacing: 12) {
                // Icon: clay when selected
                RetraceSymbol(tab.icon, size: 13.5, label: "")
                    .foregroundColor(isSelected ? .retraceAccent : .retraceInk2)
                    .frame(width: 32, height: 32)

                Text(tab.rawValue)
                    .font(isSelected ? .retraceCalloutBold : .retraceCallout)
                    .foregroundColor(isSelected ? .retraceInk : .retraceInk2)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // Fade opacity of fixed-colour fills. Animating a fill between `Color.clear` (transparent black)
            // and a light colour passes through a dark intermediate, which showed up as both the row being
            // left and the row being entered flashing dark before settling.
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                        .fill(Color.retraceSurfaceHover)
                        .opacity(isHovered && !isSelected ? 1 : 0)
                    RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                        .fill(Color.retraceAccentWash)
                        .opacity(isSelected ? 1 : 0)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                    .stroke(Color.retraceAccent, lineWidth: 1)
                    .opacity(isSelected ? 1 : 0)
            )
            .retraceFocusRing(cornerRadius: .radiusMd)
            .contentShape(RoundedRectangle(cornerRadius: .radiusMd, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if isHovered != hovering { isHovered = hovering }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

