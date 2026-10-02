import SwiftUI

/// Analytics card in the Linen / Dusk style: surface, hairline border, soft elevation
public struct AnalyticsCard: View {

    // MARK: - Properties

    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let tint: Color

    // MARK: - Initialization

    /// The gradient parameter is kept for call-site compatibility; the design system is flat, so the accent is a solid color.
    public init(
        title: String,
        value: String,
        subtitle: String? = nil,
        icon: String,
        gradient: LinearGradient = .retraceAccentGradient
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.tint = .retraceAccent
    }

    /// Legacy initializer for backwards compatibility
    public init(
        title: String,
        value: String,
        subtitle: String? = nil,
        icon: String,
        accentColor: Color
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.tint = accentColor
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Icon on an accent wash
            ZStack {
                Circle()
                    .fill(Color.retraceAccentWash)
                    .frame(width: 48, height: 48)

                RetraceSymbol(icon, size: 17, weight: .semibold, label: "")
                    .foregroundColor(tint)
            }

            VStack(alignment: .leading, spacing: 6) {
                // Value
                Text(value)
                    .font(.retraceLargeNumber)
                    .monospacedDigit()
                    .foregroundColor(.retraceInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // Title
                Text(title)
                    .font(.retraceLabel)
                    .retraceLabelTracking()
                    .foregroundColor(.retraceInk2)
            }

            // Subtitle (optional)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
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
}

// MARK: - Preview

#if DEBUG
struct AnalyticsCard_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 16) {
            AnalyticsCard(
                title: "Frames Captured",
                value: "2.3M",
                subtitle: "+1,247 today",
                icon: "photo.on.rectangle.angled",
                gradient: .retraceAccentGradient
            )

            AnalyticsCard(
                title: "Storage Used",
                value: "147 GB",
                subtitle: "23% of 500 GB",
                icon: "internaldrive",
                gradient: .retraceOrangeGradient
            )

            AnalyticsCard(
                title: "Days Recording",
                value: "127",
                subtitle: "Since Jan 15, 2024",
                icon: "calendar",
                gradient: .retraceGreenGradient
            )
        }
        .padding(32)
        .background(Color.retraceBackground)
    }
}
#endif
