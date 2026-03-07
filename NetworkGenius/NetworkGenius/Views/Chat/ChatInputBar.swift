import SwiftUI

struct ChatInputBar: View {
    let isLoading: Bool
    let onSend: (String) -> Void
    let onOpenSettings: () -> Void
    @ObservedObject var speechService: SpeechService

    @State private var text = ""
    @State private var isPushToTalkActive = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
            }

            TextField("Ask about your network...", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit {
                    sendCurrentText()
                }
                .padding(10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20))

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading {
                // Push-to-talk mic when text field is empty
                ZStack {
                    Circle()
                        .fill(isPushToTalkActive ? Color.red : Color.accentColor)
                        .frame(width: 34, height: 34)
                    Image(systemName: isPushToTalkActive ? "waveform" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: isPushToTalkActive)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            beginPushToTalkIfNeeded()
                        }
                        .onEnded { _ in
                            endPushToTalkAndSubmit()
                        }
                )
                .accessibilityLabel("Hold to talk")
                .opacity(canUseSpeechInput ? 1 : 0.5)
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
        .onAppear {
            Task {
                await speechService.requestPermissions()
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

    private var canUseSpeechInput: Bool {
        speechService.micPermissionGranted && speechService.speechPermissionGranted
    }

    private func beginPushToTalkIfNeeded() {
        guard !isLoading else { return }
        guard !isPushToTalkActive else { return }
        guard canUseSpeechInput else { return }

        isPushToTalkActive = true
        speechService.startListening()
    }

    private func endPushToTalkAndSubmit() {
        guard isPushToTalkActive else { return }
        isPushToTalkActive = false
        text = ""
        Task {
            let spoken = await speechService.stopListening().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { return }
            onSend(spoken)
        }
    }
}
