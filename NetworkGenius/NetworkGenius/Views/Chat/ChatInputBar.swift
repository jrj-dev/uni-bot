import SwiftUI

struct ChatInputBar: View {
    let isLoading: Bool
    let onSend: (String) -> Void
    @ObservedObject var speechService: SpeechService

    @State private var text = ""

    var body: some View {
        HStack(spacing: 12) {
            TextField("Ask about your network...", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit {
                    sendCurrentText()
                }
                .padding(10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20))

            if speechService.isListening {
                // Show live transcript overlay
                Button {
                    let spoken = speechService.stopListening()
                    if !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        text = spoken
                    }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: true)
                }
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading {
                // Mic button when text field is empty
                Button {
                    Task {
                        await speechService.requestPermissions()
                        speechService.startListening()
                    }
                } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.title2)
                }
                .disabled(!speechService.micPermissionGranted && !speechService.speechPermissionGranted)
            } else {
                // Send button
                Button {
                    sendCurrentText()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: speechService.transcript) { _, newValue in
            if speechService.isListening {
                text = newValue
            }
        }
    }

    private func sendCurrentText() {
        guard !isLoading else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        text = ""
    }
}
