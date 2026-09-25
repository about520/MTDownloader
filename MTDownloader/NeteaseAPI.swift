import Foundation

// MARK: - 数据模型

struct NeteaseSong: Identifiable, Hashable {
    let id: Int
    var name: String
    var artists: String
    var album: String
    var durationMs: Int
    /// 0=免费  1=付费单曲(通常只给30秒试听)  4=需购专辑  8=会员限定(多数可拿完整320k)
    var fee: Int

    var durationText: String {
        let s = max(0, durationMs / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 实测：几乎所有歌曲都能拿到直链，包括 fee=1/8。
    /// 差别在于会员/付费歌可能只下发 30 秒试听片段，所以不再用 fee 来拦截。
    var canDownload: Bool { true }

    var feeText: String {
        switch fee {
        case 0:  return "免费"
        case 1:  return "付费单曲"
        case 4:  return "需购专辑"
        case 8:  return "会员"
        default: return "受限"
        }
    }

    /// 根据体积与时长判断是不是完整版。
    /// 试听片段固定约 30 秒（128k 下约 480KB），远小于曲长应有的体积。
    func isFull(size: Int64, bitrate: Int) -> Bool {
        guard durationMs > 0, bitrate > 0, size > 0 else { return true }
        let expected = Double(durationMs) / 1000.0 * (Double(bitrate) / 8.0)
        return Double(size) > expected * 0.75
    }

    /// 存成「歌名 - 歌手.mp3」，斜杠换成全角避免路径问题
    var suggestedFileName: String {
        let raw = artists.isEmpty ? name : "\(name) - \(artists)"
        let cleaned = raw.replacingOccurrences(of: "/", with: "／")
        return cleaned + ".mp3"
    }
}

struct NeteaseArtist: Identifiable, Hashable {
    let id: Int
    var name: String
}

struct NeteasePlaylist: Identifiable, Hashable {
    let id: Int
    var name: String
    var trackCount: Int
}

/// 取链结果
struct NeteaseLink {
    let url: String
    let size: Int64
    let bitrate: Int
    /// true=完整版；false=只有约30秒试听
    let isFull: Bool
    /// 实际使用的曲目（自动换版本后会是另一首）
    let song: NeteaseSong
    /// 是否发生过「同曲换版本」
    let swapped: Bool

    var qualityText: String {
        let k = bitrate / 1000
        return "\(k)k"
    }
}

// MARK: - API

/// 网易云音乐 Web 接口。
///
/// 实测结论（2026-09 修正版）：
/// - 取链接口必须带 br 参数，否则返回 400/null
/// - 榜单 336 首抽样：全部都能拿到直链；其中 180 首是完整版
///   （完整版里 175 首是 fee=8 会员歌，可拿 320k），156 首只有 30 秒试听（全为 fee=1）
/// - 所以「按 fee 拦截」是错的，会白白丢掉大量会员完整版
/// - 试听片段是硬版权限制：匿名 cookie / 换 UA / download 接口（301 需登录）均无效，
///   唯一正解是用户自己的会员 Cookie（MUSIC_U）
/// - 试听片段可用「同曲换版本」救回：搜同名歌，其他版本（Live/翻唱/原唱）常是完整版
/// - CDN 直链不需要 Referer，支持 Range 分片（可多线程下载）
final class NeteaseAPI {

    static let shared = NeteaseAPI()

    enum SearchKind: String, CaseIterable, Identifiable {
        case song, artist, playlist
        var id: String { rawValue }

        var title: String {
            switch self {
            case .song:     return "歌曲"
            case .artist:   return "歌手"
            case .playlist: return "歌单"
            }
        }

        /// 网易搜索接口的类型码
        var code: Int {
            switch self {
            case .song:     return 1
            case .artist:   return 100
            case .playlist: return 1000
            }
        }
    }

    private let base = "https://music.163.com/api"
    private let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
                     "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 码率档位，从高到低依次尝试，取第一个有直链的
    private let ladder = [999000, 320000, 192000, 128000]

    private static let cookieKey = "netease_cookie"

    /// 用户粘贴的会员 Cookie（含 MUSIC_U），为空则用游客标识
    var cookie: String {
        get { UserDefaults.standard.string(forKey: Self.cookieKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.cookieKey) }
    }

    var isLoggedIn: Bool { !cookie.isEmpty }

    private var effectiveCookie: String {
        cookie.isEmpty ? "appver=2.9.7; os=pc" : cookie
    }

    private init() {}

    // MARK: 基础请求

    private func request(_ urlString: String,
                         completion: @escaping ([String: Any]?) -> Void) {
        guard let u = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var req = URLRequest(url: u, timeoutInterval: 25)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue(effectiveCookie, forHTTPHeaderField: "Cookie")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(dict) }
        }.resume()
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }

