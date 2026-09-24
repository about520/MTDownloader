import Foundation
import Network
import UIKit

// MARK: - 局域网里的设备

struct LANPeer: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var ip: String?
    var port: Int?

    var isResolved: Bool { ip != nil && port != nil }
    var addressText: String {
        if let i = ip, let p = port { return "\(i):\(p)" }
        return "解析中…"
    }
}

// MARK: - 共享目录

enum LANPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 去掉路径分隔符，防止对方传来的文件名把文件写到别的目录
    static func safeName(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = raw.components(separatedBy: bad).joined(separator: "_")
        return cleaned.isEmpty ? "未命名文件" : cleaned
    }

    static func localFiles() -> [(name: String, size: Int64)] {
        let fm = FileManager.default
        let list = (try? fm.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []

        var out: [(name: String, size: Int64)] = []
        for u in list {
            if u.lastPathComponent.hasSuffix(".mtprog") { continue }
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            out.append((u.lastPathComponent, Int64(v?.fileSize ?? 0)))
        }
        out.sort { $0.name < $1.name }
        return out
    }
}

// MARK: - 本机服务端（HTTP + Bonjour 广播）

final class LANServer: ObservableObject {

    static let serviceType = "_mtdl._tcp"

    @Published var isRunning = false
    @Published var port: Int = 0
    @Published var statusText = "未开启"
    @Published var lastEvent = ""

    private var listener: NWListener?
    private var conns: [NWConnection] = []

    var deviceName: String { UIDevice.current.name }

