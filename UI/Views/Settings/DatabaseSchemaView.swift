import SwiftUI
import AppKit

struct DatabaseSchemaView: View {
    let schemaText: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Database Schema")
                    .font(.retraceTitle2)
                    .foregroundColor(.retraceInk)

                Spacer()

                Button(action: { isPresented = false }) {
                    RetraceSymbol("xmark.circle.fill", size: 20)
                        .foregroundColor(.retraceSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.retraceBackground)

            Divider().overlay(Color.retraceBorder)

            ScrollView {
                Text(schemaText.isEmpty ? "Loading..." : schemaText)
                    .font(.retraceMonoSmall)
                    .foregroundColor(.retraceTermInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.retraceTermBg)

            Divider().overlay(Color.retraceBorder)

            HStack {
                Spacer()

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(schemaText, forType: .string)
                }) {
                    HStack(spacing: 6) {
                        RetraceSymbol("doc.on.doc", size: 13)
                        Text("Copy to Clipboard")
                    }
                    .font(.retraceCallout)
                }
                .buttonStyle(.plain)
                .foregroundColor(.retraceInk)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.retraceAccentWash)
                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
            }
            .padding()
            .background(Color.retraceBackground)
        }
        .frame(width: 600, height: 500)
        .background(Color.retraceBackground)
        .clipShape(RoundedRectangle(cornerRadius: .radiusLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .radiusLg, style: .continuous).stroke(Color.retraceBorder, lineWidth: 1))
    }
}
