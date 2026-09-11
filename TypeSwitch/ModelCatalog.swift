import Foundation

enum ModelCatalogError: LocalizedError {
    case badAddress(String)
    case transport(String)
    case http(Int, String)
    case notOffered

    var errorDescription: String? {
        switch self {
        case .badAddress(let url): String(localized: "接口地址无效：\(url)")
        case .transport(let message): String(localized: "网络错误：\(message)")
        case .http(401, _), .http(403, _): String(localized: "这个地址要先有正确的 Key 才肯列出模型")
        case .http(let code, let message): String(localized: "取模型列表失败（\(code)）：\(message)")
        case .notOffered: String(localized: "这个地址不提供模型列表，模型名要自己填")
        }
    }
}

/// What an address will admit to being able to run.
///
/// A model name is the one field nobody can be expected to remember. It is not
/// a setting the user chooses so much as a fact about the address they are
/// pointed at, and the address knows it: asking beats a text field where a typo
/// only shows up later as a 404 from somewhere else in the app.
enum ModelCatalog {
    static func fetch(baseURL: String, key: String) async throws -> [String] {
        guard let url = Endpoint.models(baseURL) else {
            throw ModelCatalogError.badAddress(baseURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ModelCatalogError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // 404 here means this address does not offer the list, which is a
            // normal thing for an address to do — it is not a failure the user
            // has to fix, only one they have to work around by typing a name.
            if http.statusCode == 404 { throw ModelCatalogError.notOffered }
            throw ModelCatalogError.http(http.statusCode, message(in: data))
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else { throw ModelCatalogError.notOffered }

        let names = entries.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        guard !names.isEmpty else { throw ModelCatalogError.notOffered }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func message(in data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return String(data: data, encoding: .utf8) ?? "" }
        return message
    }
}
