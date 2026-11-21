import SwiftUI
import PhotosUI
import Photos
import UIKit
import Vision
import CoreImage
import UserNotifications

// MARK: - 通知

enum 通知 {
    static func 申请() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 处理完成提醒（App 在前台也会弹，靠下面的 delegate）
    static func 完成(_ n: Int) {
        let 内 = UNMutableNotificationContent()
        内.title = "白底图处理完成"
        内.body = n > 0 ? "\(n) 张已生成，回来点「全部存进相册」" : "一张都没成功，打开看看"
        内.sound = .default
        let 请求 = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: 内, trigger: nil)
        try? UNUserNotificationCenter.current().add(请求)
    }
}

/// 让通知在 App 前台也显示
final class 通知代理: NSObject, UNUserNotificationCenterDelegate {
    static let 共享 = 通知代理()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent 通知: UNNotification,
                                withCompletionHandler 完成: @escaping (UNNotificationPresentationOptions) -> Void) {
        完成([.banner, .sound])
    }
}

@main
struct 白底方图App: App {
    init() {
        UNUserNotificationCenter.current().delegate = 通知代理.共享
        通知.申请()
    }
    var body: some Scene {
        WindowGroup { 根视图2() }
    }
}

// MARK: - 规格

/// 两种出图规格（用户 2026-11-11 要求）
///   白边：主体撑满 + 一圈白边，尺寸跟原图一样（抖店主图/详情）
///   白底：800×800、纯白背景（抖店「白底图」要求）
enum 规格: String, CaseIterable, Codable {
    case 白边 = "白边"
    case 白底 = "白底"

    var 边长: Int {
        switch self {
        case .白边: return 0        // 0 = 用原图边长
        case .白底: return 800      // 抖店要求 800×800
        }
    }

    var 边距: CGFloat {
        switch self {
        case .白边: return 0.06
        case .白底: return 0.04
        }
    }

    var 说明: String {
        switch self {
        case .白边: return "主体撑满 + 白边（尺寸同原图）"
        case .白底: return "800×800 纯白底（系统抠图，抖店白底图）"
        }
    }
}

// MARK: - 处理核心

enum 处理器 {

    /// 从图片里裁掉"接近白色"的边框，返回主体区域（原图坐标）
    static func 主体框(_ cg: CGImage, 阈值: UInt8 = 244) -> CGRect {
        let 小宽 = 256
        let 小高 = max(1, Int(Double(cg.height) / Double(cg.width) * Double(小宽)))
        var 缓冲 = [UInt8](repeating: 0, count: 小宽 * 小高 * 4)
        guard let 上下文 = CGContext(data: &缓冲, width: 小宽, height: 小高,
                                 bitsPerComponent: 8, bytesPerRow: 小宽 * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CGRect(x: 0, y: 0, width: cg.width, height: cg.height) }
        上下文.draw(cg, in: CGRect(x: 0, y: 0, width: 小宽, height: 小高))

        var 左 = 小宽, 右 = -1, 上 = 小高, 下 = -1
        let 阈 = Int(阈值)
        for y in 0..<小高 {
            for x in 0..<小宽 {
                let i = (y * 小宽 + x) * 4
                let r = Int(缓冲[i]), g = Int(缓冲[i + 1]), b = Int(缓冲[i + 2])
                if r < 阈 || g < 阈 || b < 阈 {
                    if x < 左 { 左 = x }
                    if x > 右 { 右 = x }
                    if y < 上 { 上 = y }
                    if y > 下 { 下 = y }
                }
            }
        }
        if 右 < 左 || 下 < 上 {
            return CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        }
        let 比 = CGFloat(cg.width) / CGFloat(小宽)
        let 余 = 2.0
        let x0 = max(0, (CGFloat(左) - 余) * 比)
        let y0 = max(0, (CGFloat(上) - 余) * 比)
        let x1 = min(CGFloat(cg.width), (CGFloat(右) + 余) * 比)
        let y1 = min(CGFloat(cg.height), (CGFloat(下) + 余) * 比)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 抠主体：用 iOS 自带的「主体提取」返回带透明度的图（失败 nil）
    /// 原理和拣货那边的 rembg 抠图一样，模型换成系统内置的
    static func 抠主体(_ cg: CGImage) -> CGImage? {
        if #available(iOS 17.0, *) {
            let 处 = VNImageRequestHandler(cgImage: cg, options: [:])
            let 请 = VNGenerateForegroundInstanceMaskRequest()
            do {
                try 处.perform([请])
            } catch {
                return nil
            }
            guard let 果 = 请.results?.first, !果.allInstances.isEmpty else { return nil }
            guard let 缓 = try? 果.generateMaskedImage(
                ofInstances: 果.allInstances, from: 处,
                croppedToInstancesExtent: true) else { return nil }
            let 图 = CIImage(cvPixelBuffer: 缓)
            let 上 = CIContext(options: [.useSoftwareRenderer: false])
            return 上.createCGImage(图, from: 图.extent)
        }
        return nil
    }