    /// JSON 里的数字可能是 NSNumber/Int/Double，统一取 Int64
    private static func int64(_ any: Any?) -> Int64 {
        if let n = any as? NSNumber { return n.int64Value }
        if let i = any as? Int { return Int64(i) }
        if let d = any as? Double { return Int64(d) }
        return 0
    }

    private static func int(_ any: Any?) -> Int {
        Int(int64(any))
    }

    static func parseSong(_ d: [String: Any]) -> NeteaseSong? {
        guard let id = int_opt(d["id"]), id > 0 else { return nil }
        let name = d["name"] as? String ?? "未知曲目"

        var artists = ""
        if let arr = d["artists"] as? [[String: Any]] {
            artists = arr.compactMap { $0["name"] as? String }
                         .filter { !$0.isEmpty }
                         .joined(separator: "、")
        }
        // 搜索结果里 artists[].name 有时是空的，退回用 album.artist.name
        if artists.isEmpty,
           let al = d["album"] as? [String: Any],
           let ar = al["artist"] as? [String: Any],
           let n = ar["name"] as? String, !n.isEmpty {
            artists = n
        }

        var album = ""
        if let al = d["album"] as? [String: Any] {
            album = al["name"] as? String ?? ""
        }

        let dur = int(d["duration"])
        let fee = int(d["fee"])
        return NeteaseSong(id: id, name: name, artists: artists,
                           album: album, durationMs: dur, fee: fee)
    }

