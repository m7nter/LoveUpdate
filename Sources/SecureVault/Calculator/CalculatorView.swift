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
        GeometryReader { geo in
            let spacing: CGFloat = 8
            let btnSize = (geo.size.width - spacing * 5) / 4

            ZStack {
                Color.black.ignoresSafeArea()

                VStack {
                    HStack {
                        Button {
                            showHistory = true
                        } label: {
                            Image(systemName: "clock")
                                .font(.system(size: 22, weight: .regular))
                                .foregroundColor(.white.opacity(0.8))
                                .frame(width: 44, height: 44)
                        }
                        .padding(.leading, 16)

                        Spacer()

                        Button {
                        } label: {
                            Image(systemName: "calculator")
                                .font(.system(size: 22, weight: .regular))
                                .foregroundColor(.white.opacity(0.8))
                                .frame(width: 44, height: 44)
                        }
                        .padding(.trailing, 16)
                    }
                    .padding(.top, geo.safeAreaInsets.top + 48)
                    Spacer()
                }

                VStack(spacing: 0) {
                    Spacer()

                    if !vm.expression.isEmpty {
                        Text(vm.expression)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }

                    Text(vm.display)
                        .font(.system(size: 72, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)

                    VStack(spacing: spacing) {
                        ForEach(buttons, id: \.self) { row in
                            HStack(spacing: spacing) {
                                ForEach(row, id: \.self) { btn in
                                    CalculatorButton(
                                        title: btn == "CLEAR" ? vm.clearButtonTitle : btn,
                                        vm: vm,
                                        size: btnSize,
                                        spacing: spacing
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, spacing)
                    .padding(.bottom, geo.safeAreaInsets.bottom + 48)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: vm.shouldUnlock) { val in
            if val { onUnlock() }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(history: vm.history)
        }
    }
}

struct CalculatorButton: View {
    let title: String
    @ObservedObject var vm: CalculatorViewModel
    let size: CGFloat
    let spacing: CGFloat

    private var bgColor: Color {
        switch title {
        case "⌫", "AC", "C", "%", "+/−":
            return Color(red: 0.33, green: 0.33, blue: 0.33)
        case "÷", "×", "−", "+", "=":
            return Color(red: 1.0, green: 0.62, blue: 0.04)
        default:
            return Color(red: 0.18, green: 0.18, blue: 0.18)
        }
    }

    private var label: some View {
        Group {
            switch title {
            case "⌫":
                Image(systemName: "delete.left")
                    .font(.system(size: size * 0.32, weight: .regular))
                    .foregroundColor(.white)
            case "=":
                Text("=")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundColor(.white)
            case "÷", "×", "−", "+":
                Text(title)
                    .font(.system(size: size * 0.42, weight: .regular))
                    .foregroundColor(.white)
            default:
                Text(title)
                    .font(.system(size: size * 0.36, weight: .regular))
                    .foregroundColor(.white)
            }
        }
    }

    private func playClick() {
        switch title {
        case "⌫":
            AudioServicesPlaySystemSound(1155)
        case "AC", "C", "+/−", "%":
            AudioServicesPlaySystemSound(1156)
        default:
            AudioServicesPlaySystemSound(1123)
        }
    }

    var body: some View {
        Button {
            playClick()
            vm.tap(title)
        } label: {
            label
                .frame(width: size, height: size)
                .background(bgColor)
                .clipShape(Circle())
        }
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
        NavigationView {
            List {
                if history.isEmpty {
                    Text("История пуста")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(history.reversed(), id: \.self) { item in
                        Text(item)
                            .font(.system(size: 16, design: .monospaced))
                    }
                }
            }
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundColor(.orange)
                }
            }
        }
    }
}
