import SwiftUI
import UIKit

/// 机型识别 + 屏幕分辨率信息
///
/// 用途：
/// 1) 通过 uname 拿到机型标识符（如 iPhone15,2），映射到「iPhone 14 Pro」这类俗称
/// 2) 读出当前屏幕的逻辑分辨率（pt）/ 物理分辨率（px）/ 缩放倍数
/// 3) 给 UI 提供判断依据，好在大屏、小屏、iPad 上分别排版
enum DeviceInfo {

    // MARK: - 机型标识符

    /// 形如 "iPhone15,2" / "iPad13,2" / "arm64"（模拟器）
    static var identifier: String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        var id = ""
        for child in mirror.children {
            if let v = child.value as? Int8, v != 0 {
                id.append(Character(UnicodeScalar(UInt8(v))))
            }
        }
        return id
    }

    /// 机型俗称。查不到就回退显示原始标识符，保证新机型不会显示成空白。
    static var modelName: String {
        let id = identifier
        if let n = nameMap[id] { return n }
        if id.hasPrefix("iPhone") { return "iPhone（" + id + "）" }
        if id.hasPrefix("iPad")   { return "iPad（" + id + "）" }
        if id.hasPrefix("iPod")   { return "iPod touch（" + id + "）" }
        if id == "arm64" || id == "x86_64" { return "iOS 模拟器（" + id + "）" }
        return id.isEmpty ? "未知设备" : id
    }

    // MARK: - 屏幕参数

    /// 逻辑分辨率，单位 pt（写代码布局用的就是这个）
    static var pointsSize: CGSize { UIScreen.main.bounds.size }

    /// 物理分辨率，单位 px（屏幕真实像素）
    static var pixelsSize: CGSize { UIScreen.main.nativeBounds.size }

    /// 缩放倍数，@2x / @3x
    static var scale: CGFloat { UIScreen.main.scale }

    static var pointsText: String {
        String(format: "%.0f × %.0f pt", pointsSize.width, pointsSize.height)
    }

    static var pixelsText: String {
        String(format: "%.0f × %.0f px", pixelsSize.width, pixelsSize.height)
    }

    static var scaleText: String {
        String(format: "@%.0fx", scale)
    }

    // MARK: - 设备类型

    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    static var idiomText: String {
        if isPad { return "iPad 平板" }
        if isPhone { return "iPhone 手机" }
        return "其他"
    }

    /// 大致判断是不是「小屏」，小屏下会把字号和间距收紧一点
    static var isCompactScreen: Bool {
        let w = min(pointsSize.width, pointsSize.height)
        let h = max(pointsSize.width, pointsSize.height)
        return w <= 320 || h <= 568
    }

    /// 系统版本
    static var systemVersion: String { UIDevice.current.systemVersion }
    static var systemName: String { UIDevice.current.systemName }

    static var systemText: String { systemName + " " + systemVersion }

    // MARK: - 机型对照表

    private static let nameMap: [String: String] = [
        // ---- iPhone ----
        "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE（第1代）",
        "iPhone9,1": "iPhone 7", "iPhone9,2": "iPhone 7 Plus",
        "iPhone9,3": "iPhone 7", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,2": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,4": "iPhone 8",
        "iPhone10,5": "iPhone 8 Plus", "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE（第2代）",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE（第3代）", "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone 17 Air",

        // ---- iPad ----
        "iPad7,5": "iPad（第6代）", "iPad7,6": "iPad（第6代）",
        "iPad7,11": "iPad（第7代）", "iPad7,12": "iPad（第7代）",
        "iPad11,6": "iPad（第8代）", "iPad11,7": "iPad（第8代）",
        "iPad12,1": "iPad（第9代）", "iPad12,2": "iPad（第9代）",
        "iPad13,18": "iPad（第10代）", "iPad13,19": "iPad（第10代）",
        "iPad14,10": "iPad（A16）", "iPad14,11": "iPad（A16）",
        "iPad5,3": "iPad Air 2", "iPad5,4": "iPad Air 2",
        "iPad11,3": "iPad Air（第3代）", "iPad11,4": "iPad Air（第3代）",
        "iPad13,1": "iPad Air（第4代）", "iPad13,2": "iPad Air（第4代）",
        "iPad13,16": "iPad Air（第5代）", "iPad13,17": "iPad Air（第5代）",
        "iPad14,8": "iPad Air（M2）", "iPad14,9": "iPad Air（M2）",
        "iPad5,1": "iPad mini 4", "iPad5,2": "iPad mini 4",
        "iPad11,1": "iPad mini（第5代）", "iPad11,2": "iPad mini（第5代）",
        "iPad14,1": "iPad mini（第6代）", "iPad14,2": "iPad mini（第6代）",
        "iPad16,1": "iPad mini（A17 Pro）", "iPad16,2": "iPad mini（A17 Pro）",
        "iPad8,1": "iPad Pro 11（第1代）", "iPad8,2": "iPad Pro 11（第1代）",
        "iPad8,3": "iPad Pro 11（第1代）", "iPad8,4": "iPad Pro 11（第1代）",
        "iPad8,9": "iPad Pro 11（第2代）", "iPad8,10": "iPad Pro 11（第2代）",
        "iPad13,4": "iPad Pro 11（第3代）", "iPad13,5": "iPad Pro 11（第3代）",
        "iPad14,3": "iPad Pro 11（第4代）", "iPad14,4": "iPad Pro 11（第4代）",
        "iPad16,3": "iPad Pro 11（M4）", "iPad16,4": "iPad Pro 11（M4）",
        "iPad8,5": "iPad Pro 12.9（第3代）", "iPad8,6": "iPad Pro 12.9（第3代）",
        "iPad8,11": "iPad Pro 12.9（第4代）", "iPad8,12": "iPad Pro 12.9（第4代）",
        "iPad13,8": "iPad Pro 12.9（第5代）", "iPad13,9": "iPad Pro 12.9（第5代）",
        "iPad14,5": "iPad Pro 12.9（第6代）", "iPad14,6": "iPad Pro 12.9（第6代）",
        "iPad16,5": "iPad Pro 13（M4）", "iPad16,6": "iPad Pro 13（M4）",

        // ---- iPod ----
        "iPod7,1": "iPod touch（第6代）", "iPod9,1": "iPod touch（第7代）",
    ]
}

// MARK: - 设备信息卡片

struct DeviceInfoCard: View {

    private var rows: [(String, String)] {
        [
            ("机型", DeviceInfo.modelName),
            ("设备类型", DeviceInfo.idiomText),
            ("系统", DeviceInfo.systemText),
            ("逻辑分辨率", DeviceInfo.pointsText),
            ("物理分辨率", DeviceInfo.pixelsText),
            ("渲染倍数", DeviceInfo.scaleText),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.0)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 8)
                    Text(row.1)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    Form { Section("设备") { DeviceInfoCard() } }
}
