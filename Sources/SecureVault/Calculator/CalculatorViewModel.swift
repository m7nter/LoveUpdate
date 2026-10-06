import Foundation
import Combine

class CalculatorViewModel: ObservableObject {
    @Published var display: String = "0"
    @Published var expression: String = ""
    @Published var shouldUnlock: Bool = false
    @Published var history: [String] = []

    private var currentInput: String = ""
    private var storedValue: Double = 0
    private var currentOperator: String? = nil
    private var shouldResetDisplay = false
    private var lastOperator: String? = nil
    private var lastOperand: Double = 0

    var clearButtonTitle: String {
        currentInput.isEmpty && display == "0" ? "AC" : "C"
    }

    func tap(_ symbol: String) {
        switch symbol {
        case "0"..."9":
            handleDigit(symbol)
        case ",", ".":
            handleDigit(".")
        case "+", "−", "×", "÷":
            handleOperator(symbol)
        case "=":
            handleEquals()
        case "AC":
            reset()
        case "C":
            clearCurrent()
        case "⌫":
            handleBackspace()
        case "+/−":
            toggleSign()
        case "%":
            handlePercent()
        default:
            break
        }
    }

    private func clearCurrent() {
        currentInput = ""
        display = "0"
    }

    private func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.decimalSeparator = ","
        formatter.maximumFractionDigits = 6
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? formatResult(value)
    }

    private func handleDigit(_ d: String) {
        if d == "." && currentInput.contains(".") { return }
        if shouldResetDisplay {
            if currentOperator == nil { lastOperator = nil; lastOperand = 0 }
            currentInput = d == "." ? "0." : d
            shouldResetDisplay = false
        } else {
            if currentInput == "0" && d != "." {
                currentInput = d
            } else {
                if currentInput.count < 9 { currentInput += d }
            }
        }
        if let val = Double(currentInput) {
            display = formatted(val)
        } else {
            display = currentInput.replacingOccurrences(of: ".", with: ",")
        }
    }

    private func handleBackspace() {
        if !currentInput.isEmpty {
            currentInput.removeLast()
            if currentInput.isEmpty || currentInput == "-" { currentInput = "0" }
            if let val = Double(currentInput) {
                display = formatted(val)
            } else {
                display = currentInput.replacingOccurrences(of: ".", with: ",")
            }
        }
    }

    private func handleOperator(_ op: String) {
        if !currentInput.isEmpty {
            storedValue = Double(currentInput) ?? 0
        }
        expression = "\(formatted(storedValue))  \(op)"
        currentOperator = op
        shouldResetDisplay = true
        currentInput = ""
    }

    private func handleEquals() {
        let store = SettingsStore.shared
        let input = currentInput.isEmpty ? display : currentInput

        let directEntry = currentOperator == nil && lastOperator == nil && !currentInput.isEmpty
        if directEntry && store.kamikazeCodeEnabled && !store.kamikazeCode.isEmpty && input == store.kamikazeCode {
            let urls = FileStorageManager.shared.loadAll()
            for url in urls { FileStorageManager.shared.delete(url: url) }
            reset()
            return
        }

        if directEntry && input == store.mainCode {
            shouldUnlock = true
            reset()
            return
        }

        guard let op = currentOperator,
              let rhs = Double(currentInput) else {
            // Повторное нажатие "=" — повторяем последнюю операцию
            if let op = lastOperator {
                let rhs = lastOperand
                let result: Double
                switch op {
                case "+": result = storedValue + rhs
                case "−": result = storedValue - rhs
                case "×": result = storedValue * rhs
                case "÷": result = rhs != 0 ? storedValue / rhs : 0
                default: return
                }

                let entry = "\(formatted(storedValue))  \(op)  \(formatted(rhs)) = \(formatted(result))"
                history.append(entry)
                expression = "\(formatted(storedValue))  \(op)  \(formatted(rhs))"

                storedValue = result
                currentInput = formatResult(result)
                display = formatted(result)
                shouldResetDisplay = true
            }
            return
        }

        lastOperator = op
        lastOperand = rhs

        let result: Double
        switch op {
        case "+": result = storedValue + rhs
        case "−": result = storedValue - rhs
        case "×": result = storedValue * rhs
        case "÷": result = rhs != 0 ? storedValue / rhs : 0
        default: return
        }

        let entry = "\(formatted(storedValue))  \(op)  \(formatted(rhs)) = \(formatted(result))"
        history.append(entry)
        expression = "\(formatted(storedValue))  \(op)  \(formatted(rhs))"

        storedValue = result
        currentInput = formatResult(result)
        display = formatted(result)
        currentOperator = nil
        shouldResetDisplay = true
    }

    private func formatResult(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 && abs(v) < 1e9 {
            return String(Int(v))
        }
        return String(format: "%.6g", v)
    }

    private func reset() {
        display = "0"
        expression = ""
        currentInput = ""
        storedValue = 0
        currentOperator = nil
        shouldResetDisplay = false
        lastOperator = nil
        lastOperand = 0
    }

    private func toggleSign() {
        if let v = Double(currentInput) {
            let toggled = -v
            currentInput = formatResult(toggled)
            display = formatted(toggled)
        }
    }

    private func handlePercent() {
        guard let v = Double(currentInput) else { return }
        let pct: Double
        if let op = currentOperator, (op == "+" || op == "−") {
            // Процент от первого числа (как в стандартном калькуляторе)
            pct = storedValue * (v / 100)
        } else {
            pct = v / 100
        }
        currentInput = formatResult(pct)
        display = formatted(pct)
    }
}