    private static func int_opt(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    // MARK: 账号

    /// 校验 Cookie 是否有效，返回描述文字
    func checkLogin(completion: @escaping (String) -> Void) {
        guard isLoggedIn else {
            completion("未登录")
            return
        }
        request("\(base)/w/nuser/account/get") { dict in
            guard let p = dict?["profile"] as? [String: Any],
                  let nick = p["nickname"] as? String else {
                completion("Cookie 无效或已过期")
                return
            }
            let vip = Self.int(p["vipType"])
            let vipText = vip > 0 ? "会员 v\(vip)" : "非会员"
            completion("\(nick) · \(vipText)")
        }
    }

    // MARK: 搜索

    func searchSongs(_ keyword: String, completion: @escaping ([NeteaseSong]) -> Void) {
        let url = "\(base)/search/get/web?s=\(Self.encode(keyword))&type=1&offset=0&limit=40"
        request(url) { dict in
            let arr = (dict?["result"] as? [String: Any])?["songs"] as? [[String: Any]]
            completion((arr ?? []).compactMap { Self.parseSong($0) })
        }
    }

    func searchArtists(_ keyword: String, completion: @escaping ([NeteaseArtist]) -> Void) {
        let url = "\(base)/search/get/web?s=\(Self.encode(keyword))&type=100&offset=0&limit=30"
        request(url) { dict in
            let arr = (dict?["result"] as? [String: Any])?["artists"] as? [[String: Any]]
            let list = (arr ?? []).compactMap { d -> NeteaseArtist? in
                guard let id = Self.int_opt(d["id"]) else { return nil }
                return NeteaseArtist(id: id, name: d["name"] as? String ?? "未知歌手")
            }
            completion(list)
        }
    }

    func searchPlaylists(_ keyword: String, completion: @escaping ([NeteasePlaylist]) -> Void) {
        let url = "\(base)/search/get/web?s=\(Self.encode(keyword))&type=1000&offset=0&limit=30"
        request(url) { dict in
            let arr = (dict?["result"] as? [String: Any])?["playlists"] as? [[String: Any]]
            let list = (arr ?? []).compactMap { d -> NeteasePlaylist? in
                guard let id = Self.int_opt(d["id"]) else { return nil }
                return NeteasePlaylist(id: id,
                                       name: d["name"] as? String ?? "未知歌单",
                                       trackCount: Self.int(d["trackCount"]))
            }
            completion(list)
        }
    }

    // MARK: 下钻

    /// 歌手热门歌曲（实测稳定返回 50 首）
    func artistSongs(_ artistId: Int, completion: @escaping ([NeteaseSong]) -> Void) {
        request("\(base)/artist/top/song?id=\(artistId)") { dict in
            let arr = dict?["songs"] as? [[String: Any]]
            completion((arr ?? []).compactMap { Self.parseSong($0) })
        }
    }

    /// 歌单歌曲。部分歌单只返回前若干首，这是服务端限制。
    func playlistSongs(_ playlistId: Int, completion: @escaping ([NeteaseSong]) -> Void) {
        request("\(base)/playlist/detail?id=\(playlistId)") { dict in
            let result = dict?["result"] as? [String: Any]
            let arr = result?["tracks"] as? [[String: Any]]
            completion((arr ?? []).compactMap { Self.parseSong($0) })
        }
    }

    // MARK: 取直链

    private struct Raw {
        let url: String
        let size: Int64
        let bitrate: Int
    }

    /// 依次尝试各码率档位，返回第一个有直链的结果
    private func fetchRaw(_ songId: Int,
                          idx: Int = 0,
                          completion: @escaping (Raw?) -> Void) {
        guard idx < ladder.count else {
            completion(nil)
            return
        }
        let br = ladder[idx]
        let url = "\(base)/song/enhance/player/url?br=\(br)&ids=%5B\(songId)%5D"
        request(url) { dict in
            guard let d = (dict?["data"] as? [[String: Any]])?.first,
                  let u = d["url"] as? String, !u.isEmpty else {
                self.fetchRaw(songId, idx: idx + 1, completion: completion)
                return
            }
            let outBitrate = Self.int(d["br"])
            completion(Raw(url: u,
                           size: Self.int64(d["size"]),
                           bitrate: outBitrate > 0 ? outBitrate : br))
        }
    }

    /// 主入口：取最佳直链。
    /// - 先按码率档位取链
    /// - 若判断为试听片段且 allowSwap，则自动搜索同名歌找完整版本
    func fetchLink(for song: NeteaseSong,
                   allowSwap: Bool = true,
                   completion: @escaping (NeteaseLink?) -> Void) {
        fetchRaw(song.id) { raw in
            guard let r = raw else {
                completion(nil)
                return
            }
            let full = song.isFull(size: r.size, bitrate: r.bitrate)
            if full || !allowSwap {
                completion(NeteaseLink(url: r.url, size: r.size, bitrate: r.bitrate,
                                       isFull: full, song: song, swapped: false))
                return
            }
            // 试听片段 → 找同名歌的其他完整版本
            self.findFullVersion(of: song) { alt in
                completion(alt ?? NeteaseLink(url: r.url, size: r.size, bitrate: r.bitrate,
                                              isFull: false, song: song, swapped: false))
            }
        }
    }

    /// 同曲换版本：搜同名歌，逐个取链，返回第一个完整版
    private func findFullVersion(of song: NeteaseSong,
                                 completion: @escaping (NeteaseLink?) -> Void) {
        searchSongs(song.name) { list in
            let cands = Array(list.filter { $0.id != song.id }.prefix(8))
            self.tryCandidates(cands, idx: 0, completion: completion)
        }
    }

    private func tryCandidates(_ cands: [NeteaseSong],
                               idx: Int,
                               completion: @escaping (NeteaseLink?) -> Void) {
        guard idx < cands.count else {
            completion(nil)
            return
        }
        let s = cands[idx]
        fetchRaw(s.id) { r in
            guard let r = r, s.isFull(size: r.size, bitrate: r.bitrate) else {
                self.tryCandidates(cands, idx: idx + 1, completion: completion)
                return
            }
            completion(NeteaseLink(url: r.url, size: r.size, bitrate: r.bitrate,
                                   isFull: true, song: s, swapped: true))
        }
    }

    /// 兜底：老的外链接口，直接 302 到音频。付费歌会返回一个 HTML 错误页。
    func outerURL(_ songId: Int) -> String {
        "https://music.163.com/song/media/outer/url?id=\(songId).mp3"
    }
}
