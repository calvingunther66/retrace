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
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LinearGradient.retraceAccentGradient)
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
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.retraceSecondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            // Error banner if any
            if let error = viewModel.aiError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 14))
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
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            } else if let answer = viewModel.aiGeneratedAnswer {
                // Generated Text
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(answer.isEmpty && viewModel.isAIGenerating ? "Searching screen records..." : answer)
                            .font(.system(size: 13, weight: .regular, design: .default))
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
                                            Image(systemName: "clock.arrow.circlepath")
                                                .font(.system(size: 10))
                                                .foregroundColor(.retraceAccent)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(citation.appName)
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundColor(.retracePrimary)
                                                Text(formatCitationDate(citation.timestamp))
                                                    .font(.system(size: 9))
                                                    .foregroundColor(.retraceSecondary)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.white.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                        .cornerRadius(6)
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
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(LinearGradient.retraceAccentGradient.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 6)
    }

    private func formatCitationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
