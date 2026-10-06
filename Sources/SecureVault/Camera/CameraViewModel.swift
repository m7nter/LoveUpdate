import AVFoundation
import UIKit
import Combine
import CoreLocation

final class CameraViewModel: NSObject, ObservableObject {
    @Published var capturedImage: UIImage?
    @Published var error: String?
    @Published var isTorchOn = false
    @Published var quickMode = false
    @Published var isCapturing = false
    @Published var zoom: Double = 1
    @Published var minimumZoom: Double = 1
    @Published var maximumZoom: Double = 2
    @Published var event: CaptureContext?
    private(set) var pendingContext: CaptureContext?
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "SecureVault.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var zoomMultiplier: Double = 1
    private var configured = false
    private var wantsSession = false
    private var completion: ((UIImage, CLLocation?, CLHeading?) -> Void)?
    private var shotLocation: CLLocation?
    private var shotHeading: CLHeading?
    private let ownerGeneration = VaultGate.shared.generation

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "pendingCaptureEvent") {
            event = try? JSONDecoder().decode(CaptureContext.self, from: data)
            reconcileEvent()
        }
    }

    func startSession() {
        guard (try? VaultGate.shared.withAccess(generation: ownerGeneration) { true }) == true else { return }
        queue.async { self.wantsSession = true }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                if allowed { self.configureAndStart() }
                else { self.reportError("Разрешите доступ к камере в настройках iPhone") }
            }
        default: reportError("Разрешите доступ к камере в настройках iPhone")
        }
    }

    private func configureAndStart() {
        queue.async {
            guard self.wantsSession else { return }
            guard (try? VaultGate.shared.withAccess(generation: self.ownerGeneration) { true }) == true else { return }
            if !self.configured {
                guard let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    self.reportError("Камера недоступна"); return
                }
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    guard self.session.canAddInput(input), self.session.canAddOutput(self.photoOutput) else {
                        self.reportError("Не удалось настроить камеру"); return
                    }
                    self.session.sessionPreset = .photo
                    self.session.addInput(input)
                    self.session.addOutput(self.photoOutput)
                    self.device = device
                    let ultraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
                    self.zoomMultiplier = ultraWide ? 1 / (device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 2) : 1
                    let lower = max(0.5, Double(device.minAvailableVideoZoomFactor) * self.zoomMultiplier)
                    let upper = min(2, Double(device.maxAvailableVideoZoomFactor) * self.zoomMultiplier)
                    try device.lockForConfiguration()
                    device.videoZoomFactor = CGFloat(min(upper, max(lower, 1)) / self.zoomMultiplier)
                    device.unlockForConfiguration()
                    self.configured = true
                    DispatchQueue.main.async {
                        self.minimumZoom = lower; self.maximumZoom = max(lower, upper)
                        self.zoom = min(upper, max(lower, 1))
                    }
                } catch { self.reportError("Ошибка камеры: \(error.localizedDescription)"); return }
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stopSession() {
        queue.async {
            self.wantsSession = false
            if let device = self.device, device.hasTorch {
                do { try device.lockForConfiguration(); device.torchMode = .off; device.unlockForConfiguration() }
                catch { self.reportError("Не удалось отключить фонарик") }
            }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isTorchOn = false }
        }
    }

    func setZoom(_ value: Double) {
        let clamped = min(maximumZoom, max(minimumZoom, value))
        zoom = clamped
        queue.async {
            guard let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                let factor = CGFloat(clamped / self.zoomMultiplier)
                device.ramp(toVideoZoomFactor: min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, factor)), withRate: 6)
                device.unlockForConfiguration()
            } catch { self.reportError("Не удалось изменить увеличение") }
        }
    }

    func toggleTorch() {
        queue.async {
            guard let device = self.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                let enabled = device.torchMode != .on
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.isTorchOn = enabled }
            } catch { self.reportError("Фонарик недоступен") }
        }
    }

    func capturePhoto(completion: @escaping (UIImage, CLLocation?, CLHeading?) -> Void) {
        guard (try? VaultGate.shared.withAccess(generation: ownerGeneration) { true }) == true else { return }
        guard !isCapturing, session.isRunning else { return }
        reconcileEvent()
        if event == nil { event = FileStorageManager.shared.newEvent(); persistEvent() }
        pendingContext = event
        pendingContext?.capturedAt = Date()
        isCapturing = true
        self.completion = completion
        let location = LocationManager.shared.location
        shotLocation = location.flatMap { $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 15 ? $0 : nil }
        shotHeading = LocationManager.shared.heading
        queue.async { self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self) }
    }

    func didSavePhoto() {
        guard var current = event else { return }
        if current.index >= current.expectedCount {
            FileStorageManager.shared.completeEvent(current.eventID)
            event = nil
        }
        else { current.index += 1; event = current }
        pendingContext = nil
        persistEvent()
    }

    func finishEvent() {
        if let current = event { FileStorageManager.shared.completeEvent(current.eventID) }
        event = nil; pendingContext = nil; persistEvent()
    }
    private func reconcileEvent() {
        guard var current = event else { return }
        guard current.generation == nil || current.generation == ownerGeneration else { event = nil; persistEvent(); return }
        current.generation = ownerGeneration
        let storage = FileStorageManager.shared
        let members = storage.loadAll().filter { storage.loadMeta(for: $0)?.eventID == current.eventID }
        if let first = members.first {
            current.folder = storage.folder(for: first)
            let lastIndex = members.compactMap { storage.loadMeta(for: $0)?.eventIndex }.max() ?? 0
            current.index = max(current.index, lastIndex + 1)
            if current.index > current.expectedCount { event = nil }
            else { event = current }
        } else if current.index > 1 { event = nil }
        else { event = current }
        persistEvent()
    }
    private func persistEvent() {
        if let event = event, let data = try? JSONEncoder().encode(event) {
            UserDefaults.standard.set(data, forKey: "pendingCaptureEvent")
        } else { UserDefaults.standard.removeObject(forKey: "pendingCaptureEvent") }
    }
    private func reportError(_ message: String) { DispatchQueue.main.async { self.error = message } }
}

extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            self.isCapturing = false
            guard (try? VaultGate.shared.withAccess(generation: self.ownerGeneration) { true }) == true else {
                self.completion = nil; self.shotLocation = nil; self.shotHeading = nil; self.pendingContext = nil; self.event = nil
                return
            }
            guard error == nil, let image = image else {
                self.error = "Не удалось снять фото. Повторите кадр."; return
            }
            self.completion?(image, self.shotLocation, self.shotHeading)
            self.completion = nil
        }
    }
}
