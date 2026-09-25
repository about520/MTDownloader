import Foundation
import SwiftUI

// MARK: - 续传用的快照

struct ChunkSnapshot: Codable {
    let index: Int
    let start: Int64
    let end: Int64
    let done: Int64
}

struct TaskSnapshot: Codable {
    let url: String
    let fileName: String
    let total: Int64
    let threads: Int
    let chunks: [ChunkSnapshot]
}

// MARK: - 工具函数

func formatBytes(_ b: Int64) -> String {
    if b < 0 { return "-" }
    var v = Double(b)
    let units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while v >= 1024 && i < units.count - 1 {
        v /= 1024
        i += 1
    }
    if i == 0 { return String(format: "%.0f %@", v, units[i]) }
    return String(format: "%.2f %@", v, units[i])
}

func formatSpeed(_ bps: Double) -> String {
    if bps <= 0 { return "—" }
    return formatBytes(Int64(bps)) + "/s"
}

// MARK: - 下载管理器

final class DownloadManager: NSObject, ObservableObject, ChunkDelegate {

    @Published var status: String = "待机"
    @Published var totalBytes: Int64 = 0
    @Published var doneBytes: Int64 = 0
    @Published var speedBps: Double = 0
    @Published var fileName: String = ""
    @Published var errorText: String = ""

    private var chunks: [ChunkDownloader] = []
    private var fileHandle: FileHandle?
    private var outPath: String = ""
    private var progPath: String = ""
    private var sourceURL: URL?
    private var threadCount: Int = 8
    private var isRunning = false

    private let ioLock = NSLock()
    private let stateLock = NSLock()
    private var rawDone: Int64 = 0
    private var lastSampleBytes: Int64 = 0
    private var lastSampleDate: Date = Date()
    private var ticker: Timer?

    // MARK: 对外接口

    /// 文件名覆盖。音乐下载时用「歌名 - 歌手.mp3」，
    /// 否则只能拿到 CDN 那串哈希名。每次 start 会重置。
    private var preferredName: String?

    func start(urlString: String, threads: Int, preferredName: String? = nil) {
        let text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { setError("请先填写下载链接"); return }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            setError("URL 格式不对（需要 http/https）")
            return
        }
        guard !isRunning else { return }

        sourceURL = url
        threadCount = max(1, min(threads, 32))
        self.preferredName = preferredName