    func start() {
        if listener != nil { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: .any)

            // 挂上 Bonjour 服务，别的装了本 App 的设备就能自动发现
            l.service = NWListener.Service(name: deviceName, type: Self.serviceType)

            l.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    let p = Int(l.port?.rawValue ?? 0)
                    DispatchQueue.main.async {
                        self.port = p
                        self.isRunning = true
                        self.statusText = "可被发现（端口 \(p)）"
                    }
                case .failed(let err):
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.port = 0
                        self.statusText = Self.friendlyError(err)
                    }
                case .cancelled:
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.port = 0
                        self.statusText = "已关闭"
                    }
                default:
                    break
                }
            }

            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }

            l.start(queue: .main)
            self.listener = l
            DispatchQueue.main.async { self.statusText = "正在启动…" }
        } catch {
            statusText = "开启失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in conns { c.cancel() }
        conns.removeAll()
        DispatchQueue.main.async {
            self.isRunning = false
            self.port = 0
            self.statusText = "已关闭"
        }
    }

    // MARK: 接收连接

    private func accept(_ conn: NWConnection) {
        conns.append(conn)
        conn.start(queue: .main)
        readHeader(conn, acc: Data())
    }

    private func drop(_ conn: NWConnection) {
        conn.cancel()
        if let i = conns.firstIndex(where: { $0 === conn }) { conns.remove(at: i) }
    }

    private func readHeader(_ conn: NWConnection, acc: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self = self else { conn.cancel(); return }
            var buf = acc
            if let d = data { buf.append(d) }

            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buf.subdata(in: 0..<r.lowerBound), encoding: .utf8) ?? ""
                let rest = buf.subdata(in: r.upperBound..<buf.count)
                self.serve(conn, header: head, bodySoFar: rest)
                return
            }
            if error != nil || done { self.drop(conn); return }
            self.readHeader(conn, acc: buf)
        }
    }

    // MARK: 解析并路由

    private func serve(_ conn: NWConnection, header: String, bodySoFar: Data) {
        let lines = header.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let reqLine = lines.first else { drop(conn); return }
        let comps = reqLine.components(separatedBy: " ")
        guard comps.count >= 2 else { drop(conn); return }

        let method = comps[0].uppercased()
        let target = comps[1]

        var contentLength = 0
        var rangeHeader: String?
        for l in lines.dropFirst() {
            let lower = l.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(l.components(separatedBy: ":").last?
                    .trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            } else if lower.hasPrefix("range:") {
                rangeHeader = l.components(separatedBy: ":").last?
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        if method == "POST" && bodySoFar.count < contentLength {
            readBody(conn, need: contentLength, have: bodySoFar) { full in
                self.route(conn, method: method, target: target, body: full, range: rangeHeader)
            }
            return
        }
        route(conn, method: method, target: target, body: bodySoFar, range: rangeHeader)
    }

    private func readBody(_ conn: NWConnection, need: Int, have: Data, done: @escaping (Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self else { conn.cancel(); return }
            var buf = have
            if let d = data { buf.append(d) }
            if buf.count >= need || error != nil { done(buf); return }
            self.readBody(conn, need: need, have: buf, done: done)
        }
    }

    private func route(_ conn: NWConnection, method: String, target: String,
                       body: Data, range: String?) {
        let comps = URLComponents(string: "http://local" + target)
        let path = comps?.path ?? "/"
        let fileName = comps?.queryItems?.first(where: { $0.name == "filename" })?.value

        switch (method, path) {
        case ("GET", "/ping"):
            sendText(conn, status: 200, text: "OK")

        case ("GET", "/list"):
            let arr = LANPaths.localFiles().map { ["name": $0.name, "size": $0.size] }
            sendJSON(conn, arr)

        case ("GET", "/file"):
            guard let n = fileName else { sendText(conn, status: 400, text: "缺少 filename"); return }
            sendFile(conn, name: LANPaths.safeName(n), range: range)

        case ("POST", "/upload"):
            guard let n = fileName else { sendText(conn, status: 400, text: "缺少 filename"); return }
            let safe = LANPaths.safeName(n)
            let url = LANPaths.documents.appendingPathComponent(safe)
            do {
                try body.write(to: url)
                DispatchQueue.main.async { self.lastEvent = "收到文件：\(safe)" }
                sendText(conn, status: 200, text: "OK")
            } catch {
                sendText(conn, status: 500, text: "写入失败")
            }

        default:
            sendText(conn, status: 404, text: "Not Found")
        }
    }

    // MARK: 发送响应

    private func send(_ conn: NWConnection, status: Int, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { [weak self] _ in
            self?.drop(conn)
        })
    }

    private func sendText(_ conn: NWConnection, status: Int, text: String) {
        let d = Data(text.utf8)
        send(conn, status: status,
             headers: ["Content-Type": "text/plain; charset=utf-8", "Content-Length": "\(d.count)"],
             body: d)
    }

    private func sendJSON(_ conn: NWConnection, _ obj: [[String: Any]]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else {
            sendText(conn, status: 500, text: "序列化失败"); return
        }
        send(conn, status: 200,
             headers: ["Content-Type": "application/json", "Content-Length": "\(d.count)"],
             body: d)
    }

    private func sendFile(_ conn: NWConnection, name: String, range: String?) {
        let url = LANPaths.documents.appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let attrs = try? fm.attributesOfItem(atPath: url.path),
              let total = attrs[.size] as? Int, total > 0 else {
            sendText(conn, status: 404, text: "文件不存在"); return
        }

        var start = 0
        var end = total - 1
        var status = 200

        if let r = range, let eq = r.range(of: "=") {
            let spec = String(r[eq.upperBound...])
            let parts = spec.components(separatedBy: "-")
            if let s = Int(parts[0].trimmingCharacters(in: .whitespaces)) { start = s }
            if parts.count > 1, let e = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                end = min(e, total - 1)
            }
            status = 206
        }

        guard start >= 0, start < total else { sendText(conn, status: 416, text: "范围无效"); return }
        end = min(end, total - 1)
        let length = end - start + 1

        var headers = [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(length)",
            "Accept-Ranges": "bytes",
        ]
        if status == 206 {
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
        }

        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        guard let fh = try? FileHandle(forReadingFrom: url) else {
            sendText(conn, status: 500, text: "打不开文件"); return
        }
        if start > 0 { fh.seek(toFileOffset: UInt64(start)) }

        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        sendChunks(conn, fh: fh, remaining: length)
    }

    private func sendChunks(_ conn: NWConnection, fh: FileHandle, remaining: Int) {
        if remaining <= 0 { finish(fh, conn); return }
        let n = min(remaining, 256 * 1024)
        let chunk = fh.readData(ofLength: n)
        if chunk.isEmpty { finish(fh, conn); return }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            if err != nil { self.finish(fh, conn); return }
            self.sendChunks(conn, fh: fh, remaining: remaining - chunk.count)
        })
    }

    private func finish(_ fh: FileHandle, _ conn: NWConnection) {
        try? fh.close()
        drop(conn)
    }

    /// 把系统错误翻译成能看懂的提示
    static func friendlyError(_ e: NWError) -> String {
        let s = String(describing: e)
        // -65555 NoAuth = 本地网络权限没放行（iOS 14+ 隐私限制）
        if s.contains("NoAuth") || s.contains("-65555") {
            return "系统没放行：去 设置 → 隐私与安全性 → 本地网络，打开「多线程下载器」的开关"
        }
        if s.contains("EADDRINUSE") {
            return "端口被占用，请稍后再试"
        }
        return "开启失败：\(s)"
    }

    private static func reason(_ code: Int) -> String {        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}

// MARK: - 发现局域网里的其他设备

final class LANFinder: NSObject, ObservableObject, NetServiceDelegate {

