import SwiftUI
import AppKit

enum CommentContextPreviewStyle {
    static let previewWidth: CGFloat = 192
    static let previewHeight: CGFloat = 124
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 14
    static let metadataRowMinHeight: CGFloat = 16
    static let sectionCornerRadius: CGFloat = .radiusMd
    static let collapsedColumnWidth: CGFloat = 164
    static let collapseButtonSize: CGFloat = 24
    static let collapseButtonHitArea: CGFloat = 34
    static let collapseButtonInset: CGFloat = 34
    static let expandedPreviewTrailingInset: CGFloat = 30
}

private enum CommentContextPreviewFormatters {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

enum CommentContextPreviewMetadataLayout {
    case inline
    case stacked
}

private enum CommentContextPreviewShellStyle {
    static let contentTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)),
        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing))
    )
    static let collapseAnimation = Animation.spring(response: 0.24, dampingFraction: 0.88)
}

private struct CommentContextPreviewCollapseButton: View {
    let isCollapsed: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            RetraceSymbol(isCollapsed ? "chevron.down" : "chevron.up", size: 10, weight: .semibold)
                .foregroundColor(isHovering ? .retraceInk : .retraceInk2)
                .frame(
                    width: CommentContextPreviewStyle.collapseButtonSize,
                    height: CommentContextPreviewStyle.collapseButtonSize
                )
                .frame(
                    width: CommentContextPreviewStyle.collapseButtonHitArea,
                    height: CommentContextPreviewStyle.collapseButtonHitArea
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Expand context preview" : "Collapse context preview")
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

private struct CommentContextPreviewShell<ExpandedContent: View, CollapsedContent: View, FooterContent: View>: View {
    let isCollapsed: Bool
    let onToggleCollapsed: (() -> Void)?
    let expandedContent: ExpandedContent
    let collapsedContent: CollapsedContent
    let footerContent: FooterContent

    init(
        isCollapsed: Bool,
        onToggleCollapsed: (() -> Void)? = nil,
        @ViewBuilder expanded: () -> ExpandedContent,
        @ViewBuilder collapsed: () -> CollapsedContent,
        @ViewBuilder footer: () -> FooterContent
    ) {
        self.isCollapsed = isCollapsed
        self.onToggleCollapsed = onToggleCollapsed
        self.expandedContent = expanded()
        self.collapsedContent = collapsed()
        self.footerContent = footer()
    }

    var body: some View {
        CommentChromeSectionCard(cornerRadius: CommentContextPreviewStyle.sectionCornerRadius) {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if isCollapsed {
                        collapsedContent
                    } else {
                        expandedContent
                    }
                }
                .transition(CommentContextPreviewShellStyle.contentTransition)

                footerContent
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onToggleCollapsed {
                CommentContextPreviewCollapseButton(
                    isCollapsed: isCollapsed,
                    action: onToggleCollapsed
                )
                .padding(10)
            }
        }
        .animation(CommentContextPreviewShellStyle.collapseAnimation, value: isCollapsed)
    }
}

struct CommentContextPreviewCard<TagsContent: View, FooterContent: View>: View {
    let title: String
    let subtitle: String?
    let timestamp: Date
    let appBundleID: String?
    let previewImage: NSImage?
    let isPreviewLoading: Bool
    let shouldUseExpandedTitle: Bool
    let metadataLayout: CommentContextPreviewMetadataLayout
    let isCollapsed: Bool
    let onToggleCollapsed: (() -> Void)?
    let tagsContent: TagsContent
    let footerContent: FooterContent

