import SwiftUI
import AVFoundation
import Photos

// MARK: - FaceFind — on-device face recognition (Vision + SQLite)
//
// MENU UI: home screen with three big menu buttons —
//   ENROLMENT | RECOGNITION | SETTINGS
// Each opens its own full screen via NavigationStack push. Recognition holds
// the live camera + overlay; Enrolment the photo→faceprint→SQLite flow;
// Settings the tunables (threshold, confirm hits, frame skip, history).

// URL: Identifiable for .sheet(item:)
extension URL: Identifiable { public var id: String { absoluteString } }

struct ContentView: View {
    @State private var path: [Screen] = []
    @StateObject private var status = StatusBox()

    enum Screen: Hashable {
        case enrolment, recognition, settings
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Image(systemName: "faceid")
                        .font(.system(size: 64))
                        .foregroundStyle(.green)
                    Text("FaceFind")
                        .font(.largeTitle.bold())
                    Text("on-device face recognition")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 30)

                Spacer()

                MenuButton(title: "enrolment",
                           subtitle: status.peopleCount == 0
                               ? "no one enrolled yet — tap to add people"
                               : "\(status.peopleCount) people enrolled",
                           icon: "person.badge.plus",
                           color: .blue) { path.append(.enrolment) }

                MenuButton(title: "recognition",
                           subtitle: "live camera — recognize enrolled people",
                           icon: "eye.fill",
                           color: .green) { path.append(.recognition) }

                MenuButton(title: "settings",
                           subtitle: "thresholds, frame rate, database",
                           icon: "gearshape.fill",
                           color: .gray) { path.append(.settings) }

                Spacer()
            }
            .padding(.horizontal, 24)
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .enrolment:   EnrolmentView()
                case .recognition: RecognitionView()
                case .settings:    SettingsView()
                }
            }
        }
    }
}

// MARK: big menu button (button-style selection per standing preference)
struct MenuButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(color.opacity(0.35), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// Shared people-count publisher (every screen reads StatusBox)
@MainActor final class StatusBox: ObservableObject {
    @Published var peopleCount = FaceDatabase.shared.people().count
    func refresh() { peopleCount = FaceDatabase.shared.people().count }
}

// MARK: - ENROLMENT screen
struct EnrolmentView: View {
    @StateObject private var status = StatusBox()
    @State private var pickImage: UIImage? = nil
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var name = ""
    @State private var message = ""
    @State private var ok = false
    @State private var busy = false
    @State private var existing: [(name: String, count: Int)] = []

    var body: some View {
        Form {
            Section("new person") {
                TextField("person's name", text: $name)

                // photo source buttons (button style, not checkboxes)
                HStack(spacing: 10) {
                    Button { showPicker = true } label: {
                        Label("library", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)

                    Button { showCamera = true } label: {
                        Label("camera", systemImage: "camera")
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                }

                if let pickImage {
                    Image(uiImage: pickImage)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity)
                }

                Button {
                    enroll()
                } label: {
                    Text(busy ? "embedding faceprint..." : "save faceprint")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pickImage == nil
                          || name.trimmingCharacters(in: .whitespaces).isEmpty
                          || busy)
            }

            if !message.isEmpty {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(ok ? Color.green : Color.red)
                }
            }

            Section("enrolled (\(existing.reduce(0) { $0 + $1.count }) faceprints)") {
                if existing.isEmpty {
                    Text("no one yet").foregroundStyle(.secondary)
                }
                ForEach(existing, id: \.name) { p in
                    LabeledContent(p.name, value: "\(p.count) photo\(p.count == 1 ? "" : "s")")
                }
            }
        }
        .navigationTitle("enrolment")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            existing = FaceDatabase.shared.people()
            status.refresh()
        }
        .sheet(isPresented: $showPicker) { PhotoLibraryPicker(image: $pickImage) }
        .sheet(isPresented: $showCamera) { PhotoCameraPicker(image: $pickImage) }
    }

    private func enroll() {
        let personName = name.trimmingCharacters(in: .whitespaces)
        guard let ui = pickImage, let cg = ui.cgImage else { return }
        busy = true; message = ""; ok = false

        DispatchQueue.global(qos: .userInitiated).async {
            let error = FaceEngine.enroll(image: cg, name: personName, db: FaceDatabase.shared)
            DispatchQueue.main.async {
                busy = false
                if let error {
                    ok = false
                    message = error
                } else {
                    ok = true
                    message = "\(personName) enrolled successfully"
                    LiveFaceScanner.shared.reloadDatabase()   // live matching sees them now
                    pickImage = nil
                    name = ""
                }
                existing = FaceDatabase.shared.people()
                status.refresh()
            }
        }
    }
}

