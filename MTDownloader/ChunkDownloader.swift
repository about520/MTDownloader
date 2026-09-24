import Foundation

protocol ChunkDelegate: AnyObject {
    func chunk(_ chunk: ChunkDownloader, didReceiveBytes count: Int64)
    func chunkDidFinish(_ chunk: ChunkDownloader)
    func chunk(_ chunk: ChunkDownloader, didFailWithError error: Error?, cancelled: Bool)
}

/// 单个分片下载器。
/// 用 Range 请求只负责自己那段字节，收到数据后 seek 到对应偏移写入同一个文件。
final class ChunkDownloader: NSObject, URLSessionDataDelegate {

    let index: Int
    let start: Int64
    let end: Int64
    private let url: URL
    private let fileHandle: FileHandle
    private let ioLock: NSLock

    private(set) var written: Int64

    weak var delegate: ChunkDelegate?

    private var session: URLSession?
    private var task: URLSessionDataTask?

    var totalBytes: Int64 { end - start + 1 }
    var isFinished: Bool { written >= totalBytes }

    init(index: Int,
         start: Int64,
         end: Int64,
         url: URL,
         fileHandle: FileHandle,
         ioLock: NSLock,
         written: Int64) {
        self.index = index
        self.start = start
        self.end = end
        self.url = url
        self.fileHandle = fileHandle
        self.ioLock = ioLock
        self.written = written
        super.init()
    }

    /// 注意：不能叫 start()，因为类里已有一个叫 start 的 Int64 属性（起始偏移），会重名。
    func resume() {
        guard task == nil, !isFinished else { return }

        var req = URLRequest(url: url,
                             cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 60)
        req.httpMethod = "GET"
        req.setValue("bytes=\(start + written)-\(end)", forHTTPHeaderField: "Range")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 7200

        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        let t = s.dataTask(with: req)
        task = t
        t.resume()
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        let n = Int64(data.count)
        ioLock.lock()
        fileHandle.seek(toFileOffset: UInt64(start + written))
        try? fileHandle.write(data)
        written += n
        ioLock.unlock()
        delegate?.chunk(self, didReceiveBytes: n)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        self.task = nil
        self.session?.invalidateAndCancel()
        self.session = nil

        if let e = error as NSError? {
            let isCancel = (e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled)
            delegate?.chunk(self, didFailWithError: isCancel ? nil : e, cancelled: isCancel)
        } else {
            delegate?.chunkDidFinish(self)
        }
    }
}
