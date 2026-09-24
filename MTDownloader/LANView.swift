import SwiftUI

/// 本机可发送的文件。用结构体而不是元组，因为 Swift 不支持对元组元素写 KeyPath。
struct LocalFileItem: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var size: Int64
}

struct LANView: View {

    @StateObject private var server = LANServer()
    @StateObject private var finder = LANFinder()
    @StateObject private var client = LANClient()
    @State private var selected: LANPeer?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { server.isRunning },
                        set: { on in on ? server.start() : server.stop() }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("允许局域网传输")
                            Text("开启后，同一 WiFi 下装了本 App 的设备就能发现你")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("本机名称")
                        Spacer()
                        Text(server.deviceName)
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                    }

                    HStack {
                        Text("状态")
                        Spacer()
                        Text(server.statusText)
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                } header: {
                    Text("本机")
                } footer: {
                    Text("双方都要开启才看得见对方。传文件走的是局域网，不耗流量。")
                }

                Section {
                    HStack {
                        Button {
                            finder.start()
                        } label: {
                            Label("扫描设备", systemImage: "arrow.clockwise")
                        }
                        Spacer()
                        Text(finder.statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if finder.peers.isEmpty {
                        Text("还没发现设备。确认对方也装了这个 App，\n并且在同一个 WiFi 下。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(finder.peers) { peer in
                            Button {
                                guard peer.isResolved else { return }
                                selected = peer
                            } label: {
                                HStack {
                                    Image(systemName: "iphone")
                                        .foregroundColor(.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peer.name)
                                            .foregroundColor(.primary)
                                            .font(.subheadline)
                                        Text(peer.addressText)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if peer.isResolved {
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("附近的设备")
                }

                if !server.lastEvent.isEmpty {
                    Section("最近动态") {
                        Text(server.lastEvent)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("局域网传输")
            .onAppear {
                if !server.isRunning { server.start() }
                finder.start()
            }
            .sheet(item: $selected) { peer in
                PeerDetailView(peer: peer, client: client)
            }
        }
    }
}

// MARK: - 单个设备的文件互传

struct PeerDetailView: View {

    let peer: LANPeer
    @ObservedObject var client: LANClient
    @EnvironmentObject var dm: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var myFiles: [LocalFileItem] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("地址")
                        Spacer()
                        Text(peer.addressText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if !client.message.isEmpty {
                        Text(client.message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text(peer.name)
                }

                Section("对方的文件") {
                    if client.remoteFiles.isEmpty {
                        Text("对方还没有文件")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(client.remoteFiles) { f in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(f.name)
                                        .font(.footnote)
                                        .lineLimit(2)
                                    Text(formatBytes(f.size))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("拉过来") {
                                    guard let ip = peer.ip, let p = peer.port,
                                          let u = client.fileURL(host: ip, port: p, name: f.name)
                                    else { return }
                                    dm.start(urlString: u.absoluteString, threads: 8)
                                    dismiss()
                                }
                                .font(.caption)
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }

                Section("把我的文件发过去") {
                    if myFiles.isEmpty {
                        Text("你还没有文件")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(myFiles) { f in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(f.name)
                                        .font(.footnote)
                                        .lineLimit(2)
                                    Text(formatBytes(f.size))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("发送") {
                                    guard let ip = peer.ip, let p = peer.port else { return }
                                    client.upload(localName: f.name, to: ip, port: p)
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .navigationTitle("传文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                myFiles = LANPaths.localFiles().map {
                    LocalFileItem(name: $0.name, size: $0.size)
                }
                if let ip = peer.ip, let p = peer.port {
                    client.fetchList(host: ip, port: p)
                }
            }
        }
    }
}
