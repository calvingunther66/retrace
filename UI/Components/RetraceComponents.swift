import SwiftUI

// MARK: - Design-system components
//
// SwiftUI counterparts of the Linen / Dusk components: Badge, Meter, Switch, Field, Tile and a section
// header. Buttons and cards live in AppTheme.swift (`RetraceButtonStyle`, `.retraceCard()`).

// MARK: Badge

public enum RetraceBadgeTone: Sendable {
    case neutral, accent, good, warning, critical
}

/// Small status pill. Always carries a word; never rely on color alone.
public struct RetraceBadge: View {
    let text: String
    let tone: RetraceBadgeTone

    public init(_ text: String, tone: RetraceBadgeTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .font(.retraceLabel)
            .foregroundColor(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(background))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return .retraceInk2
        case .accent: return .retraceInk
        case .good: return .retraceGood
        case .warning: return .retraceWarningText
        case .critical: return .retraceCritical
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return .retraceSurfaceSunken
        case .accent: return .retraceAccentWash
        case .good: return .retraceGoodBg
        case .warning: return .retraceWarningBg
        case .critical: return .retraceCriticalBg
        }
    }
}

// MARK: Meter

/// Progress or capacity as a smooth pill with a single solid accent fill.
public struct RetraceMeter: View {
    let value: Double
    let label: String
    var tint: Color = .retraceAccent

    public init(value: Double, label: String, tint: Color = .retraceAccent) {
        self.value = value
        self.label = label
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Color.retraceSurfaceSunken)
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(0, min(1, value / 100)) * proxy.size.width)
                    .animation(.easeOut(duration: 0.4), value: value)
            }
            .overlay(Capsule(style: .continuous).stroke(Color.retraceBorder, lineWidth: 1))
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(max(0, min(100, value)))) percent")
    }
}

// MARK: Switch

/// Toggles one setting immediately. Track uses `border-strong` when off and `accent` when on.
public struct RetraceSwitchStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                RetraceSwitchTrack(isOn: configuration.isOn)
                configuration.label
                    .font(.retraceCallout)
                    .foregroundColor(.retraceInk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct RetraceSwitchTrack: View {
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(isOn ? Color.retraceAccent : Color.retraceSurface)
            Capsule(style: .continuous)
                .stroke(isOn ? Color.retraceAccent : Color.retraceBorderStrong, lineWidth: 1)
            Circle()
                .fill(isOn ? Color.retraceOnAccent : Color.retraceBorderStrong)
                .frame(width: 14, height: 14)
                .padding(3)
        }
        .frame(width: 38, height: 22)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.easeOut(duration: 0.18), value: isOn)
        .retraceFocusRing(cornerRadius: 11)
    }
}

extension View {
    /// Applies the design-system switch to `Toggle`.
    public func retraceSwitch() -> some View {
        self.toggleStyle(RetraceSwitchStyle())
    }
}

// MARK: Field

/// Text input: `surface` fill, `border-strong` edge, `radius-sm`, accent focus ring.
public struct RetraceFieldStyle: TextFieldStyle {
    public init() {}

    public func _body(configuration: TextField<Self._Label>) -> some View {
        RetraceFieldBody(content: configuration)
    }
}

private struct RetraceFieldBody<Content: View>: View {
    let content: Content
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    var body: some View {
        content
            .textFieldStyle(.plain)
            .font(.retraceCallout)
            .foregroundColor(.retraceInk)
            .focused($isFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous).fill(Color.retraceSurface))
            .overlay(
                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .stroke(isFocused ? Color.retraceAccent : Color.retraceBorderStrong, lineWidth: isFocused ? 2 : 1)
            )
            .retraceElevation(.sm)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Labeled field with optional hint and error. The error replaces the hint.
public struct RetraceField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var hint: String?
    var error: String?

    public init(_ label: String, text: Binding<String>, placeholder: String = "", hint: String? = nil, error: String? = nil) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.hint = hint
        self.error = error
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.retraceLabel)
                .retraceLabelTracking()
                .foregroundColor(.retraceInk2)
            TextField(placeholder, text: $text)
                .textFieldStyle(RetraceFieldStyle())
            if let error {
                Text(error).font(.retraceCaption).foregroundColor(.retraceCritical)
            } else if let hint {
                Text(hint).font(.retraceMeta).foregroundColor(.retraceMuted)
            }
        }
    }
}

// MARK: Tile

/// One stat: a label, a mono value and an optional hint in caption.
public struct RetraceTile: View {
    let label: String
    let value: String
    var hint: String?

    public init(label: String, value: String, hint: String? = nil) {
        self.label = label
        self.value = value
        self.hint = hint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.retraceLabel)
                .retraceLabelTracking()
                .foregroundColor(.retraceInk2)
            Text(value)
                .font(.retraceLargeNumber)
                .monospacedDigit()
                .foregroundColor(.retraceInk)
                .padding(.top, 2)
            if let hint {
                Text(hint)
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .retraceCard()
    }
}

// MARK: Section header

/// `section-title` with an optional italic caption underneath, joined metadata style.
public struct RetraceSectionHeader: View {
    let title: String
    var subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.retraceTitle2).foregroundColor(.retraceInk)
            if let subtitle {
                Text(subtitle).font(.retraceMeta).foregroundColor(.retraceMuted)
            }
        }
    }
}
