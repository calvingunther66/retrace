import SwiftUI
import AppKit
import Shared

struct ModernSettingsCard<Content: View>: View {
    let title: String
    let icon: String?
    let customIcon: AnyView?
    var dangerous: Bool = false
    var trailingAction: (() -> Void)? = nil
    var trailingActionIcon: String? = nil
    var trailingActionTooltip: String? = nil
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        icon: String,
        dangerous: Bool = false,
        trailingAction: (() -> Void)? = nil,
        trailingActionIcon: String? = nil,
        trailingActionTooltip: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.customIcon = nil
        self.dangerous = dangerous
        self.trailingAction = trailingAction
        self.trailingActionIcon = trailingActionIcon
        self.trailingActionTooltip = trailingActionTooltip
        self.content = content
    }

    init<Icon: View>(
        title: String,
        dangerous: Bool = false,
        trailingAction: (() -> Void)? = nil,
        trailingActionIcon: String? = nil,
        trailingActionTooltip: String? = nil,
        @ViewBuilder iconView: () -> Icon,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = nil
        self.customIcon = AnyView(iconView())
        self.dangerous = dangerous
        self.trailingAction = trailingAction
        self.trailingActionIcon = trailingActionIcon
        self.trailingActionTooltip = trailingActionTooltip
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Group {
                    if let customIcon {
                        customIcon
                    } else if let icon {
                        RetraceSymbol(icon, size: 13.5)
                            .foregroundColor(dangerous ? .retraceCritical : .retraceInk2)
                    }
                }
                .frame(width: 18, height: 16, alignment: .center)

                Text(title)
                    .font(.retraceHeadline)
                    .foregroundColor(dangerous ? .retraceCritical : .retraceInk)

                Spacer()

                if let action = trailingAction, let actionIcon = trailingActionIcon {
                    Button(action: action) {
                        RetraceSymbol(actionIcon, size: 14)
                            .foregroundColor(.retraceMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(trailingActionTooltip ?? "Action")
                    .help(trailingActionTooltip ?? "")
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .retraceCard()
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(dangerous ? Color.retraceCritical.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}

struct RewindLogoIcon: View {
    var color: Color = .retraceInk

    var body: some View {
        RewindLogoShape()
            .fill(color)
            .accessibilityHidden(true)
    }
}

struct RewindLogoShape: Shape {
    private static let bounds = CGRect(x: -0.25, y: -0.75, width: 65.75, height: 41.5)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.bounds.width, rect.height / Self.bounds.height)
        let scaledWidth = Self.bounds.width * scale
        let scaledHeight = Self.bounds.height * scale
        let offsetX = rect.midX - (scaledWidth / 2)
        let offsetY = rect.midY - (scaledHeight / 2)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: offsetX + ((x - Self.bounds.minX) * scale),
                y: offsetY + ((y - Self.bounds.minY) * scale)
            )
        }

        var path = Path()
        path.move(to: point(32.1, 17.7))
        path.addLine(to: point(60.8, 0.6))
        path.addCurve(to: point(64.8, 3.5), control1: point(62.8, -0.6), control2: point(65.3, 1.2))
        path.addLine(to: point(63.8, 7.5))
        path.addCurve(to: point(63.8, 32.4), control1: point(61.8, 15.7), control2: point(61.8, 24.2))
        path.addLine(to: point(64.8, 36.4))
        path.addCurve(to: point(60.8, 39.3), control1: point(65.4, 38.7), control2: point(62.9, 40.5))
        path.addLine(to: point(32.1, 22.3))
        path.addCurve(to: point(31.6, 22.0), control1: point(31.9, 22.2), control2: point(31.8, 22.1))
        path.addCurve(to: point(33.0, 32.5), control1: point(31.7, 25.5), control2: point(32.2, 29.0))
        path.addLine(to: point(34.0, 36.5))
        path.addCurve(to: point(30.0, 39.4), control1: point(34.6, 38.8), control2: point(32.1, 40.6))
        path.addLine(to: point(1.5, 22.3))
        path.addCurve(to: point(1.5, 17.7), control1: point(-0.2, 21.3), control2: point(-0.2, 18.7))
        path.addLine(to: point(30.1, 0.6))
        path.addCurve(to: point(34.1, 3.5), control1: point(32.1, -0.6), control2: point(34.6, 1.2))
        path.addLine(to: point(33.1, 7.5))
        path.addCurve(to: point(31.7, 18.0), control1: point(32.3, 10.9), control2: point(31.8, 14.5))
        path.addCurve(to: point(32.1, 17.7), control1: point(31.8, 17.9), control2: point(32.0, 17.8))
        path.closeSubpath()
        return path
    }
}

