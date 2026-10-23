import AppKit

/// Hands audio recorded on the phone to Haki, which transcribes it and types the text
/// into the focused field. Haki keeps the OpenAI key, model and language settings.
///
/// The clip goes into Haki's inbox, then `haki://transcribe?file=<name>` is opened in the
/// background, so the app you're typing into keeps focus. Haki deletes the file when done.
enum VoiceHandoff {
    static let inbox = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Haki/Inbox", isDirectory: true)

    /// File extension for the recording, from the upload's Content-Type (Safari on iOS records audio/mp4).
    static func fileExtension(contentType: String?) -> String {
        let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch type {
        case "audio/webm", "video/webm": return "webm"
        case "audio/wav", "audio/wave", "audio/x-wav": return "wav"
        case "audio/ogg": return "ogg"
        case "audio/mpeg": return "mp3"
        default: return "m4a"
        }
    }

    static func send(_ audio: Data, ext: String) throws {
        let name = "airmouse-\(UUID().uuidString).\(ext)"
        var components = URLComponents()
        components.scheme = "haki"
        components.host = "transcribe"
        components.queryItems = [URLQueryItem(name: "file", value: name)]
        guard let url = components.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            throw VoiceError.hakiMissing
        }

        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent(name)
        try audio.write(to: file, options: .atomic)

        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false  // keep focus on the app you're typing into
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                guard let error else { return }
                NSLog("AirMouse: could not hand audio to Haki: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

enum VoiceError: LocalizedError {
    case hakiMissing
    var errorDescription: String? { "Haki is not installed on this Mac." }
}
