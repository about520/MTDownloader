import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var dm: DownloadManager
    @State private var urlText: String = ""
    @State private var threadCount: Double = 8
    @State private var showFiles = false

    var body: some View {
        NavigationStack {
            Form {
                Section("下载链接") {
                    TextField("粘贴直链（http/https）", text: $urlText)
                        .font(.system(.footnote, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                }

                Section("线程数：\(Int(threadCount)) 条") {
                    Slider(value: $threadCount, in: 1...32, step: 1)
                    Text("文件越大多开几条越快；小文件 4 条就够。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("进度") {
                    if dm.totalBytes > 0 {
                        ProgressView(value: Double(dm.doneBytes),
                                     total: Double(max(dm.totalBytes, 1)))
                        HStack {
                            Text(formatBytes(dm.doneBytes))
                            Spacer()
                            Text(formatBytes(dm.totalBytes))
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)

                        if !dm.fileName.isEmpty {
                            Text(dm.fileName)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    } else {
                        Text("还没有任务").foregroundColor(.secondary)
                    }

                    HStack {
                        Label(dm.status, systemImage: statusIcon)
                        Spacer()
                        Text(formatSpeed(dm.speedBps))
                    }
                    .font(.subheadline)
                }

                Section {
                    HStack(spacing: 12) {
                        Button("开始") { dm.start(urlString: urlText, threads: Int(threadCount)) }
                            .buttonStyle(.borderedProminent)
                        Button("暂停") { dm.pause() }
                            .buttonStyle(.bordered)
                        Button("继续") { dm.resume() }
                            .buttonStyle(.bordered)
                    }
                    Button("取消并删除文件", role: .destructive) {
                        dm.cancelAndDelete()
                    }
                }

                if !dm.errorText.isEmpty {
                    Section("错误") {
                        Text(dm.errorText)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }

                Section("当前设备") {
                    DeviceInfoCard()
                    Text("已按本机原生分辨率渲染，竖屏 / 横屏自动重排。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button("查看已下载的文件") { showFiles = true }
                }
            }
            .navigationTitle("多线程下载器")
            .navigationDestination(isPresented: $showFiles) {
                FilesView()
            }
        }
    }

    private var statusIcon: String {
        switch dm.status {
        case "下载中": return "arrow.down.circle.fill"
        case "已完成": return "checkmark.circle.fill"
        case "已暂停": return "pause.circle.fill"
        case "出错":   return "exclamationmark.triangle.fill"
        default:       return "circle"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DownloadManager())
}