    init(
        title: String,
        subtitle: String?,
        timestamp: Date,
        appBundleID: String?,
        previewImage: NSImage?,
        isPreviewLoading: Bool,
        shouldUseExpandedTitle: Bool,
        metadataLayout: CommentContextPreviewMetadataLayout = .inline,
        isCollapsed: Bool = false,
        onToggleCollapsed: (() -> Void)? = nil,
        @ViewBuilder tagsContent: () -> TagsContent,
        @ViewBuilder footerContent: () -> FooterContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self.timestamp = timestamp
        self.appBundleID = appBundleID
        self.previewImage = previewImage
        self.isPreviewLoading = isPreviewLoading
        self.shouldUseExpandedTitle = shouldUseExpandedTitle
        self.metadataLayout = metadataLayout
        self.isCollapsed = isCollapsed
        self.onToggleCollapsed = onToggleCollapsed
        self.tagsContent = tagsContent()
        self.footerContent = footerContent()
    }

    init(
        title: String,
        subtitle: String?,
        timestamp: Date,
        appBundleID: String?,
        previewImage: NSImage?,
        isPreviewLoading: Bool,
        shouldUseExpandedTitle: Bool,
        metadataLayout: CommentContextPreviewMetadataLayout = .inline,
        isCollapsed: Bool = false,
        onToggleCollapsed: (() -> Void)? = nil,
        @ViewBuilder tagsContent: () -> TagsContent
    ) where FooterContent == EmptyView {
        self.init(
            title: title,
            subtitle: subtitle,
            timestamp: timestamp,
            appBundleID: appBundleID,
            previewImage: previewImage,
            isPreviewLoading: isPreviewLoading,
            shouldUseExpandedTitle: shouldUseExpandedTitle,
            metadataLayout: metadataLayout,
            isCollapsed: isCollapsed,
            onToggleCollapsed: onToggleCollapsed,
            tagsContent: tagsContent,
            footerContent: { EmptyView() }
        )
    }

    var body: some View {
        CommentContextPreviewShell(
            isCollapsed: isCollapsed,
            onToggleCollapsed: onToggleCollapsed
        ) {
            expandedContent
        } collapsed: {
            collapsedContent
        } footer: {
            footerContent
        }
    }

    private var expandedContent: some View {
        HStack(alignment: .top, spacing: CommentContextPreviewStyle.sectionSpacing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Context Preview")
                    .font(.retraceLabel)
                    .foregroundColor(.retraceInk)
                    .lineLimit(2)
                    .padding(.leading, 4)

                HStack(alignment: .top, spacing: 10) {
                    previewAppIcon
                    previewTextStack(
                        titleLineLimit: shouldUseExpandedTitle ? 2 : 1,
                        showsSubtitle: true
                    )
                }

                expandedMetadataContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            previewSurface
                .frame(
                    width: CommentContextPreviewStyle.previewWidth,
                    height: CommentContextPreviewStyle.previewHeight
                )
                .padding(.trailing, onToggleCollapsed == nil ? 0 : CommentContextPreviewStyle.expandedPreviewTrailingInset)
        }
    }

    private var collapsedContent: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Context Preview")
                    .font(.retraceLabel)
                    .foregroundColor(.retraceInk)
                    .lineLimit(1)

                timestampLabel
            }
            .frame(
                width: CommentContextPreviewStyle.collapsedColumnWidth,
                alignment: .leading
            )

            previewAppIcon

