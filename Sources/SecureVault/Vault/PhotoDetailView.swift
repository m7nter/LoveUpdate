import SwiftUI

struct PhotoDetailView: View {
    let urls: [URL]
    let initialIndex: Int
    let onDelete: (URL) -> Void

    @Environment(\.dismiss) var dismiss
    @State private var currentIndex: Int
    @State private var showEditor = false
    @State private var showDeleteConfirm = false
    @State private var showNoteEditor = false
    @State private var noteText: String = ""
    @State private var refreshToken = UUID()
    private let accessGeneration = VaultGate.shared.generation

    init(urls: [URL], initialIndex: Int, onDelete: @escaping (URL) -> Void) {
        self.urls = urls
        self.initialIndex = initialIndex
        self.onDelete = onDelete
        self._currentIndex = State(initialValue: initialIndex)
    }

    private var currentURL: URL? {
        guard !urls.isEmpty else { return nil }
        return urls[min(max(currentIndex, 0), urls.count - 1)]
    }

    private var hasNote: Bool {
        !(currentURL.flatMap { FileStorageManager.shared.loadMeta(for: $0)?.note } ?? "").isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    PhotoPageView(url: url, refreshToken: refreshToken)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button("Закрыть") { dismiss() }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                    Spacer()
                    if urls.count > 1 {
                        Text("\(currentIndex + 1) из \(urls.count)")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(8)
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        Button {
                            guard let url = currentURL else { dismiss(); return }
                            noteText = FileStorageManager.shared.loadMeta(for: url)?.note ?? ""
                            showNoteEditor = true
                        } label: {
                            Image(systemName: hasNote ? "note.text" : "note")
                                .foregroundColor(hasNote ? .orange : .white)
                                .padding(10)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        Button { showEditor = true } label: {
                            Image(systemName: "pencil")
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                                .padding(10)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 60)

                Text(currentURL.map { FileStorageManager.shared.title(for: $0) } ?? "Фото удалено")
                    .font(.caption).foregroundColor(.white)
                    .padding(8).background(Color.black.opacity(0.6)).cornerRadius(8)

                if hasNote {
                    HStack {
                        Image(systemName: "note.text")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(currentURL.flatMap { FileStorageManager.shared.loadMeta(for: $0)?.note } ?? "")
                            .font(.caption)
                            .foregroundColor(.white)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                Spacer()
            }
            .allowsHitTesting(true)
        }
        .sheet(isPresented: $showEditor) {
            if let url = currentURL, let img = FileStorageManager.shared.loadImage(at: url) {
                GalleryEditorView(image: img, url: url) { _ in
                    refreshToken = UUID()
                }
            }
        }
        .sheet(isPresented: $showNoteEditor) {
            PhotoNoteEditorView(text: noteText) { newText in
                guard let url = currentURL else { return false }
                let saved = FileStorageManager.shared.updateNote(for: url, note: newText, generation: accessGeneration)
                if saved { refreshToken = UUID() }
                return saved
            }
        }
        .alert("Удалить фото?", isPresented: $showDeleteConfirm) {
            Button("Удалить", role: .destructive) {
                guard let deletingURL = currentURL else { dismiss(); return }
                onDelete(deletingURL)
                dismiss()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это действие нельзя отменить.")
        }
        .onChange(of: urls) { if $0.isEmpty { dismiss() } }
    }
}

private struct PhotoPageView: View {
    let url: URL
    let refreshToken: UUID
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { load() }
        .onChange(of: refreshToken) { _ in load() }
    }

    private func load() {
        image = FileStorageManager.shared.loadImage(at: url)
    }
}

struct PhotoNoteEditorView: View {
    let text: String
    let onSave: (String) -> Bool
    @Environment(\.dismiss) var dismiss
    @State private var noteText: String = ""
    @State private var saveError = false

    var body: some View {
        NavigationView {
            Form {
                Section("Заметка к фото") {
                    TextEditor(text: $noteText)
                        .frame(minHeight: 200)
                }
            }
            .navigationTitle("Заметка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(.red)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Сохранить") {
                        if onSave(noteText) { dismiss() }
                        else { saveError = true }
                    }
                    .foregroundColor(.orange)
                }
            }
        }
        .onAppear { noteText = text }
        .alert("Заметка не сохранена", isPresented: $saveError) {
            Button("Закрыть", role: .cancel) {}
        } message: { Text("Проверьте свободное место и повторите сохранение.") }
    }
}
