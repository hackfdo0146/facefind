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
        case enrolment, recognition, settings, library
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

                MenuButton(title: "library scan",
                           subtitle: "find NEW faces in your photo library",
                           icon: "photo.stack",
                           color: .purple) { path.append(.library) }

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
                case .library:     LibraryScanView()
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

// MARK: - LIBRARY SCAN screen (find NEW faces in the photo library)
struct LibraryScanView: View {
    @StateObject private var status = StatusBox()
    @State private var permissionDenied = false
    @State private var scanning = false
    @State private var progressText = ""
    @State private var resultSummary = ""
    @State private var newFaces: [LibraryScanner.NewFace] = []
    @State private var thumbs: [String: UIImage] = [:]        // assetID → thumbnail
    @State private var enrollTarget: LibraryScanner.NewFace? = nil
    @State private var enrollName = ""
    @State private var scannedKnown = 0
    @State private var scannedNoFace = 0
    @State private var processedBefore = 0
    @State private var indexedPeople: [(id: String, name: String, faceCount: Int)] = []
    @State private var enrolledAfter: [(name: String, count: Int)] = []   // mirrors enrolment list

    private let budget = 40          // assets per pass (UI stays responsive)

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("people & pets index") {
                    if indexedPeople.isEmpty {
                        Text("Apple's on-device People & Pets index is not readable in this build — falling back to on-device Vision detection for the library scan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Apple already indexed \(indexedPeople.count) named people on this phone. Photos attributed to them are marked recognized from that index directly — no re-detection. Only photos with UNNAMED faces are scanned.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(indexedPeople.prefix(6), id: \.id) { p in
                            LabeledContent(p.name, value: "\(p.faceCount) visages")
                        }
                    }
                }

                Section("on-device scan") {
                    LabeledContent("already processed", value: "\(processedBefore) photos")
                    LabeledContent("mode", value: "incremental — only unseen photos")
                }