            previewTextStack(
                titleLineLimit: shouldUseExpandedTitle ? 2 : 1,
                showsSubtitle: !shouldUseExpandedTitle
            )
                .padding(.trailing, onToggleCollapsed == nil ? 0 : CommentContextPreviewStyle.collapseButtonInset)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    }

    @ViewBuilder
    private var expandedMetadataContent: some View {
        switch metadataLayout {
        case .inline:
            HStack(alignment: .center, spacing: 12) {
                timestampLabel
                tagsContent
            }
            .frame(
                maxWidth: .infinity,
                minHeight: CommentContextPreviewStyle.metadataRowMinHeight,
                alignment: .leading
            )
        case .stacked:
            VStack(alignment: .leading, spacing: 10) {
                timestampLabel
                    .frame(
                        maxWidth: .infinity,
                        minHeight: CommentContextPreviewStyle.metadataRowMinHeight,
                        alignment: .leading
                    )
                tagsContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timestampLabel: some View {
        HStack(alignment: .center, spacing: 8) {
            RetraceSymbol("clock", size: 10, weight: .semibold)
                .foregroundColor(.retraceInk2)
                .frame(width: 14)

            Text(CommentContextPreviewFormatters.dateFormatter.string(from: timestamp))
                .font(.retraceMonoSmall)
                .monospacedDigit()
                .foregroundColor(.retraceInk2)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previewTextStack(titleLineLimit: Int, showsSubtitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.retraceCalloutBold)
                .foregroundColor(.retraceInk)
                .lineLimit(titleLineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsSubtitle,
               let subtitle,
               subtitle != title {
                Text(subtitle)
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var previewAppIcon: some View {
        if let appBundleID {
            AppIconView(bundleID: appBundleID, size: 34)
                .frame(width: 34, height: 34)
        } else {
            RetraceSymbol("macwindow", size: 14, weight: .semibold)
                .foregroundColor(.retraceInk)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                        .fill(Color.retraceSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                        .stroke(Color.retraceBorder, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(Color.retraceSurface)

            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if isPreviewLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.retraceInk2)
            } else {
                VStack(spacing: 7) {
                    RetraceSymbol("photo.on.rectangle.angled", size: 18, weight: .semibold)
                        .foregroundColor(.retraceMuted)

                    Text(title)
                        .font(.retraceCaptionBold)
                        .foregroundColor(.retraceInk2)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: .radiusMd, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
    }
}

struct CommentContextPreviewLoadingCard: View {
    let title: String
    let detail: String
    let isCollapsed: Bool
    let onToggleCollapsed: (() -> Void)?

    init(
        title: String,
        detail: String,
        isCollapsed: Bool = false,
        onToggleCollapsed: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.isCollapsed = isCollapsed
        self.onToggleCollapsed = onToggleCollapsed
    }

    var body: some View {
        CommentContextPreviewShell(
            isCollapsed: isCollapsed,
            onToggleCollapsed: onToggleCollapsed
        ) {
            expandedContent
        } collapsed: {
            collapsedContent
        } footer: {
            EmptyView()
        }
    }

    private var expandedContent: some View {
        HStack(alignment: .top, spacing: CommentContextPreviewStyle.sectionSpacing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.retraceLabel)
                    .foregroundColor(.retraceInk)
                    .padding(.leading, 4)

                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .fill(Color.retraceSurfaceHover)
                        .frame(width: 184, height: 14)

                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .fill(Color.retraceSurfaceHover)
                        .frame(width: 108, height: 11)
                }
                .padding(.top, 2)

                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .fill(Color.retraceSurfaceHover)
                    .frame(height: CommentContextPreviewStyle.metadataRowMinHeight)

                Text(detail)
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(Color.retraceSurface)
                .frame(
                    width: CommentContextPreviewStyle.previewWidth,
                    height: CommentContextPreviewStyle.previewHeight
                )
                .overlay(
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading preview")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                    }
                )
                .padding(.trailing, onToggleCollapsed == nil ? 0 : CommentContextPreviewStyle.expandedPreviewTrailingInset)
        }
    }

    private var collapsedContent: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Context Preview")
                    .font(.retraceLabel)
                    .foregroundColor(.retraceInk)
                    .lineLimit(1)

                HStack(alignment: .center, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(title)
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(
                width: CommentContextPreviewStyle.collapsedColumnWidth,
                alignment: .leading
            )

            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(Color.retraceSurface)
                .frame(width: 34, height: 34)
                .overlay(
                    RetraceSymbol("macwindow", size: 13, weight: .semibold)
                        .foregroundColor(.retraceInk2)
                )

            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .fill(Color.retraceSurfaceHover)
                    .frame(width: 124, height: 14)

                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .fill(Color.retraceSurfaceHover)
                    .frame(width: 86, height: 11)
            }
            .padding(.trailing, onToggleCollapsed == nil ? 0 : CommentContextPreviewStyle.collapseButtonInset)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    }

}