struct ModernToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var disabled: Bool = false
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.retraceCalloutMedium)
                        .foregroundColor(disabled ? .retraceSecondary : .retracePrimary)

                    if let badge = badge {
                        RetraceBadge(badge, tone: .accent)
                    }
                }

                Text(subtitle)
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(RetraceSwitchStyle())
                .accessibilityLabel(title)
                .disabled(disabled)
        }
        .padding(.vertical, 4)
    }
}

struct ModernShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)

            Spacer()

            Text(shortcut)
                .font(.retraceMono)
                .foregroundColor(.retraceInk2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.retraceSurfaceSunken)
                .overlay(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous).stroke(Color.retraceBorderStrong, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
        }
    }
}

struct ModernPermissionRow: View {
    let label: String
    let status: PermissionStatus
    var enableAction: (() -> Void)? = nil
    var openSettingsAction: (() -> Void)? = nil
    @State private var isHoveringGrantedControl = false
    private static let grantedControlWidth: CGFloat = 120

    var body: some View {
        HStack {
            Text(label)
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)

            Spacer()

            if status == .granted {
                ZStack {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.retraceGood)
                            .frame(width: 8, height: 8)

                        Text(status.rawValue)
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retraceGood)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(width: Self.grantedControlWidth)
                    .background(Color.retraceGoodBg)
                    .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                    .opacity((openSettingsAction != nil && isHoveringGrantedControl) ? 0 : 1)

                    if let openSettingsAction {
                        Button(action: openSettingsAction) {
                            Text("Change")
                                .font(.retraceCaption2Bold)
                                .foregroundColor(.retraceOnAccent)
                                .padding(.vertical, 6)
                                .frame(width: Self.grantedControlWidth)
                                .background(Color.retraceAccent)
                                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .opacity(isHoveringGrantedControl ? 1 : 0)
                        .allowsHitTesting(isHoveringGrantedControl)
                    }
                }
                .onHover { hovering in
                    guard openSettingsAction != nil else { return }
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHoveringGrantedControl = hovering
                    }
                }
            } else {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.retraceWarningText)
                            .frame(width: 8, height: 8)

                        Text("Not Enabled")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retraceWarningText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.retraceWarningBg)
                    .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))

                    if let action = enableAction {
                        Button(action: action) {
                            Text("Enable")
                                .font(.retraceCaption2Bold)
                                .foregroundColor(.retraceOnAccent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.retraceAccent)
                                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    if let settingsAction = openSettingsAction {
                        Button(action: settingsAction) {
                            RetraceSymbol("gear", size: 12)
                                .foregroundColor(.retraceSecondary)
                                .padding(6)
                                .background(Color.retraceSurfaceSunken)
                                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Open System Settings")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ModernSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    @GestureState private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let thumbPosition = trackWidth * progress

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.retraceSurfaceSunken)
                    .overlay(Capsule(style: .continuous).stroke(Color.retraceBorder, lineWidth: 1))
                    .frame(height: 6)

                Capsule(style: .continuous)
                    .fill(Color.retraceAccent)
                    .frame(width: max(0, thumbPosition), height: 6)

                Circle()
                    .fill(Color.retraceAccent)
                    .frame(width: isDragging ? 16 : 14, height: isDragging ? 16 : 14)
                    .overlay(
                        Circle()
                            .stroke(Color.retraceSurface, lineWidth: 2)
                    )
                    .retraceElevation(.sm)
                    .offset(x: max(0, min(thumbPosition - 7, trackWidth - 14)))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { gestureValue in
                        let percentage = max(0, min(1, gestureValue.location.x / trackWidth))
                        let rawValue = range.lowerBound + (range.upperBound - range.lowerBound) * Double(percentage)
                        let steppedValue = round(rawValue / step) * step
                        let clampedValue = max(range.lowerBound, min(range.upperBound, steppedValue))
                        if clampedValue != value {
                            value = clampedValue
                        }
                    }
            )
        }
        .frame(height: 20)
    }

    private var progress: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

