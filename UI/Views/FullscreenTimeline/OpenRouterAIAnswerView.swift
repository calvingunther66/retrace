import SwiftUI
import Shared

public struct OpenRouterAIAnswerView: View {
    @ObservedObject var viewModel: SearchViewModel
    var onSelectCitation: ((OpenRouterCitation) -> Void)?

    public init(
        viewModel: SearchViewModel,
        onSelectCitation: ((OpenRouterCitation) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onSelectCitation = onSelectCitation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    RetraceSymbol("sparkles", size: 13, weight: .semibold)
                        .foregroundColor(.retraceAccent)
                    Text("Retrace AI Answer")
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)
                }

                Spacer()

                if viewModel.isAIGenerating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                        Text("Synthesizing...")
                            .font(.retraceCaption2Medium)
                            .foregroundColor(.retraceSecondary)
                    }
                }

                Button(action: {
                    viewModel.clearAIAnswer()
                }) {
                    RetraceSymbol("xmark.circle.fill", size: 14)
                        .foregroundColor(.retraceInk2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear AI answer")
            }

            // Error banner if any
            if let error = viewModel.aiError {
                HStack(spacing: 10) {
                    RetraceSymbol("exclamationmark.triangle.fill", size: 14)
                        .foregroundColor(.retraceWarningText)
                    Text(error)
                        .font(.retraceCaption)
                        .foregroundColor(.retracePrimary)
                    Spacer()
                    Button("Open Settings") {
                        NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsAI"), object: nil)
                    }
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceAccent)
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Color.retraceWarningBg)
                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
            } else if let answer = viewModel.aiGeneratedAnswer {
                // Generated Text
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(answer.isEmpty && viewModel.isAIGenerating ? "Searching screen records..." : answer)
                            .font(.retraceCallout)
                            .lineSpacing(4)
                            .foregroundColor(.retracePrimary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)

                // Citations list
                if !viewModel.aiCitations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cited Screen Records:")
                            .font(.retraceCaption2Medium)
                            .foregroundColor(.retraceSecondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(viewModel.aiCitations) { citation in
                                    Button(action: {
                                        onSelectCitation?(citation)
                                    }) {
                                        HStack(spacing: 6) {
                                            RetraceSymbol("clock.arrow.circlepath", size: 10, label: "")
                                                .foregroundColor(.retraceAccent)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(citation.appName)
                                                    .font(.retraceTinyBold)
                                                    .foregroundColor(.retracePrimary)
                                                Text(formatCitationDate(citation.timestamp))
                                                    .font(RetraceFont.mono(size: 9))
                                                    .foregroundColor(.retraceSecondary)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.retraceSurfaceSunken)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                                                .stroke(Color.retraceBorder, lineWidth: 1)
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.retraceSurface)
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: .radiusMd, style: .continuous))
        .retraceElevation(.md)
    }

    private func formatCitationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
