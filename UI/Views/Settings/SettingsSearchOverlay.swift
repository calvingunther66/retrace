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
    @ViewBuilder
    func cardView(for entry: SettingsSearchEntry) -> some View {
        switch entry.id {
        case "general.shortcuts": keyboardShortcutsCard
        case "general.updates": updatesCard
        case "general.startup": startupCard
        case "general.appearance": appearanceCard
        case "capture.rate": captureRateCard
        case "capture.menuBarIcon": menuBarIconCard
        case "capture.compression": compressionCard
        case "capture.pauseReminder": pauseReminderCard
        case "capture.inPageURLs": inPageURLCollectionCard
        case "storage.rewindData": rewindDataCard
        case "storage.databaseLocations": databaseLocationsCard
        case "storage.retentionPolicy": retentionPolicyCard
        case "exportData.comingSoon": comingSoonCard
        case "privacy.excludedApps": appLevelRedactionCard
        case "privacy.frameRedaction": windowLevelRedactionCard
        case "privacy.phraseRedaction": phraseLevelRedactionCard
        case "privacy.quickDelete": quickDeleteCard
        case "privacy.permissions": permissionsCard
        case "power.ocrProcessing": ocrProcessingCard
        case "power.powerEfficiency": powerEfficiencyCard
        case "power.appFilter": appFilterCard
        case "tags.manageTags": manageTagsCard
        case "advanced.cache": cacheCard
        case "advanced.timeline": timelineCard
        case "advanced.developer": developerCard
        case "advanced.dangerZone": dangerZoneCard
        default: EmptyView()
        }
    }

    // MARK: - Settings Search Overlay

    @ViewBuilder
    var settingsSearchOverlay: some View {
        if shellViewModel.showSettingsSearch {
            ZStack {
                // Backdrop
                Color.retraceScrim
                    .ignoresSafeArea()
                    .onTapGesture { dismissSettingsSearch() }

                // Search panel
                VStack(spacing: 0) {
                    // Search bar
                    HStack(spacing: 12) {
                        RetraceSymbol("magnifyingglass", size: 18, label: "")
                            .foregroundColor(.retraceMuted)

                        SettingsSearchField(
                            text: $shellViewModel.settingsSearchQuery,
                            onEscape: { dismissSettingsSearch() }
                        )
                        .frame(height: 24)

                        Text("esc")
                            .font(RetraceFont.mono(size: 10, weight: .medium))
                            .foregroundColor(.retraceInk2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.retraceSurfaceSunken)
                            .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                    Divider().overlay(Color.retraceBorder)

                    // Results
                    let results = SettingsShellViewModel.searchResults(for: shellViewModel.settingsSearchQuery)

                    if shellViewModel.settingsSearchQuery.isEmpty {
                        VStack(spacing: 8) {
                            Text("Search settings...")
                                .font(.retraceCallout)
                                .foregroundColor(.retraceInk2)
                            Text("Type to find settings like \"OCR\", \"retention\", \"privacy\"")
                                .font(.retraceMeta)
                                .foregroundColor(.retraceMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else if results.isEmpty {
                        VStack(spacing: 8) {
                            RetraceSymbol("magnifyingglass", size: 32)
                                .foregroundColor(.retraceMuted)
                            Text("No settings found for \"\(shellViewModel.settingsSearchQuery)\"")
                                .font(.retraceCallout)
                                .foregroundColor(.retraceInk2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ScrollView(showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(results) { entry in
                                    VStack(alignment: .leading, spacing: 8) {
                                        // Breadcrumb
                                        HStack(spacing: 6) {
                                            RetraceSymbol(entry.tab.icon, size: 10, label: "")
                                                .foregroundColor(.retraceAccent)
                                            Text(entry.breadcrumb)
                                                .font(.retraceMeta)
                                                .foregroundColor(.retraceMuted)

                                            Spacer()

                                            // Navigate button
                                            Button(action: {
                                                dismissSettingsSearch()
                                                shellViewModel.selectedTab = entry.tab
                                            }) {
                                                HStack(spacing: 4) {
                                                    Text("Go to")
                                                        .font(.retraceTiny)
                                                    RetraceSymbol("arrow.right", size: 8, weight: .semibold, label: "")
                                                }
                                                .foregroundColor(.retraceAccent)
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        // Actual settings card with working controls
                                        cardView(for: entry)
                                    }
                                }
                            }
                            .padding(20)
                        }
                        .frame(maxHeight: 500)
                    }
                }
                .frame(width: 600)
                .background(
                    RoundedRectangle(cornerRadius: .radiusLg, style: .continuous)
                        .fill(Color.retracePage)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: .radiusLg, style: .continuous)
                        .stroke(Color.retraceBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: .radiusLg, style: .continuous))
                .retraceElevation(.lg)
            }
            .transition(.opacity)
            .onExitCommand { dismissSettingsSearch() }
        }
    }

    func dismissSettingsSearch() {
        withAnimation(.easeOut(duration: 0.15)) {
            shellViewModel.showSettingsSearch = false
        }
        shellViewModel.scheduleSettingsSearchReset()
    }

    func openSettingsSearch(source: String) {
        if !shellViewModel.showSettingsSearch {
            DashboardViewModel.recordSettingsSearchOpened(
                coordinator: coordinatorWrapper.coordinator,
                source: source
            )
        }

        shellViewModel.cancelSettingsSearchReset()
        withAnimation(.easeOut(duration: 0.15)) {
            shellViewModel.showSettingsSearch = true
        }
    }
}
