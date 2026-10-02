import AppKit
import SwiftUI

enum RetraceAboutPanel {
    struct Content {
        static let defaultWindowSize = NSSize(width: 480, height: 560)
        static let defaultDescriptionText =
            "Retrace is an open source, local-first screen memory for macOS. It continuously captures what you see, extracts text with on-device OCR, and makes your screen history searchable without sending it to the cloud."
        static let repositoryURL = URL(string: "https://github.com/haseab/retrace")!
        static let creatorURL = URL(string: "https://retrace.to/l/haseab-twitter")!

        let appName: String
        let versionText: String
        let branchText: String?
        let descriptionText: String
        let repositoryURL: URL
        let creatorURL: URL
        let windowSize: NSSize
    }

    static func makeContent(appName: String) -> Content {
        Content(
            appName: appName,
            versionText: BuildInfo.displayVersion,
            branchText: BuildInfo.displayBranch,
            descriptionText: Content.defaultDescriptionText,
            repositoryURL: Content.repositoryURL,
            creatorURL: Content.creatorURL,
            windowSize: Content.defaultWindowSize
        )
    }

    @MainActor
    static func makeWindow(appName: String) -> NSWindow {
        let content = makeContent(appName: appName)
        let hostingController = NSHostingController(rootView: RetraceAboutPanelView(content: content))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.title = "About \(appName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor.retracePage
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace]
        window.setContentSize(content.windowSize)
        window.center()

        return window
    }
}

private struct RetraceAboutPanelView: View {
    let content: RetraceAboutPanel.Content

    var body: some View {
        ZStack {
            Color.retracePage
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 28)

                VStack(spacing: 18) {
                    RetraceMarkView(size: 64)
                        .frame(width: 104, height: 104)
                        .background(
                            RoundedRectangle(cornerRadius: .radiusLg, style: .continuous)
                                .fill(Color.retraceSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: .radiusLg, style: .continuous)
                                .stroke(Color.retraceBorder, lineWidth: 1)
                        )
                        .retraceElevation(.md)

                    VStack(spacing: 8) {
                        Text(content.appName)
                            .font(.retraceTitle)
                            .foregroundColor(.retraceInk)

                        Text("Local-first screen memory for macOS")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)

                        Text(content.versionText)
                            .font(.retraceMono)
                            .monospacedDigit()
                            .foregroundColor(.retraceInk2)

                        if let branchText = content.branchText {
                            Text(branchText)
                                .font(.retraceMonoSmall)
                                .foregroundColor(.retraceInk2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.retraceSurfaceSunken)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color.retraceBorder, lineWidth: 1)
                                )
                        }
                    }
                    .multilineTextAlignment(.center)
                }

                Rectangle()
                    .fill(Color.retraceBorder)
                    .frame(height: 1)
                    .padding(.top, 28)

                VStack(spacing: 22) {
                    Text(content.descriptionText)
                        .font(.retraceBody)
                        .foregroundColor(.retraceInk2)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .frame(maxWidth: 390)

                    HStack(spacing: 12) {
                        aboutLink(
                            title: "Open Source Repo",
                            systemImage: "arrow.up.right.square",
                            url: content.repositoryURL
                        )
                        aboutLink(
                            title: "@haseab on X",
                            systemImage: "person.crop.circle",
                            url: content.creatorURL
                        )
                    }
                    .frame(maxWidth: 390)
                }
                .padding(.top, 28)

                Spacer(minLength: 28)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(width: content.windowSize.width, height: content.windowSize.height)
    }

    private func aboutLink(title: String, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                RetraceSymbol(systemImage, size: 13, weight: .semibold)
                Text(title)
                    .font(.retraceCalloutBold)
                    .lineLimit(1)
            }
            .foregroundColor(.retraceInk)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                    .fill(Color.retraceSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                    .stroke(Color.retraceBorderStrong, lineWidth: 1)
            )
            .retraceElevation(.sm)
        }
        .buttonStyle(.plain)
    }
}