        DispatchQueue.main.async {
            self.errorText = ""
            self.status = "正在探测文件…"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.probeAndBegin(url: url)
        }
    }

    func pause() {
        guard isRunning else { return }
        isRunning = false
        for c in chunks { c.stop() }
        try? fileHandle?.synchronize()
        saveProgress()
        stopTicker()
        DispatchQueue.main.async {
            self.status = "已暂停"
            self.speedBps = 0
        }
    }

    func resume() {
        guard !isRunning, !chunks.isEmpty else { return }
        isRunning = true
        lastSampleBytes = rawDone
        lastSampleDate = Date()
        DispatchQueue.main.async { self.status = "下载中" }
        startTicker()
        for c in chunks { c.resume() }
    }

    func cancelAndDelete() {
        isRunning = false
        for c in chunks { c.stop() }
        try? fileHandle?.close()
        fileHandle = nil
        stopTicker()
        if !outPath.isEmpty { try? FileManager.default.removeItem(atPath: outPath) }
        if !progPath.isEmpty { try? FileManager.default.removeItem(atPath: progPath) }
        chunks = []
        rawDone = 0
        DispatchQueue.main.async {
            self.totalBytes = 0
            self.doneBytes = 0
            self.speedBps = 0
            self.status = "待机"
            self.fileName = ""
        }
    }

    // MARK: 探测 + 建任务

    private func probeAndBegin(url: URL) {
        var total: Int64 = 0

        // 1) HEAD
        let sem1 = DispatchSemaphore(value: 0)
        var req1 = URLRequest(url: url, timeoutInterval: 30)
        req1.httpMethod = "HEAD"
        req1.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        URLSession.shared.dataTask(with: req1) { _, resp, _ in
            defer { sem1.signal() }
            if let http = resp as? HTTPURLResponse {
                total = Self.contentLength(from: http) ?? 0
            }
        }.resume()
        sem1.wait()

        // 2) 兜底：Range GET 读 Content-Range
        if total <= 0 {
            let sem2 = DispatchSemaphore(value: 0)
            var req2 = URLRequest(url: url, timeoutInterval: 30)
            req2.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            req2.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            URLSession.shared.dataTask(with: req2) { _, resp, _ in
                defer { sem2.signal() }
                if let http = resp as? HTTPURLResponse,
                   let cr = http.allHeaderFields["Content-Range"] as? String,
                   let slash = cr.lastIndex(of: "/") {
                    let tail = String(cr[cr.index(after: slash)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    total = Int64(tail) ?? 0
                }
            }.resume()
            sem2.wait()
        }

        guard total > 0 else {
            setError("探测不到文件大小，该链接可能不支持分片下载或已失效")
            return
        }

        let name = (self.preferredName?.isEmpty == false)
            ? self.preferredName!
            : Self.suggestedFileName(for: url)
        begin(url: url, total: total, fileName: name)
    }

    private func begin(url: URL, total: Int64, fileName name: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var dest = docs.appendingPathComponent(name)

        // 已存在同名文件且没有进度文件 -> 换名，避免误覆盖
        if FileManager.default.fileExists(atPath: dest.path),
           !FileManager.default.fileExists(atPath: dest.path + ".mtprog") {
            dest = docs.appendingPathComponent(Self.avoidCollision(name))
        }

        outPath = dest.path
        progPath = dest.path + ".mtprog"

        if !FileManager.default.fileExists(atPath: dest.path) {
            FileManager.default.createFile(atPath: dest.path, contents: nil, attributes: nil)
        }
        guard let fh = try? FileHandle(forWritingAtPath: dest.path) else {
            setError("无法在 App 内创建文件")
            return
        }
        fh.truncateFile(atOffset: UInt64(total))
        fileHandle = fh

        // 分片
        let n = threadCount
        let step = total / Int64(n)
        var restored: [Int64] = Array(repeating: 0, count: n)

        if let data = FileManager.default.contents(atPath: progPath),
           let snap = try? JSONDecoder().decode(TaskSnapshot.self, from: data),
           snap.total == total,
           snap.url == url.absoluteString,
           snap.chunks.count == n {
            restored = snap.chunks.map { $0.done }
            rawDone = snap.chunks.reduce(0) { $0 + $1.done }
        }

        var list: [ChunkDownloader] = []
        for i in 0..<n {
            let s = Int64(i) * step
            let e = (i == n - 1) ? (total - 1) : (s + step - 1)
            let done = min(restored[i], e - s + 1)
            list.append(ChunkDownloader(index: i, start: s, end: e, url: url,
                                        fileHandle: fh, ioLock: ioLock, written: done))
        }
        chunks = list

        DispatchQueue.main.async {
            self.totalBytes = total
            self.doneBytes = self.rawDone
            self.fileName = dest.lastPathComponent
            self.status = "下载中"
        }

        isRunning = true
        lastSampleBytes = rawDone
        lastSampleDate = Date()
        startTicker()
        for c in chunks {
            c.delegate = self
            c.resume()
        }
    }

    // MARK: ChunkDelegate

    func chunk(_ chunk: ChunkDownloader, didReceiveBytes count: Int64) {
        stateLock.lock()
        rawDone += count
        stateLock.unlock()
    }

    func chunkDidFinish(_ chunk: ChunkDownloader) {
        checkAllDone()
    }

    func chunk(_ chunk: ChunkDownloader, didFailWithError error: Error?, cancelled: Bool) {
        if cancelled { return }
        if let e = error { print("[MT] chunk \(chunk.index) 失败: \(e)") }
        guard isRunning else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.isRunning == true {
                chunk.resume()
            }
        }
    }

    private func checkAllDone() {
        guard isRunning else { return }
        guard chunks.allSatisfy({ $0.isFinished }) else { return }

        isRunning = false
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(atPath: progPath)
        stopTicker()
        DispatchQueue.main.async {
            self.doneBytes = self.totalBytes
            self.speedBps = 0
            self.status = "已完成"
        }
    }

    // MARK: 计时器 / 续传

    private func startTicker() {
        DispatchQueue.main.async {
            self.ticker?.invalidate()
            let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let s = self else { return }
                let now = Date()
                let dt = now.timeIntervalSince(s.lastSampleDate)
                s.stateLock.lock()
                let cur = s.rawDone
                s.stateLock.unlock()
                if dt >= 0.5 {
                    s.speedBps = Double(cur - s.lastSampleBytes) / dt
                    s.lastSampleBytes = cur
                    s.lastSampleDate = now
                }
                s.doneBytes = cur
                s.saveProgress()
            }
            self.ticker = t
        }
    }

    private func stopTicker() {
        DispatchQueue.main.async {
            self.ticker?.invalidate()
            self.ticker = nil
        }
    }

    private func saveProgress() {
        guard !outPath.isEmpty, totalBytes > 0 else { return }
        let snaps = chunks.map {
            ChunkSnapshot(index: $0.index, start: $0.start, end: $0.end, done: $0.written)
        }
        let snap = TaskSnapshot(url: sourceURL?.absoluteString ?? "",
                                fileName: fileName,
                                total: totalBytes,
                                threads: threadCount,
                                chunks: snaps)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: URL(fileURLWithPath: progPath), options: .atomic)
        }
    }

    private func setError(_ msg: String) {
        DispatchQueue.main.async {
            self.errorText = msg
            self.status = "出错"
        }
    }

    // MARK: 辅助

    private static func contentLength(from http: HTTPURLResponse) -> Int64? {
        if let s = http.allHeaderFields["Content-Length"] as? String { return Int64(s) }
        if let n = http.allHeaderFields["Content-Length"] as? NSNumber { return n.int64Value }
        if http.expectedContentLength > 0 { return http.expectedContentLength }
        return nil
    }

    /// 优先取 URL 里的 filename= 参数（123云盘这类直链常见），否则用路径最后一段
    private static func suggestedFileName(for url: URL) -> String {
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let fn = comps.queryItems?.first(where: { $0.name.lowercased() == "filename" })?.value,
           !fn.isEmpty {
            return (fn.removingPercentEncoding ?? fn)
        }
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if !last.isEmpty, last.contains(".") { return last }
        return "download.bin"
    }

    private static func avoidCollision(_ name: String) -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        if ext.isEmpty { return "\(base)_\(stamp)" }
        return "\(base)_\(stamp).\(ext)"
    }
}
