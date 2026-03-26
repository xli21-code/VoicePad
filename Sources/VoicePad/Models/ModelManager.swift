import Foundation

/// Manages ASR and translation model downloads with proxy support.
final class ModelManager {
    private let modelsDir: URL
    private let asrModelDirName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
    private let asrModelURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"
    private let asrCheckFile = "model.onnx"

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        modelsDir = home.appendingPathComponent(".voicepad/models")
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    }

    // MARK: - ASR Model

    func isASRModelReady() -> Bool {
        let checkPath = modelsDir
            .appendingPathComponent(asrModelDirName)
            .appendingPathComponent(asrCheckFile)
        return FileManager.default.fileExists(atPath: checkPath.path)
    }

    func asrModelPath() -> String? {
        guard isASRModelReady() else { return nil }
        return modelsDir.appendingPathComponent(asrModelDirName).path
    }

    /// Check if coli already downloaded the model
    func checkColiModels() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let coliPath = home.appendingPathComponent(".coli/models/\(asrModelDirName)/\(asrCheckFile)")
        if FileManager.default.fileExists(atPath: coliPath.path) {
            return home.appendingPathComponent(".coli/models/\(asrModelDirName)").path
        }
        return nil
    }

    /// Download the ASR model with progress reporting.
    func downloadASRModel(progress: @escaping (Double) -> Void) async throws {
        // First check if coli already has it
        if let coliPath = checkColiModels() {
            let destPath = modelsDir.appendingPathComponent(asrModelDirName)
            try? FileManager.default.createSymbolicLink(
                at: destPath,
                withDestinationURL: URL(fileURLWithPath: coliPath)
            )
            if isASRModelReady() { return }
        }

        let tarPath = modelsDir.appendingPathComponent("\(asrModelDirName).tar.bz2")

        // Download with system proxy support
        let config = URLSessionConfiguration.default
        if let proxyURL = systemProxyURL() {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: proxyURL.host ?? "",
                kCFNetworkProxiesHTTPPort: proxyURL.port ?? 1087,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: proxyURL.host ?? "",
                kCFNetworkProxiesHTTPSPort: proxyURL.port ?? 1087,
            ]
        }
        let session = URLSession(configuration: config)

        guard let url = URL(string: asrModelURL) else {
            throw ModelError.invalidURL
        }

        let (asyncBytes, response) = try await session.bytes(from: url)
        let totalBytes = (response as? HTTPURLResponse)
            .flatMap { Int($0.value(forHTTPHeaderField: "Content-Length") ?? "") } ?? 0

        // Write to file
        let handle = try FileHandle(forWritingTo: tarPath.deletingLastPathComponent())
        FileManager.default.createFile(atPath: tarPath.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tarPath)
        defer { try? fileHandle.close() }

        var downloaded = 0
        for try await byte in asyncBytes {
            fileHandle.write(Data([byte]))
            downloaded += 1
            if totalBytes > 0, downloaded % (1024 * 64) == 0 {
                progress(Double(downloaded) / Double(totalBytes))
            }
        }
        progress(1.0)

        // Extract tar.bz2
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xjf", tarPath.path, "-C", modelsDir.path]
        try process.run()
        process.waitUntilExit()

        // Clean up archive
        try? FileManager.default.removeItem(at: tarPath)

        guard isASRModelReady() else {
            throw ModelError.extractionFailed
        }
    }

    // MARK: - Proxy Detection

    func systemProxyURL() -> URL? {
        guard let proxies = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        // Check HTTPS proxy first
        if let host = proxies[kCFNetworkProxiesHTTPSProxy as String] as? String,
           let port = proxies[kCFNetworkProxiesHTTPSPort as String] as? Int,
           (proxies[kCFNetworkProxiesHTTPSEnable as String] as? Int) == 1 {
            return URL(string: "http://\(host):\(port)")
        }

        // Fall back to HTTP proxy
        if let host = proxies[kCFNetworkProxiesHTTPProxy as String] as? String,
           let port = proxies[kCFNetworkProxiesHTTPPort as String] as? Int,
           (proxies[kCFNetworkProxiesHTTPEnable as String] as? Int) == 1 {
            return URL(string: "http://\(host):\(port)")
        }

        return nil
    }
}

enum ModelError: LocalizedError {
    case invalidURL
    case downloadFailed(String)
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid model URL"
        case .downloadFailed(let msg): "Download failed: \(msg)"
        case .extractionFailed: "Failed to extract model archive"
        }
    }
}
