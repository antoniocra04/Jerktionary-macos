import SwiftUI

struct ListenButton: View {
    @EnvironmentObject private var store: AppStore

    private var disabled: Bool {
        !store.isListening && (!store.backendReady || store.backendUnavailable)
    }

    var body: some View {
        Button {
            Task { await store.toggleListening() }
        } label: {
            Label(
                store.isListening ? "Стоп" : "Слушать",
                systemImage: store.isListening ? "stop.fill" : "mic.fill"
            )
            .font(.body.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(store.isListening ? .red : Theme.tint)
        .disabled(disabled)
    }
}

struct LevelMeterView: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                Capsule()
                    .fill(Theme.tint)
                    .frame(width: max(4, geometry.size.width * level))
                    .animation(reduceMotion ? nil : .linear(duration: 0.1), value: level)
            }
        }
        .frame(width: 96, height: 5)
    }
}
