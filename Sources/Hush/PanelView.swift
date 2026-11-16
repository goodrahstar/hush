import SwiftUI

// mono variant: system font, black accent, lowercase, one italic word per heading.
private enum Ink {
    static let bg = Color(white: 0.96)
    static let surface = Color.white
    static let fill = Color(red: 0.914, green: 0.910, blue: 0.918) // #e9e8ea
    static let ink = Color.black
    static let ink2 = Color.black.opacity(0.64)
    static let ink3 = Color.black.opacity(0.56)
    static let line = Color.black.opacity(0.08)
}

struct PanelState {
    var phase: Phase
    var music: Double
    var voice: Double
    var threshold: Double
    var volume: Double
    var duckedFrom: Double?
    var problem: String?
    var micName: String
    var ducks: Int
}

struct PanelView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        PanelBody(
            state: PanelState(phase: controller.phase, music: controller.music, voice: controller.voice,
                              threshold: controller.threshold, volume: controller.volume,
                              duckedFrom: controller.duckedFrom, problem: controller.problem,
                              micName: controller.micName, ducks: controller.ducksToday),
            settings: $controller.settings,
            preferBuiltInMic: $controller.preferBuiltInMic,
            opensAtLogin: Binding(get: { controller.opensAtLogin }, set: { controller.opensAtLogin = $0 }),
            quit: { controller.shutdown(); NSApp.terminate(nil) }
        )
    }
}

struct PanelBody: View {
    var state: PanelState
    @Binding var settings: DuckSettings
    @Binding var preferBuiltInMic: Bool
    @Binding var opensAtLogin: Bool
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PowerCard(isOn: $settings.enabled)
            header
            meters
            if let problem = state.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.fill))
            }
            controls
            footer
        }
        .padding(16)
        .frame(width: 320)
        .background(Ink.bg)
        .environment(\.colorScheme, .light)
    }

    // MARK: sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            headline
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.9)
                .foregroundStyle(Ink.ink)
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: state.phase)
            Text(subline)
                .font(.system(size: 12))
                .foregroundStyle(Ink.ink3)
        }
    }

    private var headline: Text {
        switch state.phase {
        case .off: return Text("hush is ") + Text("paused.").italic().fontWeight(.medium)
        case .quiet: return Text("nothing ") + Text("playing.").italic().fontWeight(.medium)
        case .listening: return Text("music on. ") + Text("listening.").italic().fontWeight(.medium)
        case .ducked: return Text("someone's ") + Text("talking.").italic().fontWeight(.medium)
        }
    }

    private var subline: String {
        switch state.phase {
        case .off: return "turn it on to lower music when people talk."
        case .quiet: return "hush wakes up when music starts."
        case .listening: return "music drops the moment someone speaks."
        case .ducked:
            let from = Int(((state.duckedFrom ?? state.volume) * 100).rounded())
            return "music down from \(from)% to \(pct(state.volume)) · back after \(fmt(settings.holdSeconds)) s of quiet"
        }
    }

    private var meters: some View {
        VStack(spacing: 12) {
            MeterRow(label: "music", value: state.music, mark: 0.3)
            MeterRow(label: "voice", value: state.voice, mark: state.threshold)
            HStack {
                Text("volume").foregroundStyle(Ink.ink3)
                Spacer()
                Text(state.duckedFrom.map { "\(pct($0)) → \(pct(state.volume))" } ?? pct(state.volume))
                    .monospacedDigit().foregroundStyle(Ink.ink)
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.surface))
    }

    private var controls: some View {
        VStack(spacing: 0) {
            SliderRow(title: "lower to", value: $settings.duckTo, range: 0.1...0.7, step: 0.05,
                      display: "\(Int((settings.duckTo * 100).rounded()))% of volume")
            Divider().overlay(Ink.line)
            SliderRow(title: "sensitivity", value: $settings.sensitivity, range: 0...1, step: 0.05,
                      display: settings.sensitivity < 0.34 ? "only clear talking" : settings.sensitivity < 0.67 ? "normal" : "even quiet voices")
            Divider().overlay(Ink.line)
            SliderRow(title: "bring music back after", value: $settings.holdSeconds, range: 1...8, step: 0.5,
                      display: "\(fmt(settings.holdSeconds)) s of quiet")
            Divider().overlay(Ink.line)
            ToggleRow(title: "use the mac's own mic", detail: "keeps airpods in full-quality sound", isOn: $preferBuiltInMic)
            Divider().overlay(Ink.line)
            ToggleRow(title: "open at login", isOn: $opensAtLogin)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.surface))
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.system(size: 11))
                .foregroundStyle(Ink.ink3)
                .lineLimit(1)
            Spacer()
            Button("quit", action: quit)
                .buttonStyle(PillButton())
                .keyboardShortcut("q")
        }
    }

    private var footerText: String {
        let mic = state.micName.isEmpty ? "" : state.micName.contains("macbook") || state.micName.contains("built-in") ? " · built-in mic" : " · \(state.micName)"
        return "on device\(mic) · \(state.ducks) ducked"
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func fmt(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v) }
}

// MARK: components

private struct MeterRow: View {
    var label: String
    var value: Double
    var mark: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Ink.ink3)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.fill)
                    Capsule().fill(Ink.ink)
                        .frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
                        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.25), value: value)
                    Rectangle().fill(Ink.ink.opacity(0.35))
                        .frame(width: 1.5, height: 12)
                        .offset(x: geo.size.width * min(max(mark, 0), 1))
                }
            }
            .frame(height: 6)
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Ink.ink)
                .frame(width: 24, alignment: .trailing)
        }
    }
}

/// The one big on/off control. Green when Hush is working, red when it's paused.
private struct PowerCard: View {
    @Binding var isOn: Bool
    static let green = Color(red: 0.204, green: 0.780, blue: 0.349) // #34c759
    static let red = Color(red: 1.0, green: 0.231, blue: 0.188)     // #ff3b30

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isOn ? "on" : "off")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-1)
                        .foregroundStyle(isOn ? Self.green : Self.red)
                        .contentTransition(.numericText())
                    Text(isOn ? "lowering music when people talk" : "music stays where you put it")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.ink3)
                }
                Spacer(minLength: 8)
                BigSwitch(isOn: isOn)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke((isOn ? Self.green : Self.red).opacity(0.35), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel("hush")
        .accessibilityValue(isOn ? "on" : "off")
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: isOn)
    }
}

private struct BigSwitch: View {
    var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? PowerCard.green : PowerCard.red)
                .frame(width: 76, height: 42)
            HStack(spacing: 0) {
                if isOn { Text("on").padding(.leading, 12); Spacer() } else { Spacer(); Text("off").padding(.trailing, 10) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 76, height: 42)
            Circle()
                .fill(.white)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .padding(4)
        }
        .frame(width: 76, height: 42)
    }
}

private struct ToggleRow: View {
    var title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Ink.ink)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Ink.ink3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Ink.ink)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(Ink.ink)
                Spacer()
                Text(display).font(.system(size: 12)).monospacedDigit().foregroundStyle(Ink.ink3)
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .tint(Ink.ink)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private struct PillButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Ink.ink)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(configuration.isPressed ? Ink.line : Ink.surface))
            .overlay(Capsule().stroke(Ink.line))
    }
}
