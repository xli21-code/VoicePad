import Foundation

/// Calls Claude API to restructure raw transcribed speech into clean, structured text.
final class LLMPolisher {
    private let configPath = NSHomeDirectory() + "/.voicepad/config.json"

    /// Polish raw transcription into structured text via Claude API.
    /// Returns the polished text, or nil if polishing fails (caller should fall back to original).
    func polish(_ text: String) async -> String? {
        guard let apiKey = loadAPIKey() else {
            vpLog("[LLMPolisher] No API key found")
            return nil
        }

        let prompt = buildPrompt(for: text)

        do {
            let result = try await callClaude(apiKey: apiKey, prompt: prompt)
            vpLog("[LLMPolisher] polished: '\(result.prefix(80))'")
            return result
        } catch {
            vpLog("[LLMPolisher] error: \(error)")
            return nil
        }
    }

    // MARK: - API Key

    private func loadAPIKey() -> String? {
        // 1. Check environment variable
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return key
        }

        // 2. Check config file ~/.voicepad/config.json
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["anthropic_api_key"] as? String, !key.isEmpty else {
            return nil
        }
        return key
    }

    private func loadBaseURL() -> String {
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let url = json["api_base_url"] as? String, !url.isEmpty {
            return url.hasSuffix("/") ? String(url.dropLast()) : url
        }
        return "https://api.anthropic.com"
    }

    private func loadModel() -> String {
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let model = json["model"] as? String, !model.isEmpty {
            return model
        }
        return "claude-sonnet-4-20250514"
    }

    /// Save config values to file.
    func saveConfig(apiKey: String? = nil, baseURL: String? = nil, model: String? = nil) {
        var json: [String: Any] = [:]

        // Read existing config
        if let data = FileManager.default.contents(atPath: configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        if let apiKey { json["anthropic_api_key"] = apiKey }
        if let baseURL { json["api_base_url"] = baseURL }
        if let model { json["model"] = model }

        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            let dir = (configPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: configPath, contents: data)
        }
    }

    /// Save API key to config file.
    func saveAPIKey(_ key: String) {
        var json: [String: Any] = [:]

        // Read existing config
        if let data = FileManager.default.contents(atPath: configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        json["anthropic_api_key"] = key

        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            let dir = (configPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: configPath, contents: data)
        }
    }

    func hasAPIKey() -> Bool {
        loadAPIKey() != nil
    }

    /// Load current config for display in settings UI.
    func loadConfig() -> (apiKey: String?, baseURL: String?, model: String?) {
        var apiKey: String?
        var baseURL: String?
        var model: String?

        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            apiKey = json["anthropic_api_key"] as? String
            baseURL = json["api_base_url"] as? String
            model = json["model"] as? String
        }
        return (apiKey, baseURL, model)
    }

    /// Test API connectivity with a minimal request. Returns nil on success, or error message on failure.
    func testConnection(apiKey: String, baseURL: String?, model: String?) async -> String? {
        let base = (baseURL?.isEmpty ?? true) ? "https://api.anthropic.com" : baseURL!
        let finalBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let mdl = (model?.isEmpty ?? true) ? "claude-sonnet-4-20250514" : model!
        let endpoint = "\(finalBase)/v1/messages"

        guard let url = URL(string: endpoint) else {
            return "Invalid URL: \(endpoint)"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": mdl,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.default
        if let proxyURL = systemProxyURL() {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: proxyURL.host ?? "",
                kCFNetworkProxiesHTTPSPort: proxyURL.port ?? 1087,
            ]
        }
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Invalid response"
            }
            if http.statusCode == 200 {
                return nil // success
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            // Try to extract error message from JSON
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String {
                return "HTTP \(http.statusCode): \(msg)"
            }
            return "HTTP \(http.statusCode): \(body.prefix(200))"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Prompt

    private func buildPrompt(for text: String) -> String {
        """
        语音转文字后处理。规则：保留原意和说话人的语气风格，整理语序，去冗余语气词，修正语法，不翻译（保持原语言和中英混合），将误识别的谐音还原为正确单词。输出要像真人说的话，不要书面化、不要AI味。直接输出结果。

        \(text)
        """
    }

    // MARK: - Claude API

    private func callClaude(apiKey: String, prompt: String) async throws -> String {
        let baseURL = loadBaseURL()
        let model = loadModel()
        let endpoint = "\(baseURL)/v1/messages"
        vpLog("[LLMPolisher] calling \(endpoint) with model=\(model)")

        guard let url = URL(string: endpoint) else {
            throw PolishError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Use system proxy if available
        let config = URLSessionConfiguration.default
        if let proxyURL = systemProxyURL() {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: proxyURL.host ?? "",
                kCFNetworkProxiesHTTPSPort: proxyURL.port ?? 1087,
            ]
        }
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PolishError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            vpLog("[LLMPolisher] API error \(httpResponse.statusCode): \(body.prefix(200))")
            throw PolishError.apiError(httpResponse.statusCode, body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw PolishError.parseError
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func systemProxyURL() -> URL? {
        guard let proxies = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        if let host = proxies[kCFNetworkProxiesHTTPSProxy as String] as? String,
           let port = proxies[kCFNetworkProxiesHTTPSPort as String] as? Int,
           (proxies[kCFNetworkProxiesHTTPSEnable as String] as? Int) == 1 {
            return URL(string: "http://\(host):\(port)")
        }
        return nil
    }
}

enum PolishError: LocalizedError {
    case invalidResponse
    case apiError(Int, String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from API"
        case .apiError(let code, _): "API error: \(code)"
        case .parseError: "Failed to parse API response"
        }
    }
}