                Section {
                    Button {
                        startScan()
                    } label: {
                        HStack {
                            Spacer()
                            if scanning {
                                ProgressView()
                                Text(progressText).font(.footnote)
                            } else {
                                Label("scan library for new faces", systemImage: "magnifyingglass")
                            }
                            Spacer()
                        }
                        .frame(minHeight: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(scanning)
                    .listRowInsets(EdgeInsets())
                }

                if !resultSummary.isEmpty {
                    Section("last scan") {
                        Text(resultSummary).font(.footnote)
                    }
                }

                if !newFaces.isEmpty {
                    Section("new faces (\(newFaces.count)) — tap to enroll") {
                        ForEach(Array(newFaces.enumerated()), id: \.offset) { idx, f in
                            Button {
                                enrollTarget = f
                                enrollName = ""
                            } label: {
                                HStack(spacing: 12) {
                                    if let t = thumbs[f.assetID] {
                                        Image(uiImage: t)
                                            .resizable().scaledToFill()
                                            .frame(width: 56, height: 56)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    } else {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.gray.opacity(0.2))
                                            .frame(width: 56, height: 56)
                                            .overlay(ProgressView())
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("unknown face — face #\(f.faceIndex + 1)")
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("closest match: \(f.bestName ?? "nobody") (\(Int(f.bestSimilarity * 100))%)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "person.badge.plus")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("library scan")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            processedBefore = LibraryScanner.processedCount()
            status.refresh()
            checkPhotoPermission()
            // read Apple's People & Pets index (private API, sideloaded builds)
            DispatchQueue.global(qos: .userInitiated).async {
                let people = PhotosPeopleIndex.namedPeople()
                DispatchQueue.main.async { indexedPeople = people }
            }
        }
        .sheet(item: Binding(
            get: { enrollTarget.map { EnrollBox(face: $0) } },
            set: { enrollTarget = $0?.face })) { box in
            NavigationStack {
                Form {
                    Section("enroll this face as") {
                        TextField("person's name", text: $enrollName)
                        Button {
                            let personName = enrollName.trimmingCharacters(in: .whitespaces)
                            if LibraryScanner.enroll(face: box.face, name: personName) {
                                newFaces.removeAll { $0.assetID == box.face.assetID && $0.faceIndex == box.face.faceIndex }
                                enrolledAfter = FaceDatabase.shared.people()
                                status.refresh()
                            }
                            enrollTarget = nil
                        } label: {
                            Text("save faceprint").frame(minHeight: 36)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(enrollName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !enrolledAfter.isEmpty {
                        Section("enrolled now") {
                            ForEach(enrolledAfter, id: \.name) { p in
                                LabeledContent(p.name, value: "\(p.count) faceprint\(p.count == 1 ? "" : "s")")
                            }
                        }
                    }
                }
                .navigationTitle("new person")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("cancel") { enrollTarget = nil }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("photo library access denied", isPresented: $permissionDenied) {
            Button("open settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("FaceFind needs full photo library access to scan for new faces. Enable it in Settings → FaceFind → Photos.")
        }
    }

    private func startScan() {
        scanning = true
        resultSummary = ""
        scannedKnown = 0
        scannedNoFace = 0
        let threshold = Float(UserDefaults.standard.object(forKey: "thresholdPct") as? Int ?? 60) / 100

        func nextPass() {
            LibraryScanner.scan(budget: budget, threshold: threshold,
                                progress: { done, total in
                                    progressText = "\(done)/\(total) photos…"
                                },
                                completion: { r in
                                    newFaces.append(contentsOf: r.newlyFound)
                                    scannedKnown += r.knownFaces
                                    scannedNoFace += r.noFaceAssets
                                    processedBefore = LibraryScanner.processedCount()
                                    resultSummary = "\(r.scanned) photos scanned · \(scannedKnown) known faces skipped · \(newFaces.count) new faces found · \(scannedNoFace) photos without faces"
                                    loadThumbs()
                                    if !r.done {
                                        nextPass()
                                    } else {
                                        scanning = false
                                        progressText = ""
                                    }
                                })
        }

        // STEP 1 — People & Pets pre-pass: photos Apple already attributes to a
        // NAMED person get marked processed immediately (zero Vision work for
        // them — the index IS Apple's face recognition).
        DispatchQueue.global(qos: .userInitiated).async {
            let opts = PHFetchOptions()
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let fetch = PHAsset.fetchAssets(with: opts)
            var all: [PHAsset] = []
            fetch.enumerateObjects { a, _, _ in all.append(a) }
            let named = PhotosPeopleIndex.namedFacesByAsset(assetIDs: all.map(\.localIdentifier))
            var covered = 0
            for (id, names) in named where !names.isEmpty {
                LibraryScanner.markProcessed(assetID: id)
                covered += 1
            }
            DispatchQueue.main.async {
                processedBefore = LibraryScanner.processedCount()
                resultSummary = covered > 0
                    ? "People & Pets index covered \(covered) photos with named people — scanning the rest…"
                    : "People & Pets index unavailable — full Vision scan…"
                // STEP 2 — Vision passes over everything not yet processed
                nextPass()
            }
        }
    }

    private func loadThumbs() {
        let ids = Set(newFaces.map(\.assetID)).intersection(Set(thumbs.keys.map { $0 })).symmetricDifference(Set(newFaces.map(\.assetID)))
        for id in ids {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { continue }
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isSynchronous = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 160, height: 160),
                                                  contentMode: .aspectFill, options: opts) { img, _ in
                if let img { thumbs[id] = img }
            }
        }
    }

    private func checkPhotoPermission() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            break
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
                if st == .denied || st == .restricted {
                    DispatchQueue.main.async { permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }
}

// Identifiable wrapper for the enroll sheet
struct EnrollBox: Identifiable {
    let face: LibraryScanner.NewFace
    var id: String { face.assetID + "-\(face.faceIndex)" }
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