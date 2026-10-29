import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "webdav-bg")

/// ★ 2026-10-29（饭耳移植 · 规格 §2.3 上传通道 · CFNetwork BackgroundSession）
///
/// Background `URLSession` for WebDAV uploads: audio files are the payload
/// that actually needs this — a transcript is a few KB and the foreground
/// path finishes it before the app can be killed, but a 60-minute recording
/// at 29 MB/h is ~28 MB, and iOS suspends the app long before a foreground
/// task of that size drains over cellular.
///
/// How it fits together (Apple's lifecycle, no shortcuts):
///   · Session id `com.nomily.app.webdav.upload`, created once by the
///     singleton (background sessions must outlive any view).
///   · `enqueue` does the cheap `MKCOL` **in the foreground first** (the
///     background task itself cannot be relied on for sequencing), then hands
///     the PUT to the daemon.
///   · When iOS needs to wake the app for session events (including relaunch
///     after the app was killed), `AppDelegate.handleEventsForBackgroundURLSession`
///     routes into `handleEvents(completionHandler:)` — that call chain is
///     what keeps the process alive while the delegate finishes.
///   · Per-task results arrive in `didCompleteWithError`; the sync page picks
///     them up via the `webdavBackgroundUploadDidFinish` notification.
///
/// Transcripts deliberately stay on the foreground path in
/// `WebDAVSyncService` — only audio is queued here.
final class WebDAVBackgroundUploader: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    static let shared = WebDAVBackgroundUploader()
    static let sessionIdentifier = "com.nomily.app.webdav.upload"
    static let didFinishNotification = Notification.Name("webdavBackgroundUploadDidFinish")

    private var session: URLSession!
    /// Held between `handleEvents` and `urlSessionDidFinishEvents`.
    private var backgroundCompletionHandler: (() -> Void)?

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 15 * 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit {
        session?.finishTasksAndInvalidate()
    }

    /// Queue a file for upload. Directories must already exist (`ensureDirectories`
    /// is done by the caller in the foreground).
    func enqueue(fileAt localURL: URL, to remotePath: String, client: WebDAVClient) {
        guard let url = client.url(forPath: remotePath) else {
            log.error("bad remote path \(remotePath, privacy: .public)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let credential = Data("\(client.username):\(client.password)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        let task = session.uploadTask(with: request, fromFile: localURL)
        task.taskDescription = remotePath
        task.resume()
        log.notice("queued upload \(remotePath, privacy: .public) (task \(task.currentRequest?.url?.absoluteString ?? "?", privacy: .public))")
    }

    // MARK: - Lifecycle (called from AppDelegate)

    /// iOS woke the process for this session's events; store the completion
    /// handler until `urlSessionDidFinishEvents` fires.
    func handleEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error {
            log.error("background session invalid: \(error.localizedDescription, privacy: .public)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let path = task.taskDescription ?? "?"
        if let error {
            log.error("upload \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            log.notice("upload \(path, privacy: .public) done (HTTP \(status))")
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didFinishNotification, object: nil)
        }
    }
}
