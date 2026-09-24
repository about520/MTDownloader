import SwiftUI

@main
struct MTDownloaderApp: App {

    // 下载器提到 App 层，三个页面共用同一个实例，
    // 这样在浏览器里点「下载」切到下载页还能看到进度。
    @StateObject private var dm = DownloadManager()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem {
                        Label("下载", systemImage: "arrow.down.circle")
                    }

                BrowserView()
                    .tabItem {
                        Label("浏览器", systemImage: "globe")
                    }

                LANView()
                    .tabItem {
                        Label("传文件", systemImage: "wifi")
                    }

                NavigationStack {
                    FilesView()
                }
                .tabItem {
                    Label("文件", systemImage: "folder")
                }
            }
            .environmentObject(dm)
        }
    }
}
