import SwiftUI
import AppKit
import Shared

struct CommentChromeHeader<Leading: View, Accessory: View>: View {
    let title: String
    let onClose: () -> Void
    let spacing: CGFloat
    let iconContainerSize: CGFloat
    let iconCornerRadius: CGFloat
    let iconSize: CGFloat
    let leading: Leading
    let accessory: Accessory

    init(
        title: String,
        onClose: @escaping () -> Void,
        spacing: CGFloat = 12,
        iconContainerSize: CGFloat = 34,
        iconCornerRadius: CGFloat = .radiusMd,
        iconSize: CGFloat = 14,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.onClose = onClose
        self.spacing = spacing
        self.iconContainerSize = iconContainerSize
        self.iconCornerRadius = iconCornerRadius
        self.iconSize = iconSize
        self.leading = leading()
        self.accessory = accessory()
    }

    init(
        title: String,
        onClose: @escaping () -> Void,
        spacing: CGFloat = 12,
        iconContainerSize: CGFloat = 34,
        iconCornerRadius: CGFloat = .radiusMd,
        iconSize: CGFloat = 14,
        @ViewBuilder accessory: () -> Accessory
    ) where Leading == EmptyView {
        self.init(
            title: title,
            onClose: onClose,
            spacing: spacing,
            iconContainerSize: iconContainerSize,
            iconCornerRadius: iconCornerRadius,
            iconSize: iconSize,
            leading: { EmptyView() },
            accessory: accessory
        )
    }

    init(
        title: String,
        onClose: @escaping () -> Void,
        spacing: CGFloat = 12,
        iconContainerSize: CGFloat = 34,
        iconCornerRadius: CGFloat = .radiusMd,
        iconSize: CGFloat = 14
    ) where Leading == EmptyView, Accessory == EmptyView {
        self.init(
            title: title,
            onClose: onClose,
            spacing: spacing,
            iconContainerSize: iconContainerSize,
            iconCornerRadius: iconCornerRadius,
            iconSize: iconSize,
            leading: { EmptyView() },
            accessory: { EmptyView() }
        )
    }

    var body: some View {
        HStack(spacing: spacing) {
            leading

            RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
                .fill(Color.retraceSurfaceSunken)
                .frame(width: iconContainerSize, height: iconContainerSize)
                .overlay(
                    RetraceSymbol("text.bubble.fill", size: iconSize, weight: .semibold)
                        .foregroundColor(.retraceInk)
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.retraceHeadline)
                    .foregroundColor(.retraceInk)
            }

            Spacer()

            accessory

            CommentChromeCircleButton(
                icon: "xmark",
                action: onClose,
                iconSize: 10,
                baseForeground: .retraceInk2,
                hoverForeground: .retraceInk,
                baseFill: .retraceSurfaceSunken,
                hoverFill: .retraceAccentWash,
                baseStroke: .retraceBorder,
                hoverStroke: .retraceAccent
            )
        }
    }
}

struct CommentChromeCircleButton: View {
    let icon: String
    let action: () -> Void
    /// VoiceOver name; defaults to a verb derived from the icon.
    var label: String? = nil
    var iconSize: CGFloat = 10
    var baseForeground: Color = .retraceInk2
    var hoverForeground: Color = .retraceInk
    var baseFill: Color = .retraceSurfaceSunken
    var hoverFill: Color = .retraceAccentWash
    var baseStroke: Color = .retraceBorder
    var hoverStroke: Color = .retraceAccent
    var onHoverChanged: ((Bool) -> Void)? = nil

    @State private var isHovering = false

    private static func defaultLabel(forIcon icon: String) -> String {
        switch icon {
        case "xmark", "xmark.circle.fill": return "Close"
        case "plus": return "Add"
        case "trash": return "Delete"
        default: return "Button"
        }
    }

