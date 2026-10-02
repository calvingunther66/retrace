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
    var inPageURLCollectionCard: some View {
        ModernSettingsCard(title: "In-Page URLs", icon: "link.badge.plus") {
            VStack(alignment: .leading, spacing: 16) {
                ModernToggleRow(
                    title: "Collect in-page URLs",
                    subtitle: "Collect visible links from browser pages using AppleScript automation.",
                    isOn: $collectInPageURLsExperimental,
                    badge: "Experimental"
                )
                .onChange(of: collectInPageURLsExperimental) { enabled in
                    recordInPageURLMetric(
                        type: .inPageURLCollectionToggle,
                        payload: ["enabled": enabled]
                    )
                    if enabled {
                        Task {
                            await checkPermissions()
                            await refreshInPageURLTargets()
                        }
                    } else {
                        inPageURLVerificationByBundleID = [:]
                        inPageURLVerificationBusyBundleIDs = []
                        inPageURLVerificationSummary = nil
                    }
                }

                if collectInPageURLsExperimental {
                    Divider().overlay(Color.retraceBorder)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Step 1: Grant automation access one app at a time")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)

                        if !hasAccessibilityPermission {
                            HStack(spacing: 8) {
                                RetraceSymbol("exclamationmark.triangle.fill", size: 12)
                                    .foregroundColor(.retraceWarning)
                                Text("Accessibility is required for stable browser/window context.")
                                    .font(.retraceMeta)
                                    .foregroundColor(.retraceMuted)
                            }

                            ModernPermissionRow(
                                label: "Accessibility",
                                status: .notDetermined,
                                enableAction: { requestAccessibilityPermission() },
                                openSettingsAction: { openAccessibilitySettings() }
                            )
                        }

                        if inPageURLTargets.isEmpty && unsupportedInPageURLTargets.isEmpty {
                            if isRefreshingInPageURLTargets {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Scanning installed Safari/Chromium browsers...")
                                        .font(.retraceMeta)
                                        .foregroundColor(.retraceMuted)
                                }
                            } else {
                                Text("No supported Safari/Chromium browsers found on this Mac.")
                                    .font(.retraceMeta)
                                    .foregroundColor(.retraceMuted)
                            }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(inPageURLTargets.enumerated()), id: \.element.bundleID) { index, target in
                                    inPageURLPermissionRow(target: target)
                                    if index < inPageURLTargets.count - 1 || !unsupportedInPageURLTargets.isEmpty {
                                        Divider().overlay(Color.retraceBorder)
                                    }
                                }
                                ForEach(Array(unsupportedInPageURLTargets.enumerated()), id: \.element.bundleID) { index, target in
                                    unsupportedInPageURLTargetRow(target: target)
                                    if index < unsupportedInPageURLTargets.count - 1 {
                                        Divider().overlay(Color.retraceBorder)
                                    }
                                }
                            }
                            .background(Color.retraceSurfaceSunken)
                            .overlay(
                                RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                                    .stroke(Color.retraceBorder, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: .radiusMd, style: .continuous))
                        }

                        HStack {
                            Spacer()
                            Button(action: {
                                Task { await refreshInPageURLTargets(force: true) }
                            }) {
                                HStack(spacing: 6) {
                                    if isRefreshingInPageURLTargets {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        RetraceSymbol("arrow.clockwise", size: 10)
                                    }
                                    Text(isRefreshingInPageURLTargets ? "Refreshing..." : "Refresh Browser List")
                                        .font(.retraceCaption2)
                                }
                                .foregroundColor(.retraceInk2)
                            }
                            .buttonStyle(.plain)
                            .disabled(isRefreshingInPageURLTargets)
                        }
                    }

                    Divider().overlay(Color.retraceBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Step 2: Enable JavaScript from Apple Events")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)
                        Text("Expand the browser you want setup instructions for.")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)

                        VStack(spacing: 10) {
                            InPageURLInstructionsDisclosure(
                                title: "Safari Instructions",
                                isExpanded: $isSafariInPageInstructionsExpanded
                            ) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("1. Open Safari.")
                                    Text("2. If the Develop menu is missing, enable it in Safari Settings > Advanced.")
                                    Text("3. Open Develop > Developer Settings...")

                                    InPageURLInstructionAssetView(
                                        assetName: "SafariInPageURLMenu",
                                        fileName: "safari_instructions_1.png",
                                        logName: "safari in-page URL menu instructions"
                                    )

                                    Text("4. In the Developer tab, turn on Allow JavaScript from Apple Events.")

                                    InPageURLInstructionAssetView(
                                        assetName: "SafariInPageURLToggle",
                                        fileName: "safari_instructions_2.png",
                                        logName: "safari in-page URL toggle instructions"
                                    )

                                    Text("5. When Safari shows the warning dialog, click Allow.")

                                    InPageURLInstructionAssetView(
                                        assetName: "SafariInPageURLAllow",
                                        fileName: "safari_instructions_3.png",
                                        logName: "safari in-page URL allow instructions"
                                    )
                                }
                                .font(.retraceMeta)
                                .foregroundColor(.retraceInk2)

                                InPageURLSecurityWarning(showSafariSpecificLine: true)
                            }

                            InPageURLInstructionsDisclosure(
                                title: "Chrome / Arc / Edge / Brave / Chromium Instructions",
                                isExpanded: $isChromeInPageInstructionsExpanded
                            ) {
                                VStack(alignment: .leading, spacing: 10) {
                                    if inPageURLTargets.contains(where: { $0.bundleID == "com.vivaldi.Vivaldi" }) {
                                        Text("In Vivaldi, enable Settings > Privacy and Security > Apple Events > Allow JavaScript from Apple Events.")
                                            .font(.retraceMeta)
                                            .foregroundColor(.retraceInk2)
                                    }

                                    Text("For Chrome, Arc, Edge, Brave, Chromium, Opera, Comet, Dia, and Thorium, open View > Developer > Allow JavaScript from Apple Events.")
                                        .font(.retraceMeta)
                                        .foregroundColor(.retraceInk2)

                                    InPageURLInstructionAssetView(
                                        assetName: "InPageURLInstructions",
                                        fileName: "safari_instructions.png",
                                        logName: "chromium in-page URL instructions"
                                    )
                                }

                                InPageURLSecurityWarning(showSafariSpecificLine: false)
                            }
                        }
                        .padding(.top, 4)
                    }

                    Divider().overlay(Color.retraceBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        let grantedTargets = inPageURLTargets.filter {
                            inPageURLPermissionStateByBundleID[$0.bundleID] == .granted
                        }
                        let browserTargets = grantedTargets.filter { !Self.isInPageURLChromiumWebAppBundleID($0.bundleID) }
                        let chromeAppTargets = grantedTargets.filter { Self.isInPageURLChromiumWebAppBundleID($0.bundleID) }

                        Text("Step 3: Test granted browsers and Chrome apps")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)
                        Text("Test URL: \(Self.inPageURLTestURLString)")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                        Text("Standard browsers open the test page. PWAs stay on their current page and only verify that a URL can be scraped.")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)

                        if grantedTargets.isEmpty {
                            Text("No granted automation permissions found yet. Complete Step 1 first.")
                                .font(.retraceMeta)
                                .foregroundColor(.retraceMuted)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                if !browserTargets.isEmpty {
                                    inPageURLVerificationSection(
                                        title: "Browsers",
                                        subtitle: nil,
                                        targets: browserTargets
                                    )
                                }

                                if !chromeAppTargets.isEmpty {
                                    inPageURLVerificationSection(
                                        title: "Chrome Apps",
                                        subtitle: "These inherit the host browser's JavaScript from Apple Events setting.",
                                        targets: chromeAppTargets
                                    )
                                }
                            }
                        }

                        if let summary = inPageURLVerificationSummary {
                            Text(summary)
                                .font(.retraceMeta)
                                .foregroundColor(.retraceMuted)
                        }
                    }
                }
            }
        }
        .task(id: collectInPageURLsExperimental) {
            guard collectInPageURLsExperimental else { return }
            await checkPermissions()
            await refreshInPageURLTargets()
        }
    }

    @ViewBuilder
    func inPageURLVerificationSection(
        title: String,
        subtitle: String?,
        targets: [InPageURLBrowserTarget]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.retraceCaption2Bold)
                .foregroundColor(.retracePrimary)

            if let subtitle {
                Text(subtitle)
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(targets) { target in
                    inPageURLVerificationRow(for: target)
                }
            }
        }
    }

    @ViewBuilder
    func inPageURLVerificationRow(for target: InPageURLBrowserTarget) -> some View {
        let isTesting = inPageURLVerificationBusyBundleIDs.contains(target.bundleID)
        let verificationState = inPageURLVerificationByBundleID[target.bundleID]

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Group {
                    if let icon = inPageURLIconByBundleID[target.bundleID] {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    } else {
                        RetraceSymbol("globe", size: 12)
                            .foregroundColor(.retraceSecondary)
                            .frame(width: 16, height: 16)
                    }
                }

                Text(target.displayName)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retracePrimary)

                Spacer()

                Button(action: {
                    Log.info(
                        "[InPageURL][SettingsTest][\(target.bundleID)] button_clicked displayName=\(target.displayName) busy=\(isTesting)",
                        category: .ui
                    )
                    Task { await runInPageURLVerification(for: target) }
                }) {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            RetraceSymbol("checkmark.circle", size: 12)
                        }
                        Text(isTesting ? "Testing..." : "Test")
                    }
                }
                .buttonStyle(RetraceButtonStyle(.primary, size: .sm))
                .disabled(isTesting)
            }

            if let verificationState {
                HStack(spacing: 8) {
                    switch verificationState {
                    case .pending:
                        ProgressView()
                            .controlSize(.small)
                    case .success:
                        RetraceSymbol("checkmark.circle.fill", size: 12)
                            .foregroundColor(.retraceSuccess)
                    case .warning:
                        RetraceSymbol("exclamationmark.triangle.fill", size: 12)
                            .foregroundColor(.retraceWarning)
                    case .failed:
                        RetraceSymbol("xmark.circle.fill", size: 12)
                            .foregroundColor(.retraceDanger)
                    }
                    Text(inPageURLVerificationDescription(verificationState))
                        .font(.retraceMeta)
                        .foregroundColor(.retraceInk2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.retraceSurfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
        .onAppear {
            scheduleInPageURLIconLoad(bundleID: target.bundleID, appURL: target.appURL)
        }
    }

    @ViewBuilder
    func inPageURLPermissionRow(target: InPageURLBrowserTarget) -> some View {
        let permissionState = inPageURLPermissionStateByBundleID[target.bundleID]
        let isRunning = inPageURLRunningBundleIDs.contains(target.bundleID)
        let isGranted = permissionState == .granted
        let buttonTitle = isGranted ? "Change" : (isRunning ? "Allow" : "Launch")
        let buttonBusyTitle = isRunning ? "Allowing..." : "Launching..."

        HStack(spacing: 12) {
            Group {
                if let icon = inPageURLIconByBundleID[target.bundleID] {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    RetraceSymbol("globe", size: 12)
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 20, height: 20)
                }
            }

            Text(target.displayName)
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)

            Spacer()

            inPageURLPermissionBadge(for: permissionState)

            Button(action: {
                if isGranted {
                    openAutomationSettings()
                    recordInPageURLMetric(
                        type: .inPageURLPermissionProbe,
                        payload: [
                            "bundleID": target.bundleID,
                            "action": "change_open_settings",
                            "status": "Granted"
                        ]
                    )
                    return
                }
                Task {
                    if isRunning {
                        await requestInPageURLPermission(for: target)
                    } else {
                        await launchInPageURLTarget(target)
                    }
                }
            }) {
                if inPageURLBusyBundleIDs.contains(target.bundleID) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(buttonBusyTitle)
                    }
                } else {
                    Text(buttonTitle)
                }
            }
            .buttonStyle(RetraceButtonStyle(.primary, size: .sm))
            .disabled(
                inPageURLBusyBundleIDs.contains(target.bundleID) ||
                (!isGranted && !hasAccessibilityPermission)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear {
            scheduleInPageURLIconLoad(bundleID: target.bundleID, appURL: target.appURL)
        }
    }

    @ViewBuilder
    func unsupportedInPageURLTargetRow(target: UnsupportedInPageURLTarget) -> some View {
        HStack(spacing: 12) {
            Group {
                if let icon = inPageURLIconByBundleID[target.bundleID] {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    RetraceSymbol("globe", size: 12)
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 20, height: 20)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retraceInk2)
                Text(target.reason)
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
            }

            Spacer()

            Text("Does Not Support")
                .font(.retraceCaption2Bold)
                .foregroundColor(.retraceInk2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.retraceSurfaceSunken)
                .clipShape(Capsule(style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(0.85)
        .onAppear {
            scheduleInPageURLIconLoad(bundleID: target.bundleID, appURL: target.appURL)
        }
    }

    @ViewBuilder
    func inPageURLPermissionBadge(for state: InPageURLPermissionState?) -> some View {
        let text = inPageURLPermissionDescription(for: state)
        let tone: RetraceBadgeTone = {
            switch state {
            case .granted?: return .good
            case .denied?: return .critical
            case .needsConsent?: return .warning
            case .unavailable(_)?, nil: return .neutral
            }
        }()
        RetraceBadge(text, tone: tone)
    }
}
