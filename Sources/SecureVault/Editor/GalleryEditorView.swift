import SwiftUI

struct GalleryEditorView: View {
    let image: UIImage
    let url: URL
    let onSaved: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss
    var body: some View {
        PhotoEditingView(image: image, addWatermark: false, location: nil, heading: nil, onSave: { result in
            guard FileStorageManager.shared.overwrite(image: result, at: url) else { return false }
            onSaved(result)
            dismiss()
            return true
        }, onCancel: { dismiss() })
    }
}
