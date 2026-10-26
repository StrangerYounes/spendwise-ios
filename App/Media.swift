import AVFoundation
import SwiftUI
import UIKit
import Vision
import SpendWiseCore

/// Records a short voice note as AAC in an ADTS stream (".aac"), the format the backend sends to
/// Gemini as audio/aac, like Android's: 16 kHz mono at 32 kbps, about 4 KB a second.
@MainActor
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    static let maxDuration: TimeInterval = 120
    private static let minBytes = 2_000 // under about half a second

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var onMax: (() -> Void)?

    var isRecording: Bool { recorder != nil }

    /// Asks for the microphone (once); false when it isn't allowed.
    static func permission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Starts recording; [onMaxDuration] fires if the note reaches the limit.
    func start(onMaxDuration: @escaping () -> Void) throws {
        cancel()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try session.setActive(true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("quick_add_\(UUID().uuidString).aac")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let r = try AVAudioRecorder(url: file, settings: settings)
        r.isMeteringEnabled = true
        r.delegate = self
        guard r.record(forDuration: Self.maxDuration) else { throw CocoaError(.fileWriteUnknown) }
        recorder = r
        url = file
        onMax = onMaxDuration
    }

    /// Current input level from 0 to 1, for the recording indicator.
    func level() -> Float {
        guard let r = recorder else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0) // -160...0
        return max(0, min(1, (db + 50) / 50))
    }

    /// Stops and returns the recorded bytes, or nil if nothing usable was captured.
    func stop() -> Data? {
        guard let r = recorder, let file = url else { return nil }
        recorder = nil
        url = nil
        onMax = nil
        r.stop()
        let data = try? Data(contentsOf: file)
        try? FileManager.default.removeItem(at: file)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let data, data.count > Self.minBytes else { return nil }
        return data
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        onMax = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            // Reached the limit while still recording: stop as if the person had pressed stop
            if self.recorder === recorder { self.onMax?() }
        }
    }
}

/// A receipt photo, prepared once: what's shown and what's sent.
struct ReceiptPhoto: Identifiable, Equatable {
    let id = UUID()
    let image: UIImage
    /** JPEG, longest side at most 2560 px (small print on long receipts), quality 0.85. */
    let jpeg: Data

    static func == (a: ReceiptPhoto, b: ReceiptPhoto) -> Bool { a.id == b.id }

    static let maxSide: CGFloat = 2560

    /// From a photo's bytes (camera or gallery); orientation is applied, as on Android.
    static func make(_ data: Data) -> ReceiptPhoto? {
        guard let image = UIImage(data: data) else { return nil }
        return make(image)
    }

    static func make(_ image: UIImage) -> ReceiptPhoto? {
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpeg = drawn.jpegData(compressionQuality: 0.85) else { return nil }
        return ReceiptPhoto(image: drawn, jpeg: jpeg)
    }
}

/// The phone's own text reader (Vision), when the AI can't read the receipt: items only.
enum OnDeviceReceipt {
    static func items(from photos: [ReceiptPhoto]) async -> [QuickItem] {
        var out: [QuickItem] = []
        for photo in photos {
            guard let cg = photo.image.cgImage else { continue }
            let boxes: [ReceiptText.Box] = await withCheckedContinuation { cont in
                let request = VNRecognizeTextRequest { req, _ in
                    let observations = req.results as? [VNRecognizedTextObservation] ?? []
                    let boxes = observations.compactMap { o -> ReceiptText.Box? in
                        guard let text = o.topCandidates(1).first?.string else { return nil }
                        let b = o.boundingBox
                        // Vision's origin is bottom left; the parser's rows go top down
                        return ReceiptText.Box(text: text, top: Double(1 - b.maxY), left: Double(b.minX), height: Double(b.height))
                    }
                    cont.resume(returning: boxes)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                do { try VNImageRequestHandler(cgImage: cg).perform([request]) } catch { cont.resume(returning: []) }
            }
            for s in ReceiptText.parseRows(ReceiptText.rows(boxes)) {
                out.append(QuickItem(name: s.name, quantity: s.quantity, unit: QuickAddParser.cleanUnit(s.unit),
                                     unitPrice: s.totalPrice.map { $0 / s.quantity } ?? s.unitPrice))
            }
        }
        return out
    }
}

/// The camera, for receipt photos.
struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

/// "0:12".
func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