    /// 一张图（文件路径）→ 写出一张 JPEG（返回字节数，失败 nil）
    static func 处理文件(_ 入: URL, 出: URL, 规格: 规格 = .白边,
                    设置: 修图设置 = 修图设置(), 上限KB: Int = 7000,
                    边距比例: CGFloat = 0.06, 边长上限: Int = 0) -> Int? {
        guard let 源数据 = try? Data(contentsOf: 入),
              let 源 = UIImage(data: 源数据), let cg0 = 源.cgImage else { return nil }
        // 先修图（裁剪/擦除/增高/瘦腿/调色），再做白边或白底
        var 设置2 = 设置
        if 规格 == .白边 { 设置2.比例 = "原比例" }   // 白边不裁，比例只用来定画布
        let cg = 修图.走一遍(cg0, 设置: 设置2) ?? cg0
        var 主体: CGImage? = nil
        if 规格 == .白底 { 主体 = 抠主体(cg) }

        if 规格 == .白边 {
            // 醒图的做法：先定一块「画布」，再把图按原尺寸装进去，空白填白
            let w = Double(cg.width), h = Double(cg.height)
            let 边 = max(0.0, min(0.30, Double(边距比例)))

            // 画布比例（跟醒图一样：比例管画布，不管裁剪）
            var 布比: Double
            switch 设置.比例 {
            case "1:1": 布比 = 1
            case "3:4": 布比 = 3.0 / 4.0
            case "4:3": 布比 = 4.0 / 3.0
            case "9:16": 布比 = 9.0 / 16.0
            case "16:9": 布比 = 16.0 / 9.0
            default: 布比 = w / h          // 原比例：画布就是图的形状，不产生白边
            }

            // 能完整装下这张图的最小画布
            var 画宽 = w, 画高 = h
            if 画宽 / 画高 > 布比 { 画高 = 画宽 / 布比 } else { 画宽 = 画高 * 布比 }

            // 再按「白边宽度」整体留一圈
            画宽 *= (1 + 2 * 边)
            画高 *= (1 + 2 * 边)

            // 指定了输出边长就等比缩到那个长边
            if 边长上限 > 0 {
                let 长 = max(画宽, 画高)
                if 长 > Double(边长上限) {
                    let k = Double(边长上限) / 长
                    画宽 *= k
                    画高 *= k
                }
            }
            if 画宽 > 8192 { let k = 8192.0 / 画宽; 画宽 *= k; 画高 *= k }
            if 画高 > 8192 { let k = 8192.0 / 画高; 画宽 *= k; 画高 *= k }

            let 宽整 = max(1, Int(画宽.rounded()))
            let 高整 = max(1, Int(画高.rounded()))
            guard let 上0 = CGContext(data: nil, width: 宽整, height: 高整,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            上0.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            上0.fill(CGRect(x: 0, y: 0, width: 宽整, height: 高整))
            上0.interpolationQuality = .high

            // 图按画布缩放（只有加了白边/限了边长才会缩），居中放
            let 倍 = 画宽 / (w * (1 + 2 * 边))
            let 图宽 = w * 倍
            let 图高 = h * 倍
            上0.draw(cg, in: CGRect(x: (画宽 - 图宽) / 2, y: (画高 - 图高) / 2,
                                    width: 图宽, height: 图高))

            guard let 出图0 = 上0.makeImage() else { return nil }
            return 修图.存最好(出图0, 到: 出, 上限字节: 上限KB * 1024)
        }

        let 裁: CGImage
        let 裁边: Int
        if let 主 = 主体 {
            裁 = 主
            裁边 = max(主.width, 主.height)
        } else {
            // 白边模式（或抠图失败回退）：按去白边后的主体裁成正方形
            let 框 = 主体框(cg)
            guard let 裁0 = cg.cropping(to: 框) else { return nil }
            裁边 = min(裁0.width, 裁0.height)
            guard let 方 = 裁0.cropping(to: CGRect(
                x: (裁0.width - 裁边) / 2, y: (裁0.height - 裁边) / 2,
                width: 裁边, height: 裁边)) else { return nil }
            裁 = 方
        }

        // 画布边长：白边=原图边长；白底=800
        var 边长 = 规格.边长 > 0 ? 规格.边长 : Int(裁边)
        if 边长 > 6144 { 边长 = 6144 }   // 长边封顶（原图更小就保持原样）
        let 目标 = CGFloat(边长) * CGFloat(1 - 规格.边距 * 2)
        let 比 = min(目标 / CGFloat(裁.width), 目标 / CGFloat(裁.height))
        let 画宽 = max(1, Int(CGFloat(裁.width) * 比))
        let 画高 = max(1, Int(CGFloat(裁.height) * 比))
        let x = (边长 - 画宽) / 2
        let y = (边长 - 画高) / 2

        guard let 上 = CGContext(data: nil, width: 边长, height: 边长,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        上.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        上.fill(CGRect(x: 0, y: 0, width: 边长, height: 边长))
        上.interpolationQuality = .high
        上.draw(裁, in: CGRect(x: x, y: y, width: 画宽, height: 画高))
        guard let 出图 = 上.makeImage() else { return nil }

        return 修图.存最好(出图, 到: 出, 上限字节: 上限KB * 1024)
    }
}

// MARK: - 任务存储（断点续做）

struct 任务状态: Codable {
    var 输入们: [String]      // 原图在沙盒里的文件名
    var 已完成: [String: Int] // 文件名 → 字节数
    var 总数: Int
    var 规格名: String?       // "白边" / "白底"（老任务没有这个字段也能读）
    var 设置: 修图设置?       // 裁剪/调色/增高/瘦腿/擦除
}

enum 任务库 {
    static var 目录: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = u.appendingPathComponent("白底图任务", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var 输入目录: URL {
        let d = 目录.appendingPathComponent("输入", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var 输出目录: URL {
        let d = 目录.appendingPathComponent("输出", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var 状态文件: URL { 目录.appendingPathComponent("状态.json") }

    static func 读() -> 任务状态? {
        guard let d = try? Data(contentsOf: 状态文件) else { return nil }
        return try? JSONDecoder().decode(任务状态.self, from: d)
    }
    static func 写(_ s: 任务状态) {
        if let d = try? JSONEncoder().encode(s) {
            try? d.write(to: 状态文件, options: .atomic)
        }
    }
    static func 清() {
        try? FileManager.default.removeItem(at: 目录)
    }
}

// MARK: - 选图

struct 多选图: UIViewControllerRepresentable {
    var 完成: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var 配 = PHPickerConfiguration(photoLibrary: .shared())
        配.filter = .images
        配.selectionLimit = 0        // 不限张数
        配.selection = .ordered
        配.preferredAssetRepresentationMode = .current
        // 记忆点：上次选的那些，这次打开就是勾好的
        if let 上次 = UserDefaults.standard.stringArray(forKey: "图来上次选图"), !上次.isEmpty {
            配.preselectedAssetIdentifiers = 上次
        }
        let vc = PHPickerViewController(configuration: 配)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> 协调器 { 协调器(完成) }

    final class 协调器: NSObject, PHPickerViewControllerDelegate {
        let 完成: ([PHPickerResult]) -> Void
        init(_ 完成: @escaping ([PHPickerResult]) -> Void) { self.完成 = 完成 }
        func picker(_ picker: PHPickerViewController,
                    didFinishPicking 结果们: [PHPickerResult]) {
            let 记下 = 结果们.compactMap { $0.assetIdentifier }
            if !记下.isEmpty { UserDefaults.standard.set(记下, forKey: "图来上次选图") }
            picker.dismiss(animated: true)
            完成(结果们)
        }
    }
}

// MARK: - 主界面

@MainActor
final class 引擎: ObservableObject {
    @Published var 状态 = "选图 → 一键生成 2048×2048 白底图"
    @Published var 完成数 = 0
    @Published var 总数 = 0
    @Published var 成品们: [URL] = []
    @Published var 忙 = false
    @Published var 已存 = false
    @Published var 暂停了 = false
    @Published var 规格选: 规格 = .白边
    @Published var 修图选 = 修图设置()

    private var 后台标识: UIBackgroundTaskIdentifier = .invalid
    private var 要停 = false

    /// 选完图：先把原图落到沙盒（不占内存），再开始处理
    func 接收(_ 结果们: [PHPickerResult]) {
        清空任务()
        let 组 = DispatchGroup()
        var 序号 = 0
        var 名单: [String] = []
        let 锁 = NSLock()

        for r in 结果们 {
            guard r.itemProvider.hasItemConformingToTypeIdentifier("public.image") else { continue }
            组.enter()
            r.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.image") { url, _ in
                defer { 组.leave() }
                guard let url else { return }
                锁.lock(); 序号 += 1; let n = 序号; 锁.unlock()
                let 名 = String(format: "in_%03d.%@", n, url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
                let 去 = 任务库.输入目录.appendingPathComponent(名)
                try? FileManager.default.removeItem(at: 去)
                do {
                    try FileManager.default.copyItem(at: url, to: 去)
                    锁.lock(); 名单.append(名); 锁.unlock()
                } catch {}
            }
        }
        组.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let 排好 = 名单.sorted()
            guard !排好.isEmpty else {
                self.状态 = "没有取到图片"
                return
            }
            任务库.写(任务状态(输入们: 排好, 已完成: [:], 总数: 排好.count,
                               规格名: 规格选.rawValue, 设置: 修图选))
            self.总数 = 排好.count
            self.完成数 = 0
            self.成品们 = []
            self.已存 = false
            self.状态 = "已选 \(排好.count) 张，点「生成白底图」"
        }
    }

    func 清空任务() {
        要停 = true
        任务库.清()
        完成数 = 0
        总数 = 0
        成品们 = []
        已存 = false
        状态 = "选图 → 一键生成 2048×2048 白底图"
    }

    /// 开始／继续处理
    func 开始() {
        guard let 态 = 任务库.读(), !态.输入们.isEmpty else { return }
        忙 = true
        暂停了 = false
        要停 = false
        总数 = 态.总数
        完成数 = 态.已完成.count
        成品们 = 成品列表()
        状态 = "处理中 \(完成数)/\(总数)"

        // 申请一点后台时间（切出去能多撑一会儿；真被挂起会自动停、回来继续）
        let 态2规格 = 任务库.读()
        if var 记 = 态2规格, 记.规格名 == nil {
            记.规格名 = 规格选.rawValue
            任务库.写(记)
        }

        后台标识 = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in self?.结束后台() }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.跑批()
        }
    }

    private func 结束后台() {
        if 后台标识 != .invalid {
            UIApplication.shared.endBackgroundTask(后台标识)
            后台标识 = .invalid
        }
    }

    nonisolated private func 跑批() async {
        while true {
            let 停 = await MainActor.run { self.要停 }
            if 停 { break }
            guard var 态 = 任务库.读() else { break }
            let 待 = 态.输入们.filter { 态.已完成[$0] == nil }
            if 待.isEmpty { break }

            // 一次只取 3 张一起跑：内存稳、发热小
            let 批 = Array(待.prefix(3))
            var 结果: [(String, Int)] = []
            for 名 in 批 {
                let 停2 = await MainActor.run { self.要停 }
                if 停2 { break }
                let 入 = 任务库.输入目录.appendingPathComponent(名)
                let 出 = 任务库.输出目录.appendingPathComponent(名.replacingOccurrences(of: "in_", with: "out_") + ".jpg")
                let 规 = 规格(rawValue: 态.规格名 ?? "白边") ?? .白边
                let 字节 = await Task.detached(priority: .userInitiated) {
                    处理器.处理文件(入, 出: 出, 规格: 规,
                                设置: 态.设置 ?? 修图设置())
                }.value
                if let 字节 {
                    结果.append((名, 字节))
                } else {
                    结果.append((名, -1))   // -1 标记失败，避免死循环
                }
            }
            if 结果.isEmpty { break }

            guard var 态2 = 任务库.读() else { break }
            for (名, 字节) in 结果 {
                态2.已完成[名] = 字节
            }
            任务库.写(态2)

            await MainActor.run {
                self.完成数 = 态2.已完成.count
                self.成品们 = self.成品列表()
                self.状态 = "处理中 \(self.完成数)/\(self.总数)"
            }
        }

        let n = await MainActor.run { self.成品列表().count }
        await MainActor.run {
            self.忙 = false
            self.结束后台()
            self.状态 = n > 0 ? "完成 \(n)/\(self.总数) 张，点「全部存进相册」" : "一张都没成功"
        }
        通知.完成(n)        // 切出去玩也能收到"处理完了"
    }

    private func 成品列表() -> [URL] {
        guard let 态 = 任务库.读() else { return [] }
        var 出: [URL] = []
        for 名 in 态.输入们 {
            guard let 字节 = 态.已完成[名], 字节 > 0 else { continue }
            let p = 任务库.输出目录.appendingPathComponent(名.replacingOccurrences(of: "in_", with: "out_") + ".jpg")
            if FileManager.default.fileExists(atPath: p.path) { 出.append(p) }
        }
        return 出
    }

    /// 存相册：每 20 张一批，逐批提交
    func 存相册() async {
        let 们 = 成品列表()
        guard !们.isEmpty else { return }
        let 权 = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard 权 == .authorized || 权 == .limited else {
            状态 = "没拿到相册权限，去设置里打开"
            return
        }
        忙 = true
        var 成功 = 0
        var i = 0
        while i < 们.count {
            let 批 = Array(们[i..<min(i + 20, 们.count)])
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for p in 批 {
                        guard let d = try? Data(contentsOf: p) else { continue }
                        let 请求 = PHAssetCreationRequest.forAsset()
                        let 选项 = PHAssetResourceCreationOptions()
                        选项.uniformTypeIdentifier = "public.jpeg"
                        请求.addResource(with: .photo, data: d, options: 选项)
                    }
                }
                成功 += 批.count
            } catch {
                // 这一批失败不影响后面的
            }
            i += 20
            await MainActor.run {
                状态 = "存相册 \(成功)/\(们.count)"
            }
        }
        忙 = false
        已存 = true
        状态 = "已存入相册 \(成功)/\(们.count) 张"
        let 内 = UNMutableNotificationContent()
        内.title = "已存入相册"
        内.body = "\(成功) 张已保存到相册"
        内.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: 内, trigger: nil))
    }

