import SwiftUI

// MARK: - 搜索页

struct MusicView: View {

    @EnvironmentObject private var dm: DownloadManager

    @State private var keyword = ""
    @State private var kind: NeteaseAPI.SearchKind = .song
    @State private var songs: [NeteaseSong] = []
    @State private var artists: [NeteaseArtist] = []
    @State private var playlists: [NeteasePlaylist] = []
    @State private var loading = false
    @State private var note = ""
    @State private var showCookie = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("类型", selection: $kind) {
                    ForEach(NeteaseAPI.SearchKind.allCases) { k in
                        Text(k.title).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                HStack(spacing: 8) {
                    TextField("搜歌名 / 歌手 / 歌单", text: $keyword)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .onSubmit { search() }
                    Button("搜索") { search() }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                if loading {
                    ProgressView().padding(.vertical, 6)
                }
                if !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }

                content
            }
            .navigationTitle("音乐")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCookie = true
                    } label: {
                        Image(systemName: NeteaseAPI.shared.isLoggedIn
                              ? "person.crop.circle.fill"
                              : "person.crop.circle")
                    }
                }
            }
            .sheet(isPresented: $showCookie) {
                CookieSettingsView()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .song:
            if songs.isEmpty && !loading {
                placeholder("输入关键词搜歌名、歌手或歌单")
            } else {
                List(songs) { SongRow(song: $0) }
            }

        case .artist:
            if artists.isEmpty && !loading {
                placeholder("搜歌手，点进去看他的热门歌曲")
            } else {
                List(artists) { a in
                    NavigationLink {
                        ArtistSongsView(artist: a)
                    } label: {
                        Label(a.name, systemImage: "person.crop.circle")
                    }
                }
            }

        case .playlist:
            if playlists.isEmpty && !loading {
                placeholder("搜歌单，点进去看里面的歌")
            } else {
                List(playlists) { p in
                    NavigationLink {
                        PlaylistSongsView(playlist: p)
                    } label: {
                        HStack {
                            Text(p.name).font(.subheadline).lineLimit(2)
                            Spacer()
                            Text("\(p.trackCount) 首")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func search() {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { note = "先输入关键词"; return }

        loading = true
        note = ""
        songs = []
        artists = []
        playlists = []

        switch kind {
        case .song:
            NeteaseAPI.shared.searchSongs(kw) { r in
                loading = false
                songs = r
                note = r.isEmpty ? "没搜到歌曲" : "找到 \(r.count) 首，点下载自动取最佳音质"
            }
        case .artist:
            NeteaseAPI.shared.searchArtists(kw) { r in
                loading = false
                artists = r
                note = r.isEmpty ? "没搜到歌手" : "找到 \(r.count) 位歌手"
            }
        case .playlist:
            NeteaseAPI.shared.searchPlaylists(kw) { r in
                loading = false
                playlists = r
                note = r.isEmpty ? "没搜到歌单" : "找到 \(r.count) 个歌单"
            }
        }
    }
}

// MARK: - Cookie 设置（会员解锁）

struct CookieSettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var text = NeteaseAPI.shared.cookie
    @State private var status = ""
    @State private var checking = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("粘贴网易云 Cookie 可解锁会员歌曲的完整版与无损音质。")
                    .font(.subheadline)

                Text("获取方法：电脑浏览器打开 music.163.com 并登录 → 按 F12 → Network → 任选一条请求 → 复制 Request Headers 里的 Cookie 整行（需包含 MUSIC_U）。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $text)
                    .font(.caption2)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)

                HStack(spacing: 10) {
                    Button("保存并校验") {
                        NeteaseAPI.shared.cookie = text
                        checking = true
                        status = ""
                        NeteaseAPI.shared.checkLogin { s in
                            checking = false
                            status = s
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("清空") {
                        text = ""
                        NeteaseAPI.shared.cookie = ""
                        status = "已清空，将按游客方式取链"
                    }

                    if checking { ProgressView() }
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(status.contains("会员") || status.contains("·")
                                         ? .green : .orange)
                }

                Text("不填也能用：多数会员歌曲（fee=8）本身就能拿到完整 320k；只有少数付费单曲（fee=1）是 30 秒试听，此时 App 会自动搜索同名歌的完整版本替代。")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(16)
            .navigationTitle("会员 Cookie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 单曲行

struct SongRow: View {

    @EnvironmentObject private var dm: DownloadManager
    let song: NeteaseSong

    @State private var busy = false
    @State private var msg = ""
    @State private var quality = ""
    @State private var isFull = true

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(song.name)
                    .font(.subheadline)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if !song.artists.isEmpty {
                        Text(song.artists)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Text(song.durationText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(song.feeText)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(song.fee == 0
                                    ? Color.green.opacity(0.18)
                                    : Color.blue.opacity(0.16))
                        .cornerRadius(4)
                    if !quality.isEmpty {
                        Text(quality)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(isFull ? Color.green.opacity(0.18)
                                               : Color.orange.opacity(0.22))
                            .cornerRadius(4)
                    }
                }

                if !msg.isEmpty {
                    Text(msg)
                        .font(.caption2)
                        .foregroundColor(isFull ? .secondary : .orange)
                }
            }

            Spacer(minLength: 6)

            if busy {
                ProgressView()
            } else {
                Button("下载") { start() }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 3)
    }

    private func start() {
        busy = true
        msg = "取直链中…"
        quality = ""
        isFull = true

        NeteaseAPI.shared.fetchLink(for: song) { link in
            busy = false
            guard let l = link else {
                msg = "取直链失败，换一首试试"
                return
            }
            isFull = l.isFull
            quality = l.isFull ? l.qualityText : "试听30秒"

            let name = l.song.suggestedFileName

            if l.isFull {
                dm.start(urlString: l.url, threads: 8, preferredName: name)
                msg = l.swapped
                    ? "原版仅试听，已换成完整版：\(l.song.name)"
                    : "已开始下载（\(l.qualityText)）"
            } else {
                dm.start(urlString: l.url, threads: 4, preferredName: name)
                msg = "只有 30 秒试听，没找到完整版；填会员 Cookie 可解锁"
            }
        }
    }
}

// MARK: - 下钻页

struct ArtistSongsView: View {

    @EnvironmentObject private var dm: DownloadManager
    let artist: NeteaseArtist

    @State private var songs: [NeteaseSong] = []
    @State private var loading = true
    @State private var note = ""

    var body: some View {
        Group {
            if loading {
                ProgressView("加载热门歌曲…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if songs.isEmpty {
                Text(note.isEmpty ? "没拿到歌曲" : note)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(songs) { SongRow(song: $0) }
            }
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard songs.isEmpty else { return }
            NeteaseAPI.shared.artistSongs(artist.id) { r in
                loading = false
                songs = r
                note = r.isEmpty ? "没拿到歌曲" : "\(r.count) 首热门歌曲"
            }
        }
    }
}

struct PlaylistSongsView: View {

    @EnvironmentObject private var dm: DownloadManager
    let playlist: NeteasePlaylist

    @State private var songs: [NeteaseSong] = []
    @State private var loading = true
    @State private var note = ""

    var body: some View {
        Group {
            if loading {
                ProgressView("加载歌单…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if songs.isEmpty {
                Text(note.isEmpty ? "没拿到歌曲" : note)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(songs) { SongRow(song: $0) }
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard songs.isEmpty else { return }
            NeteaseAPI.shared.playlistSongs(playlist.id) { r in
                loading = false
                songs = r
                note = r.isEmpty ? "没拿到歌曲" : "\(r.count) 首"
            }
        }
    }
}