// MARK: - SETTINGS screen
struct SettingsView: View {
    // tunables (persisted; the engine applies them live)
    @AppStorage("thresholdPct") private var thresholdPct = 60       // 0.60 × 100
    @AppStorage("consistentHits") private var consistentHits = 4    // 3–5 spec range
    @AppStorage("processEveryN") private var processEveryN = 3      // every Nth frame
    @AppStorage("historyLen") private var historyLen = 10

    @State private var confirmWipe = false
    @StateObject private var status = StatusBox()
    @State private var confirmDelete: String? = nil
    @State private var existing: [(name: String, count: Int)] = []

    var body: some View {
        Form {
            Section("recognition") {
                Stepper(value: $thresholdPct, in: 40...90, step: 5) {
                    LabeledContent("similarity threshold", value: "\(thresholdPct)%")
                }
                Stepper(value: $consistentHits, in: 3...5) {
                    LabeledContent("confirm after hits", value: "\(consistentHits)")
                }
                Stepper(value: $processEveryN, in: 1...5) {
                    LabeledContent("process every Nth frame", value: "\(processEveryN)")
                }
                Stepper(value: $historyLen, in: 5...20) {
                    LabeledContent("sparkline history", value: "\(historyLen) scores")
                }
            }
            Section("enrolled people") {
                if existing.isEmpty {
                    Text("no one enrolled").foregroundStyle(.secondary)
                }
                ForEach(existing, id: \.name) { p in
                    HStack {
                        LabeledContent(p.name, value: "\(p.count) photo\(p.count == 1 ? "" : "s")")
                        Button(role: .destructive) {
                            confirmDelete = p.name          // double confirm (standing rule)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section("database") {
                LabeledContent("storage", value: "on-device SQLite")
                Button(role: .destructive) { confirmWipe = true } label: {
                    Text("delete all faceprints")
                }
            }
            Section("about") {
                LabeledContent("engine", value: "Apple Vision (on-device)")
                LabeledContent("network", value: "none — nothing leaves the phone")
            }
        }
        .navigationTitle("settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            status.refresh()
            existing = FaceDatabase.shared.people()
        }
        .onChange(of: thresholdPct) { _, _ in LiveFaceScanner.kThreshold = Float(thresholdPct) / 100 }
        .onChange(of: consistentHits) { _, _ in LiveFaceScanner.kConsistentHits = consistentHits }
        .onChange(of: processEveryN) { _, _ in LiveFaceScanner.processEveryNthFrame = processEveryN }
        .onChange(of: historyLen) { _, _ in LiveFaceScanner.historyLen = historyLen }
        .alert("delete \(confirmDelete ?? "")?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } })) {
            Button("delete", role: .destructive) {
                if let n = confirmDelete {
                    FaceDatabase.shared.delete(name: n)
                    LiveFaceScanner.shared.reloadDatabase()
                    existing = FaceDatabase.shared.people()
                    status.refresh()
                }
                confirmDelete = nil
            }
            Button("cancel", role: .cancel) { confirmDelete = nil }
        }
        .alert("delete ALL faceprints?", isPresented: $confirmWipe) {
            Button("delete all", role: .destructive) {
                FaceDatabase.shared.wipeAll()
                LiveFaceScanner.shared.reloadDatabase()
                existing = FaceDatabase.shared.people()
                status.refresh()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("This removes every enrolled person. Cannot be undone.")
        }
    }
}

// MARK: - RECOGNITION screen (live camera + overlay)
struct RecognitionView: View {
    @StateObject private var status = StatusBox()
    @State private var faces: [LiveFaceScanner.FaceView] = []

    var body: some View {
        ZStack {
            CameraPreviewView(session: LiveFaceScanner.shared.session)
                .ignoresSafeArea(edges: .bottom)

            // ---- overlay: one view per tracked face ----
            GeometryReader { geo in
                ForEach(faces, id: \.id) { f in
                    FaceOverlay(face: f, canvas: geo.size)
                }
            }

            if faces.isEmpty {
                VStack {
                    Spacer()
                    Text("no faces tracked — point the camera at someone")
                        .font(.footnote)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 90)
                }
            }
        }
        .overlay(alignment: .top) {
            Text(" \(status.peopleCount) people  ·  every \(LiveFaceScanner.processEveryNthFrame) frames  ·  >\(Int(LiveFaceScanner.kThreshold * 100))% ×\(LiveFaceScanner.kConsistentHits) ")
                .font(.caption2)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 4)
        }
        .navigationTitle("recognition")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            status.refresh()
            LiveFaceScanner.shared.onFaces = { faces = $0 }
            checkPermission()
        }
    }

    private func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            LiveFaceScanner.shared.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok { LiveFaceScanner.shared.start() }
            }
        default:
            break
        }
    }
}

