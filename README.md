# 多线程下载器（iOS）

一个用 SwiftUI 写的 iPhone 多线程下载工具，支持 Range 分片并发、断点续传、实时速度。

## 功能

- 粘贴直链即可下载，自动探测文件大小
- 1–32 条线程可调，分片并发拉取
- 暂停 / 继续 / 取消，进度落盘，**关掉 App 再打开能续传**
- 实时显示已下载量、速度、百分比
- 自动识别链接里的 `filename=` 参数当文件名（123云盘这类直链尤其有用）
- 开启 `UIFileSharingEnabled`，下载的文件可以在「文件」App 里直接看到、导出

## 目录结构

```
MTDownloader/
├── project.yml                 # xcodegen 工程描述（CI 用它生成 .xcodeproj）
├── MTDownloader/
│   ├── MTDownloaderApp.swift   # App 入口
│   ├── ContentView.swift       # 主界面
│   ├── FilesView.swift         # 已下载文件列表
│   ├── DownloadManager.swift   # 下载引擎：探测、分片、续传、计时
│   └── ChunkDownloader.swift   # 单分片 Range 下载
└── .github/workflows/build.yml # GitHub Actions：macOS 环境编译打包 IPA
```

## CI 怎么跑的

GitHub Actions 用 `macos-15` 镜像（自带 Xcode）：

1. `brew install xcodegen` → `xcodegen generate` 生成 `MTDownloader.xcodeproj`
2. `xcodebuild -sdk iphoneos -configuration Release` 编译，**关闭代码签名**
3. 把 `.app` 塞进 `Payload/` 再 `zip` 成 `.ipa`
4. `actions/upload-artifact@v4` 上传产物 `MTDownloader-IPA`

> 仓库设为 **公开** 才能免费用 macOS runner（私有仓库的 macOS 时长按 10 倍计费）。

## ⚠️ 关于签名，必须知道

CI 产出的是**未签名 IPA**，iPhone 不能直接安装（会提示"无法安装"）。
要用起来，任选一条路：

1. **免费 Apple ID 自签**（最省事）
   用 [Sideloadly](https://sideloadly.io/) 或 [AltStore](https://altstore.io/)
   把这个 IPA 装到手机上，工具会用你的 Apple ID 现场签名。
   缺点：免费证书 7 天过期，到期要重装一次。

2. **付费开发者账号**（99 美元/年）
   把签名证书（.p12）+ 描述文件（.mobileprovision）作为 Secrets 传进仓库，
   改用带签名的 `xcodebuild -exportArchive` 流程，装一次管一年。

## 本地编译

```bash
brew install xcodegen
xcodegen generate
open MTDownloader.xcodeproj
```
最低系统要求 iOS 16.0。