    var body: some View {
        Button(action: action) {
            RetraceSymbol(icon, size: iconSize, weight: .semibold, label: "")
                .foregroundColor(isHovering ? hoverForeground : baseForeground)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isHovering ? hoverFill : baseFill)
                )
                .overlay(
                    Circle()
                        .stroke(isHovering ? hoverStroke : baseStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? Self.defaultLabel(forIcon: icon))
        .retraceFocusRing(cornerRadius: .radiusMd)
        .onHover { hovering in
            isHovering = hovering
            onHoverChanged?(hovering)
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

enum CommentChromeCapsuleButtonStyle: Equatable {
    case accentOutline
    case submit
    case tagSelection(isSelected: Bool)

    func foregroundColor(isHovering: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else { return .retraceInk2 }

        switch self {
        case .accentOutline:
            return .retraceInk
        case .submit:
            return isHovering ? .retraceInk : .retraceAccent
        case .tagSelection(let isSelected):
            if isSelected {
                return .retraceInk
            }
            return isHovering ? .retraceInk : .retraceInk2
        }
    }

    func backgroundColor(isHovering: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else { return .retraceSurfaceSunken }

        switch self {
        case .accentOutline:
            return isHovering ? .retraceAccentWash : .retraceSurfaceSunken
        case .submit:
            return .retraceAccentWash
        case .tagSelection(let isSelected):
            if isSelected {
                return .retraceAccentWash
            }
            return isHovering ? .retraceSurfaceHover : .retraceSurfaceSunken
        }
    }

    func borderColor(isHovering: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else { return .retraceBorder }

        switch self {
        case .accentOutline:
            return isHovering ? .retraceAccent : .retraceBorderStrong
        case .submit:
            return isHovering ? .retraceAccent : Color.retraceAccent.opacity(0.5)
        case .tagSelection(let isSelected):
            if isSelected {
                return .retraceAccent
            }
            return isHovering ? .retraceBorderStrong : .retraceBorder
        }
    }
}

struct CommentChromeCapsuleButton<Label: View>: View {
    let action: () -> Void
    var isEnabled: Bool = true
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 6
    var style: CommentChromeCapsuleButtonStyle = .accentOutline
    var onHoverChanged: ((Bool) -> Void)? = nil
    let label: Label

    @State private var isHovering = false

    init(
        action: @escaping () -> Void,
        isEnabled: Bool = true,
        horizontalPadding: CGFloat = 14,
        verticalPadding: CGFloat = 6,
        style: CommentChromeCapsuleButtonStyle = .accentOutline,
        onHoverChanged: ((Bool) -> Void)? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.isEnabled = isEnabled
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.style = style
        self.onHoverChanged = onHoverChanged
        self.label = label()
    }

    var body: some View {
        let isActivelyHovering = isHovering && isEnabled

        Button(action: action) {
            label
                .foregroundColor(style.foregroundColor(isHovering: isActivelyHovering, isEnabled: isEnabled))
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(
                    Capsule(style: .continuous)
                        .fill(style.backgroundColor(isHovering: isActivelyHovering, isEnabled: isEnabled))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            style.borderColor(isHovering: isActivelyHovering, isEnabled: isEnabled),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(style == .tagSelection(isSelected: true) ? .isSelected : [])
        .retraceFocusRing(cornerRadius: .radiusMd)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovering = hovering
            onHoverChanged?(hovering)
            if hovering && isEnabled {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct CommentChromeChip<Accessory: View>: View {
    let text: String
    let icon: String
    let foregroundColor: Color
    let backgroundColor: Color
    let borderColor: Color
    let accessory: (Bool) -> Accessory

    @State private var isHovering = false

    init(
        text: String,
        icon: String,
        foregroundColor: Color,
        backgroundColor: Color,
        borderColor: Color,
        @ViewBuilder accessory: @escaping (Bool) -> Accessory
    ) {
        self.text = text
        self.icon = icon
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.accessory = accessory
    }

    init(
        text: String,
        icon: String,
        foregroundColor: Color,
        backgroundColor: Color,
        borderColor: Color
    ) where Accessory == EmptyView {
        self.init(
            text: text,
            icon: icon,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
            borderColor: borderColor,
            accessory: { _ in EmptyView() }
        )
    }

    var body: some View {
        HStack(spacing: 5) {
            RetraceSymbol(icon, size: 9, weight: .semibold)

            Text(text)
                .font(RetraceFont.font(size: 10, weight: .semibold))
                .lineLimit(1)

            accessory(isHovering)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .contentShape(Capsule(style: .continuous))
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

struct CommentChromeEditorSurface<Editor: View>: View {
    let isFocused: Bool
    let textIsEmpty: Bool
    let placeholder: String
    let editor: Editor

    init(
        isFocused: Bool,
        textIsEmpty: Bool,
        placeholder: String,
        @ViewBuilder editor: () -> Editor
    ) {
        self.isFocused = isFocused
        self.textIsEmpty = textIsEmpty
        self.placeholder = placeholder
        self.editor = editor()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            editor

            if textIsEmpty {
                Text(placeholder)
                    .font(.retraceCaption)
                    .foregroundColor(.retraceMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(Color.retraceSurfaceSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(
                    isFocused ? Color.retraceAccent : Color.retraceBorderStrong,
                    lineWidth: 1
                )
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

enum CommentTagPickerStyle {
    case contextMenu
    case commentOverlay

    var backgroundColor: Color {
        switch self {
        case .contextMenu:
            return RetraceMenuStyle.backgroundColor
        case .commentOverlay:
            return RetraceMenuStyle.backgroundColor
        }
    }

    var borderColor: Color {
        switch self {
        case .contextMenu:
            return Color.retraceBorder
        case .commentOverlay:
            return RetraceMenuStyle.borderColor
        }
    }
}

struct CommentTagPickerMenu: View {
    let tags: [Tag]
    let selectedTagIDs: Set<TagID>
    let style: CommentTagPickerStyle
    let dismissOnEscape: (() -> Void)?
    let onHoverChanged: ((Bool) -> Void)?
    let onSelectTag: (Tag) -> Void
    let onCreateTag: (String) -> Void
    let onOpenSettings: () -> Void

    @State private var searchText = ""
    @State private var highlightedTagID: Int64?
    @State private var isHoveringSettingsButton = false
    @State private var keyboardMonitor: Any?
    @FocusState private var isSearchFocused: Bool

    init(
        tags: [Tag],
        selectedTagIDs: Set<TagID>,
        style: CommentTagPickerStyle = .contextMenu,
        dismissOnEscape: (() -> Void)? = nil,
        onHoverChanged: ((Bool) -> Void)? = nil,
        onSelectTag: @escaping (Tag) -> Void,
        onCreateTag: @escaping (String) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.tags = tags
        self.selectedTagIDs = selectedTagIDs
        self.style = style
        self.dismissOnEscape = dismissOnEscape
        self.onHoverChanged = onHoverChanged
        self.onSelectTag = onSelectTag
        self.onCreateTag = onCreateTag
        self.onOpenSettings = onOpenSettings
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleTags: [Tag] {
        let filtered = trimmedSearchText.isEmpty
            ? tags
            : tags.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearchText) }

        return filtered.sorted { lhs, rhs in
            let lhsSelected = selectedTagIDs.contains(lhs.id)
            let rhsSelected = selectedTagIDs.contains(rhs.id)
            if lhsSelected != rhsSelected {
                return lhsSelected
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var exactTagMatch: Bool {
        tags.contains { $0.name.caseInsensitiveCompare(trimmedSearchText) == .orderedSame }
    }

    private var showCreateOption: Bool {
        !trimmedSearchText.isEmpty && !exactTagMatch
    }

    private var visibleTagIDs: [Int64] {
        visibleTags.map { $0.id.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RetraceSymbol("magnifyingglass", size: 12)
                    .foregroundColor(.retraceMuted)

                TextField("Search or create...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.retraceCallout)
                    .foregroundColor(.retraceInk)
                    .focused($isSearchFocused)
                    .onSubmit {
                        selectHighlightedTagOrCreate()
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .fill(Color.retraceSurfaceSunken)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                isSearchFocused = true
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 6)

            Divider()
                .background(Color.retraceBorder)
                .padding(.horizontal, 8)

            if visibleTags.isEmpty && !showCreateOption {
                Text("No tags found")
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleTags) { tag in
                            TagSubmenuRow(
                                tag: tag,
                                isSelected: selectedTagIDs.contains(tag.id),
                                isKeyboardHighlighted: highlightedTagID == tag.id.value,
                                onHoverChanged: { hovering in
                                    if hovering {
                                        highlightedTagID = tag.id.value
                                    }
                                }
                            ) {
                                onSelectTag(tag)
                            }
                        }

                        if showCreateOption {
                            Button(action: createTagFromSearch) {
                                HStack(spacing: 10) {
                                    RetraceSymbol("plus", size: 12, weight: .medium)
                                        .foregroundColor(.retraceAccent)

                                    Text("Create \"\(trimmedSearchText)\"")
                                        .font(.retraceCallout)
                                        .foregroundColor(.retraceAccent)

                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() }
                                else { NSCursor.pop() }
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }

            Divider()
                .background(Color.retraceBorder)
                .padding(.horizontal, 8)
                .padding(.top, 6)

            Button(action: onOpenSettings) {
                HStack(spacing: 10) {
                    RetraceSymbol("slider.horizontal.3", size: 12, weight: .medium)
                        .foregroundColor(.retraceInk2)

                    Text("Tag Settings")
                        .font(.retraceCallout)
                        .foregroundColor(.retraceInk)

                    Spacer()
                }
                .padding(.leading, 0)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .fill(isHoveringSettingsButton ? Color.retraceSurfaceHover : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    isHoveringSettingsButton = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
        .padding(.vertical, 2)
        .frame(width: 180)
        .background(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius, style: .continuous)
                .fill(style.backgroundColor)
                .retraceElevation(.md)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius, style: .continuous)
                .stroke(style.borderColor, lineWidth: RetraceMenuStyle.borderWidth)
        )
        .contentShape(RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius, style: .continuous))
        .compositingGroup()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
            syncHighlightedTagToFirstVisibleResult()
            installKeyboardMonitor()
        }
        .onChange(of: searchText) { _ in
            syncHighlightedTagToFirstVisibleResult()
        }
        .onChange(of: visibleTagIDs) { _ in
            syncHighlightedTagToFirstVisibleResult()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .onHover { hovering in
            onHoverChanged?(hovering)
        }
        .keyboardNavigation(
            onUpArrow: { moveHighlight(by: -1) },
            onDownArrow: { moveHighlight(by: 1) },
            onReturn: {
                selectHighlightedTagOrCreate()
            }
        )
    }

    private func syncHighlightedTagToFirstVisibleResult() {
        if let highlightedTagID, visibleTagIDs.contains(highlightedTagID) {
            return
        }
        highlightedTagID = visibleTagIDs.first
    }

    private func moveHighlight(by offset: Int) {
        guard !visibleTagIDs.isEmpty else { return }
        let currentIndex: Int
        if let highlightedTagID,
           let existingIndex = visibleTagIDs.firstIndex(of: highlightedTagID) {
            currentIndex = existingIndex
        } else {
            currentIndex = 0
        }

        let nextIndex = max(0, min(visibleTagIDs.count - 1, currentIndex + offset))
        highlightedTagID = visibleTagIDs[nextIndex]
    }

    private func selectHighlightedTagOrCreate() {
        if showCreateOption {
            createTagFromSearch()
        } else if let highlightedTagID,
                  let highlightedTag = visibleTags.first(where: { $0.id.value == highlightedTagID }) {
            onSelectTag(highlightedTag)
        }
    }

    private func createTagFromSearch() {
        guard !trimmedSearchText.isEmpty else { return }
        onCreateTag(trimmedSearchText)
        searchText = ""
    }

    private func installKeyboardMonitor() {
        guard dismissOnEscape != nil else { return }
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                dismissOnEscape?()
                return nil
            }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }
}

struct CommentChromeSectionCard<Content: View>: View {
    var cornerRadius: CGFloat = .radiusMd
    let content: Content

    init(cornerRadius: CGFloat = .radiusMd, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.retraceSurfaceSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.retraceBorder, lineWidth: 1)
            )
    }
}