// Box + name + sparkline, positioned over the face
struct FaceOverlay: View {
    let face: LiveFaceScanner.FaceView
    let canvas: CGSize

    // Vision coords (bottom-left origin, normalized) → layer coords (top-left)
    private var rect: CGRect {
        CGRect(x: face.rect.minX * canvas.width,
               y: (1 - face.rect.maxY) * canvas.height,
               width: face.rect.width * canvas.width,
               height: face.rect.height * canvas.height)
    }

    private var color: Color { face.confirmed ? .green : .orange }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .stroke(color, lineWidth: face.confirmed ? 3 : 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            VStack(alignment: .leading, spacing: 3) {
                if face.confirmed, let name = face.name {
                    Text(name)
                        .font(.callout.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(color.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                } else {
                    Text("\(Int(face.similarity * 100))%")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                }
                // rolling similarity history — sparkline (last 10 scores)
                Sparkline(values: face.history, threshold: LiveFaceScanner.kThreshold)
                    .frame(width: 64, height: 22)
            }
            .position(x: max(rect.minX + 40, rect.midX), y: max(24, rect.minY - 26))
        }
        .allowsHitTesting(false)
    }
}

// Tiny bar-chart sparkline of the rolling similarity buffer
struct Sparkline: View {
    let values: [Float]
    let threshold: Float

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(values.enumerated().reversed()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1)
                    .fill(v >= threshold ? Color.green : Color.orange)
                    .frame(width: 4.5, height: CGFloat(max(0.08, min(1, v))) * 22)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }
}

// AVCaptureSession → UIViewRepresentable layer
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewContainer: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewContainer {
        let v = PreviewContainer()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewContainer, context: Context) {}
}

// MARK: - pickers (library + still camera)
import PhotosUI

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = 1
        let p = PHPickerViewController(configuration: cfg)
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoLibraryPicker
        init(_ parent: PhotoLibraryPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            defer { parent.dismiss() }
            guard let item = results.first?.itemProvider,
                  item.canLoadObject(ofClass: UIImage.self)
            else { return }
            item.loadObject(ofClass: UIImage.self) { obj, _ in
                DispatchQueue.main.async { self.parent.image = obj as? UIImage }
            }
        }
    }
}

struct PhotoCameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: PhotoCameraPicker
        init(_ parent: PhotoCameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}