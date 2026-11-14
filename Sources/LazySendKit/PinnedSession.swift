import Foundation
import Security

final class Exchange {
    let onResponse: ((HTTPURLResponse) throws -> Void)?
    let sink: ((Data) throws -> Void)?
    let progress: (@Sendable (Int64) -> Void)?
    var response: HTTPURLResponse?
    var body = Data()
    var failure: Error?
    var refused = false
    var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    init(onResponse: ((HTTPURLResponse) throws -> Void)?, sink: ((Data) throws -> Void)?, progress: (@Sendable (Int64) -> Void)?) {
        self.onResponse = onResponse
        self.sink = sink
        self.progress = progress
    }
}

/// Holds the session's tasks by identifier. The delegate is all the session retains, so the owner can
/// invalidate the session when it goes away.
final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Nil for a session that has no key to hold the computer to yet: it takes the first certificate it meets and remembers its fingerprint.
    let pin: Data?
    private let lock = NSLock()
    private var exchanges: [Int: Exchange] = [:]
    private var met: Data?

    init(pin: Data?) {
        self.pin = pin
    }

    var seen: Data? {
        lock.lock()
        defer { lock.unlock() }
        return met
    }

    func add(_ exchange: Exchange, for task: URLSessionTask) {
        lock.lock()
        exchanges[task.taskIdentifier] = exchange
        lock.unlock()
    }

    private func exchange(for task: URLSessionTask) -> Exchange? {
        lock.lock()
        defer { lock.unlock() }
        return exchanges[task.taskIdentifier]
    }

    private func remove(_ task: URLSessionTask) -> Exchange? {
        lock.lock()
        defer { lock.unlock() }
        return exchanges.removeValue(forKey: task.taskIdentifier)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var der: Data?
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            der = SecCertificateCopyData(leaf) as Data
        }
        var accepted = false
        if let pin = pin {
            accepted = PinnedSession.accepts(der, pin: pin)
        } else if let fingerprint = der.flatMap({ SpkiFingerprint.of($0) }) {
            lock.lock()
            met = fingerprint
            lock.unlock()
            accepted = true
        }
        if accepted {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            exchange(for: task)?.refused = true
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let exchange = exchange(for: dataTask), let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        exchange.response = http
        if (200..<300).contains(http.statusCode), let onResponse = exchange.onResponse {
            do {
                try onResponse(http)
            } catch {
                exchange.failure = error
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(for: dataTask), let status = exchange.response?.statusCode else { return }
        if (200..<300).contains(status) {
            if let sink = exchange.sink {
                do {
                    try sink(data)
                } catch {
                    exchange.failure = error
                    dataTask.cancel()
                }
            } else {
                exchange.body.append(data)
            }
        } else if exchange.body.count < 64 * 1024 {
            exchange.body.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        exchange(for: task)?.progress?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = remove(task), let continuation = exchange.continuation else { return }
        if let failure = exchange.failure {
            continuation.resume(throwing: failure)
        } else if exchange.refused {
            continuation.resume(throwing: LinkError.wrongCertificate)
        } else if let error = error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: LinkError.network(error.localizedDescription))
            }
        } else if let response = exchange.response {
            continuation.resume(returning: (exchange.body, response))
        } else {
            continuation.resume(throwing: LinkError.badResponse)
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let late = cancelled
        lock.unlock()
        if late { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }
}

/// The one URLSession for a paired computer. It trusts a certificate only when the SHA-256 of its key is
/// the pin from the pairing code; the system's trust is not asked, as the certificate is self-signed.
/// Ephemeral: nothing cached, no cookies, no proxy.
public final class PinnedSession: @unchecked Sendable {
    private let session: URLSession
    private let delegate: SessionDelegate

    public convenience init(pin: Data) {
        self.init(delegate: SessionDelegate(pin: pin))
    }

    /// A session with no key yet, for the first look at a computer whose code was typed: it takes whatever
    /// certificate answers, and `seen` says which. Nothing but `health` should go over it.
    public convenience init() {
        self.init(delegate: SessionDelegate(pin: nil))
    }

    private init(delegate: SessionDelegate) {
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        // Every request sets its own timeout (pairing waits 130 s, the outbox up to 40), which a shorter one here could cut.
        configuration.timeoutIntervalForRequest = 3600
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// The fingerprint of the certificate the last connection of a keyless session met.
    public var seen: Data? { delegate.seen }

    /// Whether `certificateDER` is the computer's: the SHA-256 of its key is `pin`. Nothing else about the certificate counts.
    public static func accepts(_ certificateDER: Data?, pin: Data) -> Bool {
        guard let der = certificateDER, let fingerprint = SpkiFingerprint.of(der) else { return false }
        return SpkiFingerprint.matches(fingerprint, pin)
    }

    /// Sends `request` (with `body` as its data when given) and returns the answer whatever its status. A 2xx
    /// answer's bytes go to `sink` as they arrive when there is one, after `onResponse` has seen the headers;
    /// an error thrown by either stops the request and is thrown from here.
    func run(_ request: URLRequest, body: Data? = nil, onResponse: ((HTTPURLResponse) throws -> Void)? = nil,
             sink: ((Data) throws -> Void)? = nil, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let exchange = Exchange(onResponse: onResponse, sink: sink, progress: progress)
                exchange.continuation = continuation
                let task: URLSessionTask
                if let body = body {
                    task = session.uploadTask(with: request, from: body)
                } else {
                    task = session.dataTask(with: request)
                }
                delegate.add(exchange, for: task)
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}
