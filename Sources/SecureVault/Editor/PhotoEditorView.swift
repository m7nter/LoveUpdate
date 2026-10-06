import SwiftUI
import CoreLocation

class LabelTemplatesStore: ObservableObject {
    @Published var templates: [String] {
        didSet { UserDefaults.standard.set(templates, forKey: "labelTemplates") }
    }
    @Published var selected: String {
        didSet { UserDefaults.standard.set(selected, forKey: "selectedTemplate") }
    }
    init() {
        templates = UserDefaults.standard.stringArray(forKey: "labelTemplates") ?? []
        selected = UserDefaults.standard.string(forKey: "selectedTemplate") ?? ""
    }
}

struct PhotoEditorView: View {
    let image: UIImage
    let location: CLLocation?
    let heading: CLHeading?
    let onSave: (UIImage) -> Bool
    let onDiscard: () -> Void
    var body: some View {
        PhotoEditingView(image: image, addWatermark: true, location: location, heading: heading,
                         onSave: onSave, onCancel: onDiscard)
    }
}

struct PhotoEditingView: View {
    let image: UIImage
    let addWatermark: Bool
    let location: CLLocation?
    let heading: CLHeading?
    let onSave: (UIImage) -> Bool
    let onCancel: () -> Void
    private let accessGeneration = VaultGate.shared.generation
    init(image: UIImage, addWatermark: Bool, location: CLLocation?, heading: CLHeading?,
         onSave: @escaping (UIImage) -> Bool, onCancel: @escaping () -> Void) {
        self.image = image; self.addWatermark = addWatermark
        self.location = location; self.heading = heading
        self.onSave = onSave; self.onCancel = onCancel
    }
    @StateObject private var templates = LabelTemplatesStore()
    @State private var shapes: [DrawnShape] = []
    @State private var tool: DrawingTool = .arrow
    @State private var color: Color = .red
    @State private var zoom: Double = 1
    @State private var text = ""
    @State private var textSize: Double = 0.045
    @State private var brushWidth: Double = 0.08
    @State private var showTemplates = false
    @State private var showText = false
    @State private var isSaving = false
    @State private var saveError = false

    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                ZoomAnnotationCanvas(image: image, shapes: $shapes, zoom: $zoom,
                                     tool: tool, color: color, text: text,
                                     brushWidth: CGFloat(brushWidth), textSize: CGFloat(textSize))
                    .overlay { if isSaving { ProgressView().tint(.orange) } }
                    .allowsHitTesting(!isSaving)
                HStack {
                    Image(systemName: "magnifyingglass")
                    Slider(value: $zoom, in: 1...8)
                    Text(String(format: "%.1f×", zoom)).monospacedDigit()
                    Button("Сброс") { zoom = 1 }
                }
                .padding(.horizontal)
                if tool == .blur {
                    HStack {
                        Text("Кисть")
                        Slider(value: $brushWidth, in: 0.015...0.2)
                    }.padding(.horizontal)
                }
                Text(tool == .text ? "Коснитесь фото, чтобы разместить текст. Два пальца — перемещение и масштаб." : "Один палец — пометки. Два пальца — перемещение и масштаб.")
                    .font(.caption2).foregroundColor(.secondary).padding(.horizontal)
                HStack(spacing: 18) {
                    toolButton("arrow.up.right", .arrow, "Стрелка")
                    toolButton("oval", .oval, "Овал")
                    Button {
                        tool = .text; showText = true
                    } label: { Image(systemName: "textformat").foregroundColor(tool == .text ? .orange : .white) }
                    .accessibilityLabel("Текст на фото")
                    toolButton("drop.halffull", .blur, "Кисть размытия")
                    Spacer()
                    Button { if !shapes.isEmpty { shapes.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(shapes.isEmpty).accessibilityLabel("Отменить последнюю пометку")
                    if addWatermark {
                        Button { showTemplates = true } label: { Image(systemName: "text.badge.plus") }
                            .accessibilityLabel("Шаблон подписи")
                    }
                }.padding(.horizontal)
                HStack(spacing: 20) {
                    ForEach(["red", "yellow", "white", "black"], id: \.self) { name in
                        let value = colorValue(name)
                        Circle().fill(value).frame(width: 26, height: 26)
                            .overlay(Circle().stroke(color == value ? Color.orange : Color.gray, lineWidth: 2))
                            .onTapGesture { color = value }
                    }
                    Spacer()
                    if tool == .text { Button("Изменить текст") { showText = true } }
                }.padding(.horizontal).padding(.bottom, 8)
            }
            .background(Color.black)
            .foregroundColor(.white)
            .disabled(isSaving)
            .navigationTitle("Редактор")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена", action: onCancel).disabled(isSaving) }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Сохранить", action: save).disabled(isSaving) }
            }
        }
        .sheet(isPresented: $showTemplates) { LabelTemplateSheet(store: templates) }
        .sheet(isPresented: $showText) {
            NavigationView {
                Form {
                    Section("Текст на фото") { TextEditor(text: $text).frame(minHeight: 130) }
                    Section("Размер текста") { Slider(value: $textSize, in: 0.02...0.12) }
                    Text("После закрытия коснитесь нужного места на снимке. Повторное касание добавляет ещё одну надпись; кнопка отмены удаляет последнюю.")
                }
                .navigationTitle("Надпись")
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { showText = false } } }
            }
        }
        .alert("Не удалось сохранить фото", isPresented: $saveError) {
            Button("Закрыть", role: .cancel) {}
        } message: { Text("Пометки остались в редакторе. Проверьте свободное место и повторите сохранение.") }
    }

    private func colorValue(_ name: String) -> Color {
        switch name { case "yellow": return .yellow; case "white": return .white; case "black": return .black; default: return .red }
    }
    private func toolButton(_ icon: String, _ value: DrawingTool, _ label: String) -> some View {
        Button { tool = value } label: { Image(systemName: icon).foregroundColor(tool == value ? .orange : .white) }
            .accessibilityLabel(label)
    }
    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let original = image
        let annotations = shapes
        let label = templates.selected.isEmpty ? nil : templates.selected
        let watermark = addWatermark
        let loc = location, hdg = heading
        let epoch = accessGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let base = watermark ? WatermarkRenderer.apply(to: original, location: loc, heading: hdg, labelText: label) : original
            let result = AnnotationRenderer.render(image: base, shapes: annotations)
            DispatchQueue.main.async {
                isSaving = false
                if (try? VaultGate.shared.withAccess(generation: epoch) { onSave(result) }) != true { saveError = true }
            }
        }
    }
}

struct LabelTemplateSheet: View {
    @ObservedObject var store: LabelTemplatesStore
    @Environment(\.dismiss) var dismiss
    @State private var newTemplate = ""
    var body: some View {
        NavigationView {
            List {
                Section {
                    Button("Отключить подпись") { store.selected = ""; dismiss() }
                    ForEach(store.templates, id: \.self) { template in
                        Button {
                            store.selected = template; dismiss()
                        } label: {
                            HStack {
                                Text(template)
                                Spacer()
                                if store.selected == template { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.templates.remove(atOffsets: offsets)
                        if !store.templates.contains(store.selected) { store.selected = "" }
                    }
                }
                Section("Новый шаблон") {
                    TextField("Подпись", text: $newTemplate)
                    Button("Добавить") {
                        let value = newTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        if !store.templates.contains(value) { store.templates.append(value) }
                        store.selected = value; dismiss()
                    }
                }
            }
            .navigationTitle("Подписи")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}
