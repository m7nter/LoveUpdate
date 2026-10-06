import SwiftUI
import CoreLocation

struct VaultView: View {
    @StateObject private var cameraVM = CameraViewModel()
    @State private var showCamera = false
    @State private var capturedImage: UIImage?
    @State private var capturedLocation: CLLocation?
    @State private var capturedHeading: CLHeading?
    @State private var showEditor = false
    @State private var showGallery = false
    @State private var showMap = false
    @State private var showNotes = false
    @State private var showSettings = false
    @State private var showVaultLock = false
    @State private var pendingDestination: Destination?
    @State private var openedViaURL = false
    @State private var saveError = false
    var onLock: () -> Void

    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "#1C1C1E").ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 64)).foregroundColor(.orange)
                    Text("Хранилище").font(.title.bold()).foregroundColor(.white)
                    HStack(spacing: 16) {
                        VaultActionButton(icon: "camera.fill", label: "Камера") { showCamera = true }
                        VaultActionButton(icon: "folder.fill", label: "Папки") { requestAccess(to: .gallery) }
                    }
                    HStack(spacing: 16) {
                        VaultActionButton(icon: "map.fill", label: "Карта меток") { requestAccess(to: .map) }
                        VaultActionButton(icon: "note.text", label: "Дневник") { requestAccess(to: .notes) }
                    }
                    Button("Настройки") { showSettings = true }.foregroundColor(.orange)
                    Button("Калькулятор", action: onLock).foregroundColor(.gray)
                }
            }.navigationBarHidden(true)
        }
        .onAppear { LocationManager.shared.requestAndStart() }
        .onReceive(NotificationCenter.default.publisher(for: .openCameraFromURL)) { _ in
            openedViaURL = true; showCamera = true
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            showEditor = false; capturedImage = nil; cameraVM.stopSession()
            if openedViaURL { openedViaURL = false; onLock() }
        }) {
            Group {
                if showEditor, let image = capturedImage {
                    PhotoEditorView(image: image, location: capturedLocation, heading: capturedHeading, onSave: { result in
                        guard save(result) else { return false }
                        showEditor = false; capturedImage = nil
                        if cameraVM.event == nil { showCamera = false }
                        return true
                    }, onDiscard: {
                        showEditor = false; capturedImage = nil
                    })
                } else {
                    CameraScreen(cameraVM: cameraVM, onCapture: receivePhoto)
                }
            }
            .alert("Фото не сохранено", isPresented: $saveError) {
                Button("Повторить сохранение") {
                    if let image = capturedImage, save(image) {
                        capturedImage = nil
                        if cameraVM.event == nil { showCamera = false }
                    } else { saveError = true }
                }
                Button("Отбросить кадр", role: .destructive) { capturedImage = nil }
            } message: { Text("Проверьте свободное место. Кадр события не засчитан.") }
        }
        .fullScreenCover(isPresented: $showGallery) { GalleryView() }
        .fullScreenCover(isPresented: $showNotes) { NotesListView() }
        .fullScreenCover(isPresented: $showMap) { PhotoMapView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showVaultLock) {
            VaultLockView {
                showVaultLock = false
                let destination = pendingDestination
                pendingDestination = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { open(destination) }
            } onCancel: { showVaultLock = false; pendingDestination = nil }
        }
    }

    private func receivePhoto(_ image: UIImage, _ location: CLLocation?, _ heading: CLHeading?) {
        capturedLocation = location; capturedHeading = heading
        if cameraVM.quickMode {
            let label = UserDefaults.standard.string(forKey: "selectedTemplate").flatMap { $0.isEmpty ? nil : $0 }
            let result = WatermarkRenderer.apply(to: image, location: location, heading: heading, labelText: label)
            if save(result) {
                if cameraVM.event == nil { showCamera = false }
            } else { capturedImage = result; saveError = true }
        } else { capturedImage = image; showEditor = true }
    }
    private func save(_ image: UIImage) -> Bool {
        guard FileStorageManager.shared.save(image: image, location: capturedLocation, context: cameraVM.pendingContext) != nil else { return false }
        cameraVM.didSavePhoto()
        return true
    }
    private enum Destination { case gallery, notes, map }
    private func open(_ destination: Destination?) {
        switch destination { case .gallery: showGallery = true; case .notes: showNotes = true; case .map: showMap = true; case .none: break }
    }
    private func requestAccess(to destination: Destination) {
        let store = SettingsStore.shared
        if store.vaultCodeEnabled && !store.vaultCode.isEmpty {
            pendingDestination = destination; showVaultLock = true
        } else { open(destination) }
    }
}

struct VaultActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 32)).foregroundColor(.white)
                Text(label).font(.caption).foregroundColor(.gray)
            }
            .frame(width: 130, height: 100).background(Color(hex: "#2C2C2E")).cornerRadius(16)
        }
    }
}