    @Published var peers: [LANPeer] = []
    @Published var statusText = "未扫描"

    private var browser: NWBrowser?
    private var resolving: [NetService] = []

    func start() {
        stop()
        let b = NWBrowser(for: .bonjour(type: LANServer.serviceType, domain: nil),
                          using: NWParameters.tcp)

        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            var list: [LANPeer] = []
            for r in results {
                if case let .service(name, type, domain, _) = r.endpoint {
                    list.append(LANPeer(name: name))
                    self.resolve(name: name, type: type, domain: domain)
                }
            }
            list.sort { $0.name < $1.name }
            DispatchQueue.main.async {
                self.peers = list
                self.statusText = list.isEmpty ? "没找到其他设备" : "找到 \(list.count) 台设备"
            }
        }

        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                DispatchQueue.main.async { self?.statusText = LANServer.friendlyError(e) }
            }
        }

        b.start(queue: .main)
        browser = b
        statusText = "扫描中…"
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for s in resolving { s.delegate = nil; s.stop() }
        resolving.removeAll()
    }

    private func resolve(name: String, type: String, domain: String) {
        guard !resolving.contains(where: { $0.name == name }) else { return }
        let svc = NetService(domain: domain, type: type, name: name)
        svc.delegate = self
        svc.resolve(withTimeout: 5)
        resolving.append(svc)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var ip: String?
        for d in sender.addresses ?? [] {
            if let v = Self.ipv4(from: d) { ip = v; break }
        }
        let port = sender.port
        DispatchQueue.main.async {
            if let i = self.peers.firstIndex(where: { $0.name == sender.name }) {
                self.peers[i].ip = ip
                self.peers[i].port = port
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        DispatchQueue.main.async {
            if let i = self.peers.firstIndex(where: { $0.name == sender.name }) {
                self.peers[i].ip = nil
                self.peers[i].port = nil
            }
        }
    }

    /// 从 sockaddr 里取 IPv4 字符串。手算字节，避免依赖 inet_ntop 这类 C 函数。
    static func ipv4(from data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
        return data.withUnsafeBytes { buf -> String? in
            guard let base = buf.baseAddress else { return nil }
            let sa = base.assumingMemoryBound(to: sockaddr.self)
            guard sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
            let sin = base.assumingMemoryBound(to: sockaddr_in.self)
            let raw = sin.pointee.sin_addr.s_addr
            let a = raw & 0xFF
            let b = (raw >> 8) & 0xFF
            let c = (raw >> 16) & 0xFF
            let d = (raw >> 24) & 0xFF
            return "\(a).\(b).\(c).\(d)"
        }
    }
}

// MARK: - 访问对方设备

final class LANClient: ObservableObject {

    struct RemoteFile: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var size: Int64
    }

    @Published var remoteFiles: [RemoteFile] = []
    @Published var message = ""

    func fetchList(host: String, port: Int) {
        guard let u = URL(string: "http://\(host):\(port)/list") else { return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, error in
            guard let self = self else { return }
            if let e = error {
                DispatchQueue.main.async { self.message = "连不上：\(e.localizedDescription)" }
                return
            }
            guard let data = data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                DispatchQueue.main.async { self.message = "返回内容无法解析" }
                return
            }
            var out: [RemoteFile] = []
            for it in arr {
                let n = it["name"] as? String ?? ""
                let s = it["size"] as? Int ?? 0
                if !n.isEmpty { out.append(RemoteFile(name: n, size: Int64(s))) }
            }
            DispatchQueue.main.async {
                self.remoteFiles = out
                self.message = out.isEmpty ? "对方还没有文件" : "对方有 \(out.count) 个文件"
            }
        }.resume()
    }

    /// 从对方拉文件。返回直链，交给多线程下载器，所以也是分片并发下载。
    func fileURL(host: String, port: Int, name: String) -> URL? {
        guard let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "http://\(host):\(port)/file?filename=\(enc)")
    }

    /// 把本地文件推给对方
    func upload(localName: String, to host: String, port: Int) {
        guard let enc = localName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "http://\(host):\(port)/upload?filename=\(enc)") else {
            message = "文件名编码失败"
            return
        }
        let src = LANPaths.documents.appendingPathComponent(localName)
        var req = URLRequest(url: u)
        req.httpMethod = "POST"

        DispatchQueue.main.async { self.message = "正在发送 \(localName)…" }

        URLSession.shared.uploadTask(with: req, fromFile: src) { [weak self] _, resp, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let e = error {
                    self.message = "发送失败：\(e.localizedDescription)"
                } else {
                    self.message = "已发送 \(localName)"
                }
            }
        }.resume()
    }
}
