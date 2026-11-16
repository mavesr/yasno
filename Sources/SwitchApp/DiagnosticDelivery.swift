import Foundation
import CryptoKit

private final class DiagnosticNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class DiagnosticDelivery {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config, delegate: DiagnosticNoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    static func validRepo(_ repo: String) -> Bool {
        repo.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                   options: .regularExpression) != nil
    }
    // Called on a delivery queue, never on main or the input observer.
    func request(_ path: String, token: String, method: String = "GET",
                 body: [String: Any]? = nil) throws -> (Int, [String: Any]) {
        guard let url = URL(string: "https://api.github.com/\(path)") else { throw DiagnosticError.configuration }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Yasno-Diagnostics", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?)?
        let task = session.dataTask(with: req) { data, response, error in
            result = (data, response, error); done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + 30) == .success else { task.cancel(); throw DiagnosticError.network }
        guard let (data, response, error) = result, error == nil,
              let http = response as? HTTPURLResponse, let data else { throw DiagnosticError.network }
        if [401, 403].contains(http.statusCode) { throw DiagnosticError.authorization }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiagnosticError.network
        }
        return (http.statusCode, obj)
    }
    func push(token: String, repo: String, name: String, data: Data) throws -> String {
        guard Self.validRepo(repo), !token.isEmpty,
              name.range(of: #"^[a-z0-9-]+\.jsonl$"#, options: .regularExpression) != nil else {
            throw DiagnosticError.configuration
        }
        let (status, metadata) = try request("repos/\(repo)", token: token)
        guard status == 200 else { throw DiagnosticError.authorization }
        guard metadata["private"] as? Bool == true else { throw DiagnosticError.publicRepo }
        guard let branch = metadata["default_branch"] as? String, !branch.isEmpty else {
            throw DiagnosticError.network
        }
        let path = "repos/\(repo)/contents/logs/\(name)"
        let lookup = Self.revisionPath(path, ref: branch)
        let (existing, obj) = try request(lookup, token: token)
        if existing == 200 { return try identical(obj, data: data) }
        guard existing == 404 else { throw DiagnosticError.network }
        // Recheck visibility immediately before transmitting any journal content.
        let (checked, visibility) = try request("repos/\(repo)", token: token)
        guard checked == 200, visibility["private"] as? Bool == true else { throw DiagnosticError.publicRepo }
        let (created, response) = try request(path, token: token, method: "PUT",
            body: ["message": "Yasno diagnostic session \(name)", "content": data.base64EncodedString(),
                   "branch": branch])
        if created == 201, let commit = response["commit"] as? [String: Any], let sha = commit["sha"] as? String,
           sha.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil {
            // Do not delete the only local copy on a PUT acknowledgement alone.
            // Read the exact file at the returned commit, not a moving branch.
            let (readStatus, uploaded) = try request(Self.revisionPath(path, ref: sha), token: token)
            guard readStatus == 200 else { throw DiagnosticError.network }
            _ = try identical(uploaded, data: data)
            return sha
        }
        if [409, 422].contains(created) {
            let (code, retry) = try request(lookup, token: token)
            if code == 200 { return try identical(retry, data: data) }
            throw DiagnosticError.conflict
        }
        throw DiagnosticError.network
    }
    private static func revisionPath(_ path: String, ref: String) -> String {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "ref", value: ref)]
        return path + "?" + (query.percentEncodedQuery ?? "")
    }
    static func blobSHA(_ data: Data) -> String {
        var blob = Data("blob \(data.count)\0".utf8)
        blob.append(data)
        return Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    }
    private func identical(_ obj: [String: Any], data: Data) throws -> String {
        guard let sha = obj["sha"] as? String,
              sha == Self.blobSHA(data) else { throw DiagnosticError.conflict }
        return sha
    }
    func flush(store: DiagnosticStorage, token: String) throws -> [String] {
        try flush(files: store.files("queue"), token: token, fallbackRepo: "") { file in
            try FileManager.default.removeItem(at: file)
        }
    }
    func flush(files: [URL], token: String, fallbackRepo: String, remove: (URL) throws -> Void) throws -> [String] {
        var commits: [String] = []
        var failure: Error?
        for file in files {
            do {
            let data = try Data(contentsOf: file)
            guard let first = data.split(separator: 10).first,
                  let meta = try JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
                  var repo = meta["target_repo"] as? String else { throw DiagnosticError.disk }
            // A session recorded before a repository was set goes to the one set now.
            if repo.isEmpty { repo = fallbackRepo }
            guard Self.validRepo(repo) else { throw DiagnosticError.configuration }
            let sha = try push(token: token, repo: repo, name: file.lastPathComponent, data: data)
            try remove(file)
            commits.append(sha)
            } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
        return commits
    }
}
