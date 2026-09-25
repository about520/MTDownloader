import Foundation

// MARK: - 数据模型

struct NeteaseSong: Identifiable, Hashable {
    let id: Int
    var name: String
    var artists: String
    var album: String
    var durationMs: Int
    /// 0=免费可下载  1=付费单曲  4=需购专辑  8=会员限定
    var fee: Int

    var durationText: String {
        let s = max(0, durationMs / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var canDownload: Bool { fee == 0 }

    var feeText: String {
        switch fee {
        case 0:  return "可下载"
        case 1:  return "付费单曲"
        case 4:  return "需购专辑"
        case 8:  return "会员限定"
        default: return "受限"
        }
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

// MARK: - API

/// 网易云音乐 Web 接口。
///
/// 实测结论（2026-09）：
/// - 搜索（歌曲/歌手/歌单）正常返回
/// - 只有 fee=0 的免费歌曲能拿到直链，付费/会员歌服务端返回 url=null
/// - CDN 直链不需要 Referer，且支持 Range 分片（可多线程下载）
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

    private init() {}

    private func request(_ urlString: String,
                         completion: @escaping ([String: Any]?) -> Void) {
        guard let u = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var req = URLRequest(url: u, timeoutInterval: 25)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("appver=2.0.2", forHTTPHeaderField: "Cookie")
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

    static func parseSong(_ d: [String: Any]) -> NeteaseSong? {
        guard let id = d["id"] as? Int else { return nil }
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

        let dur = d["duration"] as? Int ?? 0
        let fee = d["fee"] as? Int ?? 1
        return NeteaseSong(id: id, name: name, artists: artists,
                           album: album, durationMs: dur, fee: fee)
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
                guard let id = d["id"] as? Int else { return nil }
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
                guard let id = d["id"] as? Int else { return nil }
                return NeteasePlaylist(id: id,
                                       name: d["name"] as? String ?? "未知歌单",
                                       trackCount: d["trackCount"] as? Int ?? 0)
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

    /// 只有免费歌能拿到；付费/会员歌返回 nil。
    /// ids 参数必须带方括号，这里用百分号编码（%5B/%5D），
    /// 因为 Swift 的 URL(string:) 对方括号比较挑剔。
    func songURL(_ songId: Int, bitrate: Int = 320000,
                 completion: @escaping (String?) -> Void) {
        let url = "\(base)/song/enhance/player/url?id=\(songId)" +
                  "&ids=%5B\(songId)%5D&br=\(bitrate)"
        request(url) { dict in
            let arr = dict?["data"] as? [[String: Any]]
            let u = arr?.first?["url"] as? String
            completion((u?.isEmpty == false) ? u : nil)
        }
    }

    /// 兜底：老的外链接口，直接 302 到音频。付费歌会返回一个 HTML 错误页。
    func outerURL(_ songId: Int) -> String {
        "https://music.163.com/song/media/outer/url?id=\(songId).mp3"
    }
}
