import SwiftUI
import AudioToolbox

struct CalculatorView: View {
    @StateObject private var vm = CalculatorViewModel()
    var onUnlock: () -> Void
    @State private var showHistory = false

    private let buttons: [[String]] = [
        ["⌫", "CLEAR", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"],
        ["+/−", "0", ",", "="]
    ]

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = min(11, max(8, geometry.size.width * 0.024))
            let sideInset: CGFloat = min(20, max(14, geometry.size.width * 0.04))
            let widthForKey = (geometry.size.width - sideInset * 2 - gap * 3) / 4
            let heightForKey = (geometry.size.height - 48 - 96 - 12 - gap * 4) / 5
            let keySize = max(32, min(widthForKey, heightForKey))

            VStack(spacing: 0) {
                toolbar
                    .frame(height: 48)
                    .padding(.horizontal, sideInset)

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    if !vm.expression.isEmpty {
                        Text(vm.expression)
                            .font(.system(size: 21, weight: .regular))
                            .foregroundColor(.white.opacity(0.48))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    Text(vm.display)
                        .font(.system(size: min(78, max(38, keySize * 0.92)), weight: .light))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.36)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, sideInset + 4)
                .frame(minHeight: 84, alignment: .bottom)
                .padding(.bottom, 12)

                VStack(spacing: gap) {
                    ForEach(buttons.indices, id: \.self) { rowIndex in
                        HStack(spacing: gap) {
                            ForEach(buttons[rowIndex], id: \.self) { symbol in
                                CalculatorButton(
                                    title: symbol == "CLEAR" ? vm.clearButtonTitle : symbol,
                                    vm: vm,
                                    size: keySize
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: vm.shouldUnlock) { value in
            if value {
                vm.shouldUnlock = false
                onUnlock()
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(history: vm.history)
        }
    }

    private var toolbar: some View {
        HStack {
            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(CalculatorTopSurface())
            .accessibilityLabel("История")

            Spacer()

            Menu {
                Button {} label: {
                    Label("Основной", systemImage: "checkmark")
                }
                .disabled(true)
                Button {
                    showHistory = true
                } label: {
                    Label("История", systemImage: "clock")
                }
            } label: {
                Image(systemName: "calculator")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(CalculatorTopSurface())
            .accessibilityLabel("Режим калькулятора")
        }
        .foregroundColor(.white)
    }
}

// Keep the dynamic material on the small navigation controls. It is costly
// and distracting when applied to every key in this frequently used grid.
private struct CalculatorTopSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
        #else
        content.background(.ultraThinMaterial, in: Circle())
        #endif
    }
}

private struct CalculatorKeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CalculatorButton: View {
    let title: String
    @ObservedObject var vm: CalculatorViewModel
    let size: CGFloat

    private var isOperator: Bool {
        ["÷", "×", "−", "+", "="].contains(title)
    }

    private var backgroundColor: Color {
        if isOperator { return Color(red: 1, green: 0.62, blue: 0.04) }
        if ["⌫", "AC", "C", "%", "+/−"].contains(title) {
            return Color(red: 0.35, green: 0.35, blue: 0.36)
        }
        return Color(red: 0.19, green: 0.19, blue: 0.20)
    }

    private var label: some View {
        Group {
            if title == "⌫" {
                Image(systemName: "delete.left")
                    .font(.system(size: size * 0.31, weight: .regular))
            } else {
                Text(title == "+/−" ? "±" : title)
                    .font(.system(
                        size: size * (title == "AC" || title == "C" ? 0.33 : 0.43),
                        weight: title == "=" ? .medium : .regular
                    ))
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
            }
        }
        .foregroundColor(.white)
    }

    private func playClick() {
        switch title {
        case "⌫": AudioServicesPlaySystemSound(1155)
        case "AC", "C", "+/−", "%": AudioServicesPlaySystemSound(1156)
        default: AudioServicesPlaySystemSound(1123)
        }
    }

    var body: some View {
        Button {
            playClick()
            vm.tap(title)
        } label: {
            label
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(backgroundColor)
                        .overlay {
                            Circle().strokeBorder(Color.white.opacity(0.075), lineWidth: 0.8)
                        }
                }
                .contentShape(Circle())
        }
        .buttonStyle(CalculatorKeyPressStyle())
        .accessibilityLabel(title == "+/−" ? "Сменить знак" : title)
        .simultaneousGesture(
            title == "⌫" ?
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    playClick()
                    vm.tap("AC")
                }
            : nil
        )
    }
}

struct HistoryView: View {
    let history: [String]
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                if history.isEmpty {
                    Text("История пуста")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(history.indices.reversed(), id: \.self) { index in
                        Text(history[index])
                            .font(.system(size: 16, design: .monospaced))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundColor(.orange)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
