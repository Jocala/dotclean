import Foundation

public enum UpdateError: Error, LocalizedError {
    case badResponse(Int)
    case badPayload

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "the server answered HTTP \(code)"
        case .badPayload: return "the reply was not readable text"
        }
    }
}

/// Manual update check against jocala.com, modeled on Catalog's updatecheck.cpp:
/// fetch the published version string, compare against the running build, and
/// let the UI offer the download page. Nothing here runs on its own — no
/// network traffic happens unless the user asks for a check.
public enum Updates {
    public static let homeURL = URL(string: "https://www.jocala.com/dotclean/")!
    public static let versionURL = URL(string: "https://www.jocala.com/dotclean/version.txt")!
    public static let donateURL = URL(string:
        "https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=GKZMW456H6E5W")!

    /// Pure compare, unit-tested. Any trimmed difference means "newer", the
    /// same semantics as Catalog and adblink — including a version rollback,
    /// which is deliberate: a reverted release must still reach installs.
    public static func isNewer(_ fetched: String, than current: String) -> Bool {
        let f = fetched.trimmingCharacters(in: .whitespacesAndNewlines)
        return !f.isEmpty && f != current.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetch the published version string.
    ///
    /// `DOTCLEAN_VERSION_URL` overrides the source so the newer / equal /
    /// offline branches can be exercised without touching the live file. An
    /// http(s) value is fetched; anything else is read as a local file.
    public static func fetchPublished(completion: @escaping (Result<String, Error>) -> Void) {
        if let override = ProcessInfo.processInfo.environment["DOTCLEAN_VERSION_URL"],
           !override.isEmpty {
            if override.hasPrefix("http://") || override.hasPrefix("https://") {
                guard let url = URL(string: override) else {
                    completion(.failure(UpdateError.badPayload))
                    return
                }
                return get(url, completion)
            }
            do {
                completion(.success(try String(contentsOfFile: override, encoding: .utf8)))
            } catch {
                completion(.failure(error))
            }
            return
        }
        get(versionURL, completion)
    }

    private static func get(_ url: URL, _ completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(.failure(UpdateError.badResponse(http.statusCode)))
                return
            }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                completion(.failure(UpdateError.badPayload))
                return
            }
            completion(.success(text))
        }.resume()
    }
}
