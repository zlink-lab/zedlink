import Foundation
import ImageIO
import UniformTypeIdentifiers

// Chunked uploads into `<workspace>/.zlink/uploads/…` (project.upload.begin/chunk/commit/abort).
// Shared by the app's composer and the ZLinkShare extension; Foundation and ImageIO only.

/// A file ready for `project.upload.begin`: HEIC/HEIF already converted to JPEG.
struct PreparedUpload {
    let fileName: String
    let mimeType: String
    let data: Data
    var isImage: Bool { mimeType.hasPrefix("image/") }
}

/// The result of `project.upload.commit`. `ref` goes into `thread.send` `upload_refs`.
struct CommittedUpload: Equatable {
    let ref: String
    let displayName: String
    let mimeType: String
    let size: Int
    let kind: String
}

/// A chip above the composer: uploading (progress), uploaded (ref) or failed.
struct ComposerUpload: Identifiable, Equatable {
    let id: UUID
    let name: String
    let mimeType: String
    let size: Int
    var progress: Double = 0
    var ref: String? = nil
    var failure: String? = nil

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var isUploading: Bool { ref == nil && failure == nil }
}

enum ProjectUploader {
    static let maxBytes = 25 * 1024 * 1024
    static let maxRefsPerMessage = 10
    static let capability = "project.upload.begin"

    /// MIME type for a file name, `application/octet-stream` when unknown.
    static func mimeType(forFileName name: String) -> String {
        let ext: String = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Converts HEIC/HEIF photos to JPEG (most agents and tools cannot read HEIC) and cleans the name.
    static func prepare(fileName rawName: String, mimeType rawMime: String?, data: Data) -> PreparedUpload {
        let name: String = cleanFileName(rawName)
        let mime: String = (rawMime?.isEmpty == false ? rawMime! : mimeType(forFileName: name)).lowercased()
        let ext: String = (name as NSString).pathExtension.lowercased()
        let isHEIC: Bool = mime == "image/heic" || mime == "image/heif" || ext == "heic" || ext == "heif"
        if isHEIC, let jpeg = jpegData(from: data) {
            let base: String = (name as NSString).deletingPathExtension
            return PreparedUpload(fileName: (base.isEmpty ? "photo" : base) + ".jpg", mimeType: "image/jpeg", data: jpeg)
        }
        return PreparedUpload(fileName: name, mimeType: mime, data: data)
    }

    static func jpegData(from data: Data, quality: Double = 0.9) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // Keeps orientation and other metadata; drops the HEIC container.
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// A bare file name: no separators or control characters, no leading dot, at most 120 bytes.
    static func cleanFileName(_ raw: String) -> String {
        let blocked: Set<Unicode.Scalar> = ["/", "\\", ":"]
        let scalars: String.UnicodeScalarView = raw.unicodeScalars.filter { (scalar: Unicode.Scalar) -> Bool in
            scalar.value >= 32 && scalar.value != 127 && !blocked.contains(scalar)
        }
        var name: String = String(scalars).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        while name.utf8.count > 120 { name.removeFirst() }
        return name.isEmpty ? "file" : name
    }

    /// begin → chunk… → commit. `threadID` or `projectID` names the target workspace. Aborts the
    /// pending upload (best effort) when a step fails or the task is cancelled.
    @MainActor static func upload(client: GatewayClient, instanceID: String, epoch: String,
                       threadID: String?, projectID: String?, file: PreparedUpload,
                       progress: @escaping (Double) -> Void) async throws -> CommittedUpload {
        guard file.data.count <= maxBytes else { throw GatewayFailure.native("FILE_TOO_LARGE") }
        var begin: [String: Any] = ["instance_id": instanceID, "epoch": epoch, "file_name": file.fileName,
                                    "mime_type": file.mimeType, "size": file.data.count]
        if let threadID { begin["thread_id"] = threadID } else if let projectID { begin["project_id"] = projectID }
        let started: [String: Any]
        do {
            started = try await client.rpc("project.upload.begin", params: begin)
        } catch let error as GatewayFailure where error.isThreadNotLoaded && threadID != nil && projectID != nil {
            // A saved thread of a project closed in Zed is not loaded; the bridge accepts the
            // project itself and writes into it on disk (wave 3 §6.3).
            begin.removeValue(forKey: "thread_id")
            begin["project_id"] = projectID
            started = try await client.rpc("project.upload.begin", params: begin)
        }
        guard let uploadID = started["upload_id"] as? String, !uploadID.isEmpty else { throw GatewayFailure.invalidResponse }
        let chunkSize: Int = max(16 * 1024, min(started["chunk_size"] as? Int ?? 786_432, 4 * 1024 * 1024))
        do {
            var offset = 0
            progress(0)
            while offset < file.data.count {
                try Task.checkCancellation()
                let end: Int = min(offset + chunkSize, file.data.count)
                let chunk: String = file.data.subdata(in: offset..<end).base64EncodedString()
                let result = try await client.rpc("project.upload.chunk", params: [
                    "instance_id": instanceID, "epoch": epoch, "upload_id": uploadID,
                    "offset": offset, "data": chunk,
                ])
                let received: Int = result["received"] as? Int ?? end
                guard received == end else { throw GatewayFailure.native("UPLOAD_FAILED") }
                offset = end
                progress(Double(offset) / Double(max(file.data.count, 1)))
            }
            try Task.checkCancellation()
            let committed = try await client.rpc("project.upload.commit", params: [
                "instance_id": instanceID, "epoch": epoch, "upload_id": uploadID,
            ])
            guard let ref = committed["upload_ref"] as? String ?? committed["relative_path"] as? String, !ref.isEmpty else {
                throw GatewayFailure.invalidResponse
            }
            progress(1)
            return CommittedUpload(ref: ref,
                                   displayName: committed["display_name"] as? String ?? file.fileName,
                                   mimeType: committed["mime_type"] as? String ?? file.mimeType,
                                   size: committed["size"] as? Int ?? file.data.count,
                                   kind: committed["kind"] as? String ?? (file.isImage ? "image" : "file"))
        } catch {
            // A new task: the failed one may already be cancelled, which would cancel this request too.
            Task { _ = try? await client.rpc("project.upload.abort", params: ["instance_id": instanceID, "epoch": epoch, "upload_id": uploadID]) }
            throw error
        }
    }

    static func describe(_ error: Error) -> String {
        if case GatewayFailure.native(let code) = error {
            switch code {
            case "FILE_TOO_LARGE": return "Files can be up to 25 MiB (FILE_TOO_LARGE)."
            case "UNKNOWN_UPLOAD": return "The upload expired on the desktop (UNKNOWN_UPLOAD). Attach the file again."
            case "UPLOAD_FAILED": return "Zed could not write the file into the project (UPLOAD_FAILED)."
            case "INVALID_REQUEST": return "Zed rejected the upload (INVALID_REQUEST)."
            case "PROJECT_NOT_OPEN": return "Проект не открыт в Zed (PROJECT_NOT_OPEN). Откройте его в Zed и повторите."
            default: break
            }
        }
        return error.localizedDescription
    }
}
