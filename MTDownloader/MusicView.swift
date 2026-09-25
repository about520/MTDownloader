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
                let ok = r.filter { $0.canDownload }.count
                note = r.isEmpty ? "没搜到歌曲"
                     : "找到 \(r.count) 首，其中 \(ok) 首免费可下载"
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

// MARK: - 单曲行

struct SongRow: View {

    @EnvironmentObject private var dm: DownloadManager
    let song: NeteaseSong

    @State private var busy = false
    @State private var msg = ""

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
                        .background(song.canDownload
                                    ? Color.green.opacity(0.18)
                                    : Color.orange.opacity(0.20))
                        .cornerRadius(4)
                }

                if !msg.isEmpty {
                    Text(msg)
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
        guard song.canDownload else {
            msg = "这首是付费内容，服务端不下发直链"
            return
        }
        busy = true
        msg = ""

        NeteaseAPI.shared.songURL(song.id) { url in
            busy = false
            let name = song.suggestedFileName
            if let u = url {
                dm.start(urlString: u, threads: 8, preferredName: name)
                msg = "已开始下载"
            } else {
                // 兜底：走老的外链接口
                dm.start(urlString: NeteaseAPI.shared.outerURL(song.id),
                         threads: 8, preferredName: name)
                msg = "走备用链路下载"
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
                let ok = r.filter { $0.canDownload }.count
                note = r.isEmpty ? "没拿到歌曲"
                     : "\(r.count) 首，\(ok) 首可下载"
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
                let ok = r.filter { $0.canDownload }.count
                note = r.isEmpty ? "没拿到歌曲"
                     : "\(r.count) 首，\(ok) 首可下载"
            }
        }
    }
}