    /// 换规格重做：图片不重新选，保持结果页不丢
    /// （用户 2026-11-11：想像醒图那样处理完还能原地换规格再来一遍）
    func 换规格重做(_ 新规格: 规格) {
        guard var 态 = 任务库.读(), !态.输入们.isEmpty else { return }
        态.已完成 = [:]
        态.规格名 = 新规格.rawValue
        任务库.写(态)
        规格选 = 新规格
        完成数 = 0
        成品们 = []
        已存 = false
        状态 = "换规格重做（\(新规格.rawValue)）…"
        开始()
    }

    func 继续未完成() {
        guard let 态 = 任务库.读() else { return }
        if 态.已完成.count < 态.总数 {
            总数 = 态.总数
            完成数 = 态.已完成.count
            成品们 = 成品列表()
            状态 = "上次没做完（\(完成数)/\(总数)），点「继续处理」"
        }
    }
}

struct ContentView: View {
    @StateObject private var 引 = 引擎()
    @State private var 显示选图 = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(引.状态)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if 引.总数 > 0 {
                    ProgressView(value: Double(引.完成数), total: Double(引.总数))
                        .padding(.horizontal)
                }

                if !引.成品们.isEmpty {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                                  spacing: 10) {
                            ForEach(引.成品们, id: \.self) { u in
                                if let ui = UIImage(contentsOfFile: u.path) {
                                    Image(uiImage: ui)
                                        .resizable()
                                        .aspectRatio(1, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                } else {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

                VStack(spacing: 10) {
                    // 规格切换：白边图 / 白底图 800
                    Picker("规格", selection: $引.规格选) {
                        ForEach(规格.allCases, id: \.self) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(引.规格选.说明)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button { 显示选图 = true } label: {
                        钮("选择图片", "photo.badge.plus", false)
                    }.disabled(引.忙)

                    Button {
                        if 引.成品们.isEmpty || 引.完成数 < 引.总数 {
                            引.开始()
                        } else {
                            引.存相册Task()
                        }
                    } label: {
                        钮(引.忙 ? "处理中…"
                            : (引.完成数 < 引.总数 ? "生成白底图 / 继续"
                               : "全部存进相册"),
                          "wand.and.stars", true)
                    }
                    .disabled(引.忙)

                    if 引.完成数 >= 引.总数 && 引.总数 > 0 && !引.成品们.isEmpty {
                        HStack(spacing: 8) {
                            Button {
                                引.换规格重做(.白边)
                            } label: {
                                钮("换白边重做", "arrow.clockwise", false)
                            }.disabled(引.忙)
                            Button {
                                引.换规格重做(.白底)
                            } label: {
                                钮("换白底重做", "arrow.clockwise", false)
                            }.disabled(引.忙)
                        }
                        Button { 引.存相册Task() } label: {
                            钮(引.已存 ? "已全部存入相册" : "全部存进相册",
                               "square.and.arrow.down", false)
                        }.disabled(引.忙 || 引.已存)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("白底方图")
            .sheet(isPresented: $显示选图) {
                多选图 { 结果们 in
                    引.接收(结果们)
                }
            }
            .task {
                引.继续未完成()
            }
        }
    }

    private func 钮(_ 标题: String, _ 图标: String, _ 主色: Bool) -> some View {
        HStack {
            Image(systemName: 图标)
            Text(标题).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(主色 ? Color.green : Color(.secondarySystemBackground))
        .foregroundStyle(主色 ? Color.black : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

extension 引擎 {
    /// 给 View 用的包装（异步转 Task）
    func 存相册Task() {
        Task { await 存相册() }
    }
}

#Preview {
    ContentView()
}
