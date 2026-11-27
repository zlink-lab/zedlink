import SwiftUI
import Speech
import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// Dictation language stored under `zedlink.speechLocale`: "system", "ru-RU" or "en-US".
struct DictationLanguageOption: Identifiable, Equatable {
    let id: String
    let label: String
}

enum DictationLanguage {
    static let storageKey = "zedlink.speechLocale"
    static let options: [DictationLanguageOption] = [
        DictationLanguageOption(id: "system", label: "System"),
        DictationLanguageOption(id: "ru-RU", label: "Русский"),
        DictationLanguageOption(id: "en-US", label: "English (US)"),
    ]

    static var selected: String { UserDefaults.standard.string(forKey: storageKey) ?? "system" }

    static func label(_ id: String) -> String {
        options.first(where: { $0.id == id })?.label ?? id
    }

    static func recognizer() -> SFSpeechRecognizer? {
        let id: String = selected
        return id == "system" ? SFSpeechRecognizer() : SFSpeechRecognizer(locale: Locale(identifier: id))
    }
}

@MainActor
private final class DraftDictation: ObservableObject {
    @Published var listening = false
    @Published var starting = false
    @Published var finishing = false
    @Published var transcript = ""
    @Published var issue = ""
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapped = false
    private var generation = UUID()
    private var finishTimeout: Task<Void, Never>?
    private var audioActive = false

    func start() async {
        guard !starting, !finishing else { return }
        guard !listening else { finish(); return }
        stop()
        let current = generation
        starting = true
        defer { if current == generation { starting = false } }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard current == generation else { return }
        guard authorization == .authorized, microphone else { issue = "Allow microphone and speech access in Settings, or use keyboard dictation."; return }
        guard let recognizer = DictationLanguage.recognizer() else {
            issue = "Dictation does not support \(DictationLanguage.label(DictationLanguage.selected)). Choose another language in Settings or use your keyboard microphone."; return
        }
        guard recognizer.isAvailable else {
            issue = recognizer.supportsOnDeviceRecognition
                ? "Dictation is temporarily unavailable. Try again or use your keyboard microphone."
                : "Dictation for this language needs Apple's speech service. Check the network connection or use your keyboard microphone."
            return
        }
        self.recognizer = recognizer
        transcript = ""; issue = ""
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement)
            try audio.setActive(true)
            audioActive = true
            let request = SFSpeechAudioBufferRecognitionRequest()
            // Prefer on-device recognition; otherwise Apple's speech service transcribes the audio.
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request.shouldReportPartialResults = true
            self.request = request
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw NSError(domain: "Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone is unavailable."]) }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapped = true
            engine.prepare(); try engine.start(); listening = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if let error { self.issue = error.localizedDescription }
                    if result?.isFinal == true || error != nil { self.stop() }
                }
            }
        } catch { issue = error.localizedDescription; stop() }
    }
    func finish() {
        guard listening, !finishing else { return }
        stopAudioCapture()
        listening = false; finishing = true
        request?.endAudio()
        let current = generation
        finishTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.generation == current else { return }
            self.stop()
        }
    }
    private func stopAudioCapture() {
        if engine.isRunning { engine.stop() }
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    }
    func stop() {
        generation = UUID()
        finishTimeout?.cancel(); finishTimeout = nil
        stopAudioCapture()
        request?.endAudio(); task?.cancel(); task = nil; request = nil; recognizer = nil
        listening = false; starting = false; finishing = false
        if audioActive {
            audioActive = false
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            catch { if issue.isEmpty { issue = error.localizedDescription } }
        }
    }
}

struct VoiceDraftButton: View {
    @Binding var text: String
    let scope: String
    @StateObject private var dictation = DraftDictation()
    @State private var original = ""
    @State private var lastApplied = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            if dictation.listening { dictation.finish() }
            else { original = text; lastApplied = text; Task { await dictation.start() } }
        } label: {
            Group {
                if dictation.starting || dictation.finishing { ProgressView().controlSize(.small) }
                else { Image(systemName: dictation.listening ? "waveform" : "mic").symbolEffect(.variableColor, isActive: dictation.listening && !reduceMotion) }
            }.frame(width: 44, height: 44)
        }.disabled(dictation.starting || dictation.finishing)
        .accessibilityLabel(dictation.starting ? "Preparing dictation" : dictation.finishing ? "Finishing dictation" : dictation.listening ? "Stop dictation" : "Dictate draft text")
        .onChange(of: dictation.transcript) { _, value in
            guard text == lastApplied else { dictation.stop(); return }
            lastApplied = String((original + (original.isEmpty || value.isEmpty ? "" : " ") + value).prefix(3000))
            text = lastApplied
        }
        .onChange(of: scope) { _, _ in dictation.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { dictation.stop() } }
        .onDisappear { dictation.stop() }
        .alert("Dictation", isPresented: Binding(get: { !dictation.issue.isEmpty }, set: { if !$0 { dictation.issue = "" } })) {
            Button("OK") { dictation.issue = "" }
        } message: { Text(dictation.issue) }
    }
}