struct ModernSegmentedPicker<T: Hashable, Content: View>: View {
    @Binding var selection: T
    let options: [T]
    @ViewBuilder let label: (T) -> Content

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button(action: { selection = option }) {
                    label(option)
                        .font(selection == option ? .retraceCaptionBold : .retraceCaptionMedium)
                        .foregroundColor(selection == option ? .retraceInk : .retraceInk2)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                                .fill(selection == option ? Color.retraceAccentWash : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                                .stroke(selection == option ? Color.retraceAccent : Color.clear, lineWidth: 1)
                        )
                        .retraceFocusRing(cornerRadius: .radiusSm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.retraceSurfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: .radiusMd, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .radiusMd, style: .continuous).stroke(Color.retraceBorder, lineWidth: 1))
    }
}

struct ModernDropdown: View {
    @Binding var selection: Int
    let options: [(Int, String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(action: { selection = option.0 }) {
                    if selection == option.0 {
                        Label(option.1, systemImage: "checkmark")
                    } else {
                        Text(option.1)
                    }
                }
            }
        } label: {
            HStack {
                Text(options.first(where: { $0.0 == selection })?.1 ?? "")
                    .font(.retraceCallout)
                    .foregroundColor(.retraceInk)

                Spacer()

                // Native Menu labels only reliably render Text/Image, so this stays an SF Symbol.
                Image(systemName: "chevron.down")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceInk2)
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
        .menuStyle(.borderlessButton)
    }
}

struct ModernButton: View {
    let title: String
    let icon: String?
    let style: ButtonStyleType
    let action: () -> Void

    enum ButtonStyleType {
        case primary, secondary, danger
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = icon {
                    RetraceSymbol(icon, size: 12.5)
                }
                Text(title)
            }
        }
        .buttonStyle(RetraceButtonStyle(buttonKind))
    }

    private var buttonKind: RetraceButtonKind {
        switch style {
        case .primary: return .primary
        case .secondary: return .secondary
        case .danger: return .danger
        }
    }
}

struct FontStylePicker: View {
    @Binding var selection: RetraceFontStyle

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RetraceFontStyle.allCases) { style in
                Button(action: {
                    selection = style
                }) {
                    VStack(spacing: 8) {
                        Text("Aa")
                            .font(Self.previewFont(style, size: 24, semibold: true))
                            .foregroundColor(selection == style ? .retraceInk : .retraceInk2)

                        VStack(spacing: 2) {
                            Text(style.displayName)
                                .font(Self.previewFont(style, size: 11, semibold: true))
                                .foregroundColor(selection == style ? .retraceInk : .retraceInk2)

                            Text(style.description)
                                .font(Self.previewFont(style, size: 10, semibold: false))
                                .foregroundColor(.retraceInk2)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                            .fill(selection == style ? Color.retraceAccentWash : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                            .stroke(selection == style ? Color.retraceAccent : Color.clear, lineWidth: 1)
                    )
                    .retraceFocusRing(cornerRadius: .radiusMd)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color.retraceSurfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: .radiusMd, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .radiusMd, style: .continuous).stroke(Color.retraceBorder, lineWidth: 1))
    }

    /// Each option previews its own typeface, so this deliberately ignores the app-wide current style.
    private static func previewFont(_ style: RetraceFontStyle, size: CGFloat, semibold: Bool) -> Font {
        if style == .default, RetraceFontRegistry.isAvailable {
            return .custom(
                semibold ? RetraceFontRegistry.Face.serifSemibold : RetraceFontRegistry.Face.serifRegular,
                fixedSize: size
            )
        }
        return .system(size: size, weight: semibold ? .semibold : .regular, design: style.design)
    }
}

