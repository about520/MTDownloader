import SwiftUI

struct FileItem: Identifiable {
    let id = UUID()
    let name: String
    let size: Int64
}

struct FilesView: View {

    @State private var items: [FileItem] = []
    @State private var note: String = ""

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("还没有文件")
                        .foregroundColor(.secondary)
                    Text("下载好的文件会出现在这里")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { it in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(it.name)
                                .font(.footnote)
                                .lineLimit(2)
                            Text(formatBytes(it.size))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "doc.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("已下载")
        .onAppear(perform: load)
        .overlay(alignment: .bottom) {
            if !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }

    private func load() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let list = (try? FileManager.default.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []

        var out: [FileItem] = []
        for u in list {
            guard !u.lastPathComponent.hasSuffix(".mtprog") else { continue }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            out.append(FileItem(name: u.lastPathComponent, size: Int64(size)))
        }
        out.sort { $0.name < $1.name }
        items = out
        note = "这些文件也可以在「文件」App → 我的 iPhone → 多线程下载器 里看到"
    }
}