struct RemoteClipboardView: View {
    @EnvironmentObject private var session: SessionManager
    @Environment(\.dismiss) private var dismiss
    var destination = "terminal"
    let insert: (String) -> Void
    @State private var text = ""
    @State private var busy = false
    @State private var status = ""
    private var scope: String { "\(session.profile?.id.uuidString ?? "").\(session.targetID ?? "").\(session.instanceID ?? "").\(session.epoch ?? "").\(session.selectedThreadID ?? "")" }
    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") { TextEditor(text: $text).frame(minHeight: 160).onChange(of: text) { old, value in if value.utf8.count > 65536 { text = old; status = "Clipboard exceeds 64 KiB." } }
                    Text(destination == "terminal"
                         ? "Explicit text transfers only. Terminal paste fills a draft; it does not execute."
                         : "Explicit text transfers only. Inserting text fills the message draft; it does not send.")
                        .font(.caption)
                }
                Section {
                    Button("Read desktop clipboard") { transfer(nil) }.disabled(!session.capabilities.contains("clipboard.read"))
                    Button("Paste from phone") { let value = UIPasteboard.general.string ?? ""; if value.utf8.count <= 65536 { text = value } else { status = "Clipboard exceeds 64 KiB." } }
                    Button("Copy to phone") { UIPasteboard.general.string = text }
                    Button("Send to desktop clipboard") { transfer(text) }.disabled(!session.capabilities.contains("clipboard.write"))
                    Button("Insert in \(destination) draft") {
                        guard text.utf8.count <= 16384, !text.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13 || $0.value == 127 }) else { status = "Use plain text up to 16 KiB without terminal controls."; return }
                        guard destination != "prompt" || text.count <= 3000 else { status = "Use up to 3000 characters for the prompt."; return }
                        insert(text); dismiss()
                    }.disabled(destination == "terminal" ? !session.capabilities.contains("terminal.input") : session.selectedThreadID == nil)
                }.disabled(busy)
                if !session.capabilities.contains("clipboard.read") { Text("Enable Remote Clipboard in desktop ZedLink settings for desktop transfers.") }
                if !status.isEmpty { Text(status) }
            }
            .task { await session.loadProjectContext() }
            .onChange(of: scope) { _, _ in text = ""; dismiss() }
            .onDisappear { text = "" }
            .navigationTitle("Remote clipboard").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
    private func transfer(_ value: String?) {
        busy = true
        Task { defer { busy = false }; if let result = await session.transferClipboard(value) { text = result; status = value == nil ? "Ready to review." : "Desktop clipboard updated." } else { status = session.issue } }
    }
}

// MARK: Prompt attachments from the phone (clipboard and Files)

/// Reads the phone clipboard image: `UIPasteboard.image` first, then any item provider whose
/// type conforms to `public.image` (PNG, JPEG, HEIC, WebP, …).
@MainActor func loadPhoneClipboardImage() async -> UIImage? {
    let pasteboard = UIPasteboard.general
    if let image = pasteboard.image { return image }
    return await loadPromptImage(from: pasteboard.itemProviders)
}

@MainActor func loadPromptImage(from providers: [NSItemProvider]) async -> UIImage? {
    for provider in providers {
        let types: [String] = provider.registeredTypeIdentifiers.filter { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }
        for type in types {
            let data: Data? = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data, let image = UIImage(data: data) { return image }
        }
        if provider.canLoadObject(ofClass: UIImage.self) {
            let image: UIImage? = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                    continuation.resume(returning: object as? UIImage)
                }
            }
            if let image { return image }
        }
    }
    return nil
}

enum PromptFileImport {
    case image(UIImage)
    case text(name: String, mimeType: String, data: Data)
    case failure(String)
}

/// The bridge accepts PNG/JPEG/WebP images and UTF-8 `text/*`, JSON and XML uploads up to
/// 256 KiB (embedded as text resources). Images go through annotation and JPEG conversion.
func readPromptFile(_ url: URL) -> PromptFileImport {
    let scoped: Bool = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let values: URLResourceValues? = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey])
    if values?.isDirectory == true { return .failure("Choose a file, not a folder.") }
    let type: UTType? = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
    let size: Int = values?.fileSize ?? 0
    let textLimit: Int = 256 * 1024
    if type?.conforms(to: .image) == true {
        guard size <= 25 * 1024 * 1024 else { return .failure("This image is too large to attach.") }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return .failure("This image format cannot be read on the phone.")
        }
        return .image(image)
    }
    let unsupported: String = "Only images and UTF-8 text files up to 256 KiB can be attached from the phone. Attach other files from the project in desktop Zed."
    guard size <= textLimit, let data = try? Data(contentsOf: url), data.count <= textLimit else { return .failure(unsupported) }
    guard !data.isEmpty, !data.contains(0), String(data: data, encoding: .utf8) != nil else { return .failure(unsupported) }
    let mimeType: String
    if type?.conforms(to: .json) == true {
        mimeType = "application/json"
    } else if type?.conforms(to: .xml) == true {
        mimeType = "application/xml"
    } else if let preferred = type?.preferredMIMEType, preferred.hasPrefix("text/"), preferred.utf8.count <= 128 {
        mimeType = preferred
    } else {
        mimeType = "text/plain"
    }
    return .text(name: promptFileName(url.lastPathComponent), mimeType: mimeType, data: data)
}

/// A bare file name the bridge accepts: no separators or control characters, no leading dot, at most 128 bytes.
func promptFileName(_ raw: String) -> String {
    let blocked: Set<Unicode.Scalar> = ["/", "\\"]
    let scalars: String.UnicodeScalarView = raw.unicodeScalars.filter { (scalar: Unicode.Scalar) -> Bool in
        scalar.value >= 32 && scalar.value != 127 && !blocked.contains(scalar)
    }
    var name: String = String(scalars)
    while name.hasPrefix(".") { name.removeFirst() }
    while name.utf8.count > 120 { name.removeFirst() }
    while name.hasPrefix(".") { name.removeFirst() }
    return name.trimmingCharacters(in: .whitespaces).isEmpty ? "attachment.txt" : name
}