struct CaptureIntervalPicker: View {
    @Binding var selectedInterval: Double
    static let intervals: [Double] = [2, 5, 10, 15, 30, 60, 0]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.intervals, id: \.self) { interval in
                Text(Self.intervalLabel(interval))
                    .font(selectedInterval == interval ? .retraceCalloutBold : .retraceCalloutMedium)
                    .foregroundColor(selectedInterval == interval ? .retraceInk : .retraceInk2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .fill(selectedInterval == interval ? Color.retraceAccentWash : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .stroke(selectedInterval == interval ? Color.retraceAccent : Color.clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedInterval = interval
                    }
            }
        }
        .padding(4)
        .background(Color.retraceSurfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: .radiusMd, style: .continuous))
    }

    static func intervalLabel(_ interval: Double) -> String {
        if interval <= 0 {
            return "None"
        }
        if interval >= 60 {
            return "\(Int(interval / 60))m"
        }
        return "\(Int(interval))s"
    }
}

struct PauseReminderDelayPicker: View {
    @Binding var selectedMinutes: Double

    private let options: [(minutes: Double, label: String)] = [
        (1, "1m"), (5, "5m"), (15, "15m"), (30, "30m"), (60, "1h"),
        (120, "2h"), (240, "4h"), (480, "8h"), (0, "Never"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.minutes) { option in
                Text(option.label)
                    .font(selectedMinutes == option.minutes ? .retraceCalloutBold : .retraceCalloutMedium)
                    .foregroundColor(selectedMinutes == option.minutes ? .retraceInk : .retraceInk2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .fill(selectedMinutes == option.minutes ? Color.retraceAccentWash : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .stroke(selectedMinutes == option.minutes ? Color.retraceAccent : Color.clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedMinutes = option.minutes
                    }
            }
        }
        .padding(4)
        .background(Color.retraceSurfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: .radiusMd, style: .continuous))
    }
}

struct RetentionPolicyPicker: View {
    var displayDays: Int
    var onPreviewChange: (Int) -> Void
    var onSelectionEnd: (Int) -> Void

    private let options: [(days: Int, label: String)] = [
        (3, "3D"), (7, "1W"), (14, "2W"), (30, "1M"),
        (60, "2M"), (90, "3M"), (180, "6M"), (365, "1Y"), (0, "Forever")
    ]

    private var sliderIndex: Double {
        Double(options.firstIndex(where: { $0.days == displayDays }) ?? (options.count - 1))
    }

    @State private var lastSelectedDays: Int?

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                let horizontalInset: CGFloat = totalWidth / CGFloat(options.count) / 2
                let trackWidth = totalWidth - (horizontalInset * 2)
                let segmentWidth = trackWidth / CGFloat(options.count - 1)

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.retraceSurfaceSunken)
                        .frame(width: trackWidth, height: 4)
                        .offset(x: horizontalInset)

                    Capsule(style: .continuous)
                        .fill(Color.retraceAccent)
                        .frame(width: max(0, CGFloat(sliderIndex) * segmentWidth), height: 4)
                        .offset(x: horizontalInset)

                    HStack(spacing: 0) {
                        ForEach(0..<options.count, id: \.self) { index in
                            Circle()
                                .fill(index <= Int(sliderIndex) ? Color.retraceAccent : Color.retraceBorderStrong)
                                .frame(width: index == Int(sliderIndex) ? 14 : 8, height: index == Int(sliderIndex) ? 14 : 8)
                                .overlay(
                                    Circle()
                                        .stroke(Color.retraceSurface, lineWidth: index == Int(sliderIndex) ? 2 : 0)
                                )
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let adjustedX = value.location.x - horizontalInset
                            let index = Int(round(adjustedX / segmentWidth))
                            let clampedIndex = max(0, min(options.count - 1, index))
                            let newDays = options[clampedIndex].days
                            if newDays != displayDays {
                                lastSelectedDays = newDays
                                onPreviewChange(newDays)
                            }
                        }
                        .onEnded { _ in
                            if let selectedDays = lastSelectedDays {
                                onSelectionEnd(selectedDays)
                                lastSelectedDays = nil
                            }
                        }
                )
            }
            .frame(height: 30)

            HStack(spacing: 0) {
                ForEach(0..<options.count, id: \.self) { index in
                    Text(options[index].label)
                        .font(index == Int(sliderIndex) ? .retraceTinyBold : .retraceTiny)
                        .foregroundColor(index == Int(sliderIndex) ? .retraceInk : .retraceInk2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
