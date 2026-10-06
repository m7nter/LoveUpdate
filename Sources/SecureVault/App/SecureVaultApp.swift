import SwiftUI

@main
struct SecureVaultApp: App {
    @State private var isUnlocked = false
    @State private var backgroundTime: Date? = nil
    @State private var inactivityTimer: Timer? = nil
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var lifecycle = VaultLifecycle.shared

    init() {
        setupCrashLogging()
        VaultLifecycle.shared.resumePendingErase()
    }

    var body: some Scene {
        WindowGroup {
            Group {
            if lifecycle.blocksUI {
                VaultUnavailableView(lifecycle: lifecycle)
            } else {
            RootView(
                isUnlocked: $isUnlocked,
                onStartTimer: startTimer,
                onStopTimer: stopTimer
            )
            .id(lifecycle.generation)
            }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vaultWillErase)) { _ in
                stopTimer(); isUnlocked = false
                VolumeButtonHandler.shared.stop()
                LocationManager.shared.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .blackScreenChanged)) { notification in
                if notification.object as? Bool == true { stopTimer() }
                else if isUnlocked { startTimer() }
            }
            .onOpenURL { url in
                guard !lifecycle.blocksUI, let action = ActionButtonRouter.resolve(url,
                    mode: SettingsStore.shared.actionButtonMode, token: SettingsStore.shared.actionButtonToken) else { return }
                if action.destructive { stopTimer(); isUnlocked = false; lifecycle.erase(action); return }
                isUnlocked = true
                startTimer()
                let epoch = VaultGate.shared.generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard epoch == VaultGate.shared.generation, !lifecycle.blocksUI,
                          SettingsStore.shared.actionButtonMode == .camera else { return }
                    NotificationCenter.default.post(name: .openCameraFromURL, object: nil)
                }
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background, .inactive:
                    backgroundTime = Date()
                    stopTimer()
                    if SettingsStore.shared.lockOnBackground && isUnlocked {
                        isUnlocked = false
                    }
                case .active:
                    if let bg = backgroundTime, !SettingsStore.shared.lockOnBackground {
                        let elapsed = Date().timeIntervalSince(bg)
                        let timeout = SettingsStore.shared.autoLockTimeout
                        if timeout > 0 && elapsed >= Double(timeout) && isUnlocked {
                            isUnlocked = false
                        } else if isUnlocked {
                            startTimer()
                        }
                    }
                    backgroundTime = nil
                default:
                    break
                }
            }
        }
    }

    private func startTimer() {
        stopTimer()
        guard !lifecycle.blocksUI else { return }
        let timeout = SettingsStore.shared.autoLockTimeout
        guard timeout > 0, !SettingsStore.shared.lockOnBackground else { return }
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: Double(timeout),
                                               repeats: false) { _ in
            DispatchQueue.main.async {
                isUnlocked = false
            }
        }
    }

    private func stopTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    private func setupCrashLogging() {
        NSSetUncaughtExceptionHandler { exception in
            guard (try? VaultGate.shared.withAccess { true }) == true else { return }
            let log = """
            CRASH: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")
            Stack: \(exception.callStackSymbols.joined(separator: "\n"))
            """
            let paths = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
            if let cachePath = paths.first {
                let logPath = cachePath + "/crash.log"
                try? log.write(toFile: logPath, atomically: true, encoding: .utf8)
            }
        }
    }
}

struct RootView: View {
    @Binding var isUnlocked: Bool
    let onStartTimer: () -> Void
    let onStopTimer: () -> Void

    var body: some View {
        if isUnlocked {
            VaultView(onLock: {
                isUnlocked = false
                onStopTimer()
            })
        } else {
            CalculatorView(onUnlock: {
                isUnlocked = true
                onStartTimer()
            })
        }
    }
}
