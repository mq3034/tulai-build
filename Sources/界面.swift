import SwiftUI
import PhotosUI
import Photos
import UIKit

// MARK: - 配色（粉 / 蓝 / 白，和醒图区分开）

enum 色 {
    static let 粉 = Color(red: 0.96, green: 0.64, blue: 0.78)      // #F5A3C7
    static let 蓝 = Color(red: 0.62, green: 0.85, blue: 0.95)      // #9FD8F2
    static let 白 = Color.white
    static let 底 = Color(red: 0.99, green: 0.97, blue: 0.98)      // 近白
    static let 字 = Color(red: 0.20, green: 0.18, blue: 0.22)
    static let 浅字 = Color(red: 0.55, green: 0.52, blue: 0.58)
}

// MARK: - 主界面（照醒图排版：大按钮 + 功能格 + 底部标签）

struct 主界面: View {
    @StateObject private var 引 = 引擎()
    @State private var 显示选图 = false
    @State private var 页 = 0

    var body: some View {
        ZStack {
            色.底.ignoresSafeArea()
            VStack(spacing: 0) {
                if 页 == 0 { 首页 } else { 结果页 }

                底部标签
            }
        }
        .sheet(isPresented: $显示选图) {
            多选图 { 结果们 in
                引.接收(结果们)
                页 = 1
            }
        }
    }

    // ---------- 首页 ----------
    private var 首页: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 顶部问候
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("白底工坊").font(.title2).bold().foregroundStyle(色.字)
                        Text("选图 → 一键出图 → 存相册").font(.caption).foregroundStyle(色.浅字)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)

                // 两个大按钮（照醒图那个左右布局）
                HStack(spacing: 12) {
                    Button {
                        显示选图 = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 22, weight: .bold))
                            Text("导入照片").font(.headline).bold()
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                        .background(色.字).foregroundStyle(色.白)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                    }

                    Button {
                        显示选图 = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 22, weight: .bold))
                            Text("相机").font(.headline).bold()
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                        .background(色.蓝).foregroundStyle(色.字)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                    }
                }
                .padding(.horizontal, 16)

                // 规格选择
                VStack(alignment: .leading, spacing: 8) {
                    Text("出图规格").font(.subheadline).bold().foregroundStyle(色.浅字)
                    HStack(spacing: 10) {
                        ForEach(规格.allCases, id: \.self) { g in
                            规格卡(g, 选中: 引.规格选 == g) { 引.规格选 = g }
                        }
                    }
                }
                .padding(.horizontal, 16)

                // 修图参数
                VStack(alignment: .leading, spacing: 10) {
                    Text("修图").font(.subheadline).bold().foregroundStyle(色.浅字)

                    HStack(spacing: 8) {
                        段选(["原比例", "1:1", "3:4", "4:3"], 选: 引.修图选.比例) { 引.修图选.比例 = $0 }
                    }
                    HStack(spacing: 8) {
                        段选(["原色", "清爽", "暖调", "鲜明"], 选: 引.修图选.调色) { 引.修图选.调色 = $0 }
                    }
                    HStack(spacing: 8) {
                        段选(["不擦", "左上", "右上", "左下", "右下"], 选: 引.修图选.擦除角) { 引.修图选.擦除角 = $0 }
                    }

                    滑条("增高", 值: $引.修图选.增高, 上限: 0.25)
                    滑条("瘦腿", 值: $引.修图选.瘦腿, 上限: 0.6)
                }
                .padding(.horizontal, 16)

                // 功能格（照醒图那种 4 列图标）
                VStack(alignment: .leading, spacing: 10) {
                    Text("功能").font(.subheadline).bold().foregroundStyle(色.浅字)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                        功能格("批量出图", "square.stack.3d.up.fill", 色.粉) { 显示选图 = true }
                        一键增强格(底色: 色.蓝, 字色: 色.字)
                        推脸格(底色: 色.粉, 字色: 色.字)
                        功能格("白底 800", "rectangle.fill.on.rectangle.fill", 色.蓝) {
                            引.规格选 = .白底; 显示选图 = true
                        }
                        功能格("裁剪比例", "crop", 色.粉) { 显示选图 = true }
                        功能格("调色", "wand.and.stars", 色.蓝) { 显示选图 = true }
                        功能格("擦除", "eraser.fill", 色.粉) { 显示选图 = true }
                        功能格("增高瘦腿", "figure.walk", 色.蓝) { 显示选图 = true }
                        功能格("存相册", "square.and.arrow.down", 色.粉) { 引.存相册Task() }
                        功能格("换规格", "arrow.clockwise", 色.蓝) { 引.换规格重做(引.规格选 == .白边 ? .白底 : .白边) }
                    }
                }
                .padding(.horizontal, 16)

                Text("提示：先选规格，再导入照片，处理完点「全部存进相册」")
                    .font(.caption2).foregroundStyle(色.浅字)
                    .padding(.horizontal, 18)

                Spacer(minLength: 20)
            }
            .padding(.bottom, 24)
        }
    }

    private func 段选(_ 项们: [String], 选: String,
                     _ 点: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(项们, id: \.self) { x in
                Button { 点(x) } label: {
                    Text(x).font(.caption).bold()
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(选 == x ? 色.粉 : 色.白)
                        .foregroundStyle(色.字)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(色.蓝.opacity(0.4), lineWidth: 1))
                }
            }
        }
    }

    private func 滑条(_ 名: String, 值: Binding<Double>, 上限: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(名).font(.caption).foregroundStyle(色.字)
                Spacer()
                Text(String(format: "%.0f%%", 值.wrappedValue / 上限 * 100))
                    .font(.caption2).foregroundStyle(色.浅字)
            }
            Slider(value: 值, in: 0...上限).tint(色.粉)
        }
    }

    private func 规格卡(_ g: 规格, 选中: Bool, 点: @escaping () -> Void) -> some View {
        Button(action: 点) {
            VStack(spacing: 4) {
                Text(g.rawValue).font(.headline).bold()
                Text(g == .白边 ? "原图尺寸" : "800×800").font(.caption2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(选中 ? 色.粉 : 色.白)
            .foregroundStyle(色.字)
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(选中 ? 色.粉 : 色.蓝.opacity(0.5), lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func 功能格(_ 名: String, _ 图标: String, _ 底色: Color,
                     _ 点: @escaping () -> Void) -> some View {
        Button(action: 点) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(底色.opacity(0.25))
                    Image(systemName: 图标).font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(色.字)
                }
                .frame(height: 56)
                Text(名).font(.caption2).foregroundStyle(色.字)
            }
        }
    }

    // ---------- 结果页 ----------
    private var 结果页: some View {
        VStack(spacing: 10) {
            HStack {
                Button { 页 = 0 } label: {
                    Image(systemName: "chevron.left").font(.headline).foregroundStyle(色.字)
                }
                Spacer()
                Text(引.状态).font(.footnote).foregroundStyle(色.浅字).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8)

            if 引.总数 > 0 {
                ProgressView(value: Double(引.完成数), total: Double(引.总数))
                    .tint(色.粉).padding(.horizontal, 16)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(引.成品们, id: \.self) { u in
                        if let ui = UIImage(contentsOfFile: u.path) {
                            Image(uiImage: ui).resizable().aspectRatio(1, contentMode: .fit)
                                .background(色.白)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            VStack(spacing: 8) {
                Button { 引.存相册Task() } label: {
                    大按钮(引.已存 ? "已全部存入相册" : "全部存进相册", "square.and.arrow.down", 色.粉)
                }.disabled(引.忙 || 引.已存)

                HStack(spacing: 8) {
                    Button { 显示选图 = true } label: {
                        大按钮("再选一批", "plus", 色.蓝)
                    }
                    Button { 引.换规格重做(规格.白边) } label: {
                        大按钮("换白边", "arrow.clockwise", 色.蓝)
                    }
                    Button { 引.换规格重做(规格.白底) } label: {
                        大按钮("换白底", "arrow.clockwise", 色.蓝)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }

    private func 大按钮(_ 名: String, _ 图标: String, _ 底: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: 图标)
            Text(名).fontWeight(.bold)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 15)
        .background(底).foregroundStyle(色.字)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // ---------- 底部标签 ----------
    private var 底部标签: some View {
        HStack {
            标签("首页", "house.fill", 0)
            标签("出图", "wand.and.stars", 1)
        }
        .padding(.vertical, 8)
        .background(色.白)
        .overlay(Rectangle().fill(色.蓝.opacity(0.35)).frame(height: 1), alignment: .top)
    }

    private func 标签(_ 名: String, _ 图标: String, _ 号: Int) -> some View {
        Button { 页 = 号 } label: {
            VStack(spacing: 3) {
                Image(systemName: 图标).font(.system(size: 18))
                Text(名).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(页 == 号 ? 色.字 : 色.浅字)
        }
    }
}


// ===== 来自 主题.swift =====
/// 图来的配色（照手机实拍取色）
enum 图来色 {
    static let 绿 = Color(red: 188/255, green: 244/255, blue: 75/255)     // #bcf44b 相机钮
    static let 浅绿 = Color(red: 236/255, green: 250/255, blue: 215/255)  // #ecfad7 浅绿卡
    static let 字 = Color(red: 17/255, green: 17/255, blue: 17/255)
    static let 次字 = Color(red: 138/255, green: 138/255, blue: 138/255)
    static let 卡 = Color(red: 244/255, green: 244/255, blue: 244/255)
    static let 线 = Color(red: 238/255, green: 238/255, blue: 238/255)
    static let 编底 = Color(red: 12/255, green: 15/255, blue: 16/255)
    static let 编字 = Color.white
}

/// 浅色大按钮
struct 大按钮样式: ButtonStyle {
    var 底: Color = 图来色.字
    var 字色: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(字色)
            .frame(maxWidth: .infinity)
            .frame(height: 74)
            .background(底)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// 分节标题
struct 分节标题: View {
    let 字: String
    var 右: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(字).font(.system(size: 16, weight: .bold)).foregroundStyle(图来色.字)
            Spacer()
            if !右.isEmpty {
                Text(右).font(.system(size: 11)).foregroundStyle(图来色.次字)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

// ===== 来自 模型.swift =====
/// 一套出图参数：编辑页调好的，可以「用这套出全部」
struct 出图风格: Equatable, Codable {
    var 规格名: String = "白底"        // 白底 / 白边
    var 比例: String = "原比例"
    var 调色: String = "原色"
    var 增高: Double = 0
    var 瘦腿: Double = 0
    var 参 = 调节参数()      // 编辑页那 16 项，跟着一起带到批量
    var 边距: CGFloat = 0.04   // 白边宽度（占画布比例）
    var 边长: Int = 0          // 0 = 跟原图；>0 = 输出这个边长
    var 上限MB: Int = 7        // 每张最多多少 MB

    var 规格值: 规格 { 规格名 == "白底" ? .白底 : .白边 }

    var 修图: 修图设置 {
        var s = 修图设置()
        s.比例 = 比例
        s.调色 = 调色
        s.增高 = 增高
        s.瘦腿 = 瘦腿
        s.擦除角 = "不擦"
        return s
    }

    // MARK: 记住上次的设置（双备份 + 容错解码，升级 App 不会把习惯冲掉）
    static var 备份路径: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("图来出图设置.json")
    }

    static func 读() -> 出图风格 {
        if let d = UserDefaults.standard.data(forKey: "图来出图设置"),
           let v = try? JSONDecoder().decode(出图风格.self, from: d) { return v }
        if let d = try? Data(contentsOf: 备份路径),
           let v = try? JSONDecoder().decode(出图风格.self, from: d) { return v }
        return 出图风格()
    }

    func 存() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(d, forKey: "图来出图设置")
        try? d.write(to: 出图风格.备份路径, options: .atomic)
    }

    // 容错：以后加/删字段，老设置照样能读出来
    init() {}

    enum 键: String, CodingKey {
        case 规格名, 比例, 调色, 增高, 瘦腿, 参, 边距, 边长, 上限MB
    }

    init(from 解: Decoder) throws {
        let c = try 解.container(keyedBy: 键.self)
        规格名 = (try? c.decode(String.self, forKey: .规格名)) ?? 出图风格().规格名
        比例 = (try? c.decode(String.self, forKey: .比例)) ?? "原比例"
        调色 = (try? c.decode(String.self, forKey: .调色)) ?? "原色"
        增高 = (try? c.decode(Double.self, forKey: .增高)) ?? 0
        瘦腿 = (try? c.decode(Double.self, forKey: .瘦腿)) ?? 0
        参 = (try? c.decode(调节参数.self, forKey: .参)) ?? 调节参数()
        边距 = (try? c.decode(CGFloat.self, forKey: .边距)) ?? 0.04
        边长 = (try? c.decode(Int.self, forKey: .边长)) ?? 0
        上限MB = (try? c.decode(Int.self, forKey: .上限MB)) ?? 7
    }

    var 一句话: String {
        var 块 = [规格名]
        if 比例 != "原比例" { 块.append(比例) }
        if 调色 != "原色" { 块.append(调色) }
        if 增高 > 0.01 { 块.append("增高") }
        if 瘦腿 > 0.01 { 块.append("瘦腿") }
        if 参.有内容 { 块.append("精调") }
        return 块.joined(separator: " · ")
    }
}

/// 相册
enum 图库种类 {
    case 全部        // 最近项目
    case 收藏        // 个人收藏
    case 自拍        // 自拍
    case 实况        // 实况照片
}

@MainActor
final class 相册模型: ObservableObject {
    @Published var 图们: [PHAsset] = []
    @Published var 已授权 = false
    @Published var 读着 = false
    @Published var 被拒 = false

    func 开始() async {
        let 状态 = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if 状态 == .authorized || 状态 == .limited {
            已授权 = true
            await 读取(.全部)
        } else {
            被拒 = true
        }
    }

    func 读取(_ 种: 图库种类 = .全部) async {
        读着 = true
        defer { 读着 = false }

        let 选项 = PHFetchOptions()
        选项.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        switch 种 {
        case .全部:
            选项.fetchLimit = 800
            let 结果 = PHAsset.fetchAssets(with: .image, options: 选项)
            var 出: [PHAsset] = []
            结果.enumerateObjects { a, _, _ in 出.append(a) }
            图们 = 出

        case .实况:
            选项.fetchLimit = 3000
            let 结果 = PHAsset.fetchAssets(with: .image, options: 选项)
            var 出: [PHAsset] = []
            结果.enumerateObjects { a, _, _ in
                if a.mediaSubtypes.contains(.photoLive) { 出.append(a) }
            }
            图们 = Array(出.prefix(800))

        case .收藏, .自拍:
            let 子类: PHAssetCollectionSubtype = (种 == .收藏) ? .smartAlbumFavorites : .smartAlbumSelfPortraits
            let 相册们 = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: 子类, options: nil)
            guard let 册 = 相册们.firstObject else {
                图们 = []
                return
            }
            let 结果 = PHAsset.fetchAssets(in: 册, options: 选项)
            var 出: [PHAsset] = []
            结果.enumerateObjects { a, _, _ in 出.append(a) }
            图们 = 出
        }
    }
}

extension PHAsset {
    /// 取原图数据（会自己下载 iCloud 图）
    func 取数据() async -> Data? {
        await withCheckedContinuation { (续: CheckedContinuation<Data?, Never>) in
            var 已回 = false
            let 选 = PHImageRequestOptions()
            选.isNetworkAccessAllowed = true
            选.deliveryMode = .highQualityFormat
            选.resizeMode = .none
            选.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: self, options: 选) { 数据, _, _, _ in
                if 已回 { return }
                已回 = true
                续.resume(returning: 数据)
            }
        }
    }

    func 取图(边长: CGFloat) async -> UIImage? {
        await withCheckedContinuation { (续: CheckedContinuation<UIImage?, Never>) in
            var 已回 = false
            let 选 = PHImageRequestOptions()
            选.isNetworkAccessAllowed = true
            选.deliveryMode = .highQualityFormat
            选.resizeMode = .exact
            PHImageManager.default().requestImage(for: self,
                                              targetSize: CGSize(width: 边长, height: 边长),
                                              contentMode: .aspectFill,
                                              options: 选) { 图, _ in
                if 已回 { return }
                已回 = true
                续.resume(returning: 图)
            }
        }
    }
}

/// 相册里的一格
struct 相册格: View {
    let 资产: PHAsset
    @State private var 缩略: UIImage?

    var body: some View {
        ZStack {
            Color(white: 0.95)
            if let 缩略 {
                Image(uiImage: 缩略).resizable().scaledToFill()
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onAppear {
            guard 缩略 == nil else { return }
            Task {
                if let 图 = await 资产.取图(边长: 320) { 缩略 = 图; return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                if let 图 = await 资产.取图(边长: 240) { 缩略 = 图 }
            }
        }
    }
}

// ===== 来自 批量引擎.swift =====
/// 批量出图 + 存相册（App 里才能真的批量存）
@MainActor
final class 批量引擎: ObservableObject {
    @Published var 总数 = 0
    @Published var 完成 = 0
    @Published var 状态 = "选好照片后点「开始生成」"
    @Published var 产物: [URL] = []
    @Published var 跑着 = false
    @Published var 存着 = false
    @Published var 已存 = false
    @Published var 项们: [来源] = []     // 本次要出的图（页面实时读，避免出现 0 张）

    private var 要停 = false

    var 进度: Double { 总数 > 0 ? Double(完成) / Double(总数) : 0 }

    func 停() { 要停 = true }

    func 清空() {
        产物 = []
        完成 = 0
        总数 = 0
        已存 = false
        状态 = "选好照片后点「开始生成」"
    }

    // MARK: 出图

    func 跑(_ 项们: [来源], 风格 s: 出图风格) async {
        guard !跑着, !项们.isEmpty else { return }
        跑着 = true
        要停 = false
        已存 = false
        总数 = 项们.count
        完成 = 0
        产物 = []
        // 切出去也让它多跑一会儿
        let 后台 = UIApplication.shared.beginBackgroundTask(withName: "图来批量") {}

        let 根 = FileManager.default.temporaryDirectory
            .appendingPathComponent("图来批量", isDirectory: true)
            .appendingPathComponent(String(Int(Date().timeIntervalSince1970)), isDirectory: true)
        try? FileManager.default.createDirectory(at: 根, withIntermediateDirectories: true)

        // 3 张一组并发跑，比一张一张快一倍多
        var 起 = 0
        while 起 < 项们.count {
            if 要停 { break }
            let 止 = min(起 + 3, 项们.count)
            let 批 = Array(起..<止)
            状态 = "处理中 \(止)/\(总数)"
            let 结果 = await 跑一批(批, 项们: 项们, 根: 根, s: s)
            for (i, u) in 结果 {
                if let u { 产物.append(u) } else { _ = i }
            }
            完成 = 止
            起 = 止
        }

        跑着 = false
        if 后台 != .invalid { UIApplication.shared.endBackgroundTask(后台) }
        状态 = 要停 ? "已停下 \(产物.count)/\(总数) 张" : "完成 \(产物.count)/\(总数) 张"
        if !要停, 产物.count > 0 { 通知.完成(产物.count) }
    }

    private func 跑一批(_ 批: [Int], 项们: [来源], 根: URL, s: 出图风格) async -> [(Int, URL?)] {
        await withTaskGroup(of: (Int, URL?).self) { 组 in
            for i in 批 {
                let 项 = 项们[i]
                let 入 = 根.appendingPathComponent(String(format: "in_%03d.jpg", i))
                let 出 = 根.appendingPathComponent(String(format: "out_%03d.jpg", i))
                let 规 = s.规格值
                let 设 = s.修图
                let 参 = s.参
                let 边距 = s.边距
                let 边长 = s.边长
                let 上限 = s.上限MB * 1024
                组.addTask {
                    guard let 数据 = await 项.取数据() else { return (i, nil) }
                    try? 数据.write(to: 入)
                    if 参.有内容, let 源 = UIImage(contentsOfFile: 入.path)?.cgImage,
                       let 调过 = 修图.精调(源, 参),
                       let jpg = UIImage(cgImage: 调过).jpegData(compressionQuality: 0.95) {
                        try? jpg.write(to: 入)
                    }
                    let 字节 = await Task.detached(priority: .userInitiated) { () -> Int? in
                        处理器.处理文件(入, 出: 出, 规格: 规, 设置: 设,
                                     上限KB: 上限, 边距比例: 边距, 边长上限: 边长)
                    }.value
                    return (i, (字节 ?? 0) > 0 ? 出 : nil)
                }
            }
            var 出: [(Int, URL?)] = []
            for await r in 组 { 出.append(r) }
            return 出
        }
    }

    // MARK: 存相册

    func 存相册() async -> Int {
        guard !产物.isEmpty else { return 0 }
        let 权 = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard 权 == .authorized || 权 == .limited else {
            状态 = "没拿到相册权限，去设置里打开"
            return 0
        }
        存着 = true
        var 成功 = 0
        var i = 0
        while i < 产物.count {
            let 批 = Array(产物[i..<min(i + 20, 产物.count)])
            let 数 = 批.count
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
                成功 += 数
            } catch {
                // 这一批失败不影响后面的
            }
            i += 20
            状态 = "存相册 \(成功)/\(产物.count)"
        }
        存着 = false
        已存 = 成功 > 0
        状态 = "已存入相册 \(成功)/\(产物.count) 张"
        return 成功
    }
}

// ===== 来自 相册视图.swift =====
/// 本地相册（照醒图：页签 + 筹码 + 网格）
struct 相册视图: View {
    @ObservedObject var 相: 相册模型
    var 多选: Bool
    var 完成: ([PHAsset]) -> Void
    var 取消: () -> Void

    @State private var 页签 = "图片"
    @State private var 筹码 = "最近项目"
    @State private var 选中: [String] = []
    @State private var 选择模式 = false
    @State private var 起格: Int?
    @State private var 基准: [String] = []
    @State private var 代理: ScrollViewProxy?
    @State private var 滚钟: Timer?
    @State private var 滚锚 = 0
    @State private var 区高: CGFloat = 600
    @State private var 行选 = false
    @State private var 划着 = false
    @State private var 说明 = ""

    private let 页签们 = ["图片", "实况", "拼图", "批量修图"]
    private let 筹码们 = ["添加画布", "最近项目", "个人收藏", "自拍", "实况照片"]

    var body: some View {
        VStack(spacing: 0) {
            顶栏
            页签行
            筹码行
            Divider().overlay(图来色.线)
            内容
            底栏
        }
        .background(Color.white)
        .task {
            if !相.已授权 && !相.被拒 { await 相.开始() }
            if 多选 { 选择模式 = true }
        }
    }

    // MARK: 顶栏
    private var 顶栏: some View {
        HStack {
            Button { 取消() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(图来色.字)
            }
            Spacer()
            Text("本地相册").font(.system(size: 16, weight: .semibold)).foregroundStyle(图来色.字)
            Spacer()
            Text("\(相.图们.count) 张").font(.system(size: 11)).foregroundStyle(图来色.次字)
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
    }

    // MARK: 页签
    private var 页签行: some View {
        HStack(spacing: 22) {
            ForEach(页签们, id: \.self) { t in
                Button { 点页签(t) } label: {
                    VStack(spacing: 6) {
                        Text(t)
                            .font(.system(size: 14.5, weight: 页签 == t ? .bold : .regular))
                            .foregroundStyle(页签 == t ? 图来色.字 : 图来色.次字)
                        Rectangle()
                            .fill(页签 == t ? 图来色.字 : Color.clear)
                            .frame(height: 2.5)
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: 筹码
    private var 筹码行: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(筹码们, id: \.self) { t in
                    Button { 点筹码(t) } label: {
                        Text(t)
                            .font(.system(size: 12.5, weight: 筹码 == t ? .bold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(筹码 == t ? 图来色.字 : Color(white: 0.96))
                            .foregroundStyle(筹码 == t ? Color.white : 图来色.字)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    // MARK: 内容
    @ViewBuilder private var 内容: some View {
        if 相.被拒 {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44)).foregroundStyle(图来色.次字)
                Text("没给相册权限").font(.system(size: 15, weight: .semibold))
                Text("去「设置 → 图来 → 照片」打开").font(.system(size: 12)).foregroundStyle(图来色.次字)
                Spacer()
            }
        } else if 页签 == "拼图" {
            空态("拼图还没做", "先用水印/白底那套吧")
        } else if 相.图们.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                if 相.读着 { ProgressView() }
                Text(相.读着 ? "正在读相册…" : (说明.isEmpty ? "这里没有照片" : 说明))
                    .font(.system(size: 13)).foregroundStyle(图来色.次字)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(Array(相.图们.enumerated()), id: \.element.localIdentifier) { 序, 资产 in
                        ZStack(alignment: .topTrailing) {
                            相册格(资产: 资产).frame(height: 126)
                            if 选中.contains(资产.localIdentifier) {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(图来色.绿, lineWidth: 3)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(图来色.绿, .white)
                                    .padding(5)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { 点(资产) }
                    }
                }
                .padding(3)
                .coordinateSpace(name: "格")
                .gesture(划选)
            }
            .scrollDisabled(选择模式 && 划着)
        }
    }

    private func 空态(_ 大: String, _ 小: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(大).font(.system(size: 15, weight: .semibold)).foregroundStyle(图来色.字)
            Text(小).font(.system(size: 12)).foregroundStyle(图来色.次字)
            Spacer()
        }
    }

    // MARK: 底栏
    private var 底栏: some View {
        HStack(spacing: 12) {
            if 选择模式 && 多选 {
                Button {
                    选中 = 相.图们.prefix(200).map { $0.localIdentifier }
                } label: {
                    Text("全选").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(图来色.字)
                        .frame(width: 64, height: 48)
                        .background(图来色.卡)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            Button { 取消() } label: {
                Text("取消").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(图来色.字)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(图来色.卡)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Button {
                if 选中.isEmpty { 说明 = "先点一张" ; return }
                完成(相.图们.filter { 选中.contains($0.localIdentifier) })
            } label: {
                Text(选中.isEmpty ? (选择模式 ? "选照片" : "选一张") : "用这 \(选中.count) 张")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(图来色.字)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(选中.isEmpty ? 图来色.卡 : 图来色.绿)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
    }

    // MARK: 手势
    private var 划选: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("格"))
            .onChanged { v in
                guard 选择模式 else { return }
                if 起格 == nil {
                    起格 = 格号(v.startLocation)
                    基准 = 选中
                    划着 = true
                }
                guard let s0 = 起格 else { return }
                选中 = 区间(s0, 格号(v.location))
            }
            .onEnded { _ in
                起格 = nil
                划着 = false
            }
    }

    private func 格号(_ p: CGPoint) -> Int {
        let 屏宽 = UIScreen.main.bounds.width
        let 格宽 = max(1, (屏宽 - 6 - 6) / 3)
        let 格高: CGFloat = 126
        let 列 = max(0, min(2, Int((p.x - 3) / (格宽 + 3))))
        let 行 = max(0, Int((p.y - 3) / (格高 + 3)))
        return 行 * 3 + 列
    }

    private func 区间(_ a: Int, _ b: Int) -> [String] {
        let 低 = min(a, b), 高 = max(a, b)
        var 出 = 基准
        for i in 低...高 where i < 相.图们.count {
            let id = 相.图们[i].localIdentifier
            if !出.contains(id) { 出.append(id) }
        }
        return 出
    }

    // MARK: 交互
    private func 点页签(_ t: String) {
        页签 = t
        switch t {
        case "批量修图":
            选择模式 = true
        case "实况":
            选择模式 = false
            筹码 = "实况照片"
            Task { await 相.读取(.实况) }
        case "拼图":
            选择模式 = false
        default:
            选择模式 = false
            筹码 = "最近项目"
            Task { await 相.读取(.全部) }
        }
    }

    private func 点筹码(_ t: String) {
        筹码 = t
        选择模式 = (页签 == "批量修图")
        switch t {
        case "最近项目":
            说明 = ""
            Task { await 相.读取(.全部) }
        case "个人收藏":
            说明 = "收藏夹里没有照片"
            Task { await 相.读取(.收藏) }
        case "自拍":
            说明 = "没有自拍"
            Task { await 相.读取(.自拍) }
        case "实况照片":
            说明 = "没有实况照片"
            Task { await 相.读取(.实况) }
        default:
            说明 = "「添加画布」还没做"
            相.图们 = []
        }
    }

    private var 划选2: some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("格2")))
            .onChanged { v in
                guard 多选 else { return }
                if case .second(true, let d) = v, let d = d {
                    if 起格 == nil {
                        起格 = 格号2(d.startLocation)
                        基准 = 选中
                    }
                    guard let s0 = 起格 else { return }
                    let a = min(s0, 格号2(d.location))
                    let b = max(s0, 格号2(d.location))
                    var 出 = 基准
                    for i in a...b where i < 相.图们.count {
                        let id = 相.图们[i].localIdentifier
                        if !出.contains(id) { 出.append(id) }
                    }
                    选中 = 出
                }
            }
            .onEnded { _ in 起格 = nil }
    }

    private func 格号2(_ p: CGPoint) -> Int {
        let 屏宽 = UIScreen.main.bounds.width
        let 格宽 = max(1, (屏宽 - 6 - 6) / 3)
        let 列 = max(0, min(2, Int((p.x - 3) / (格宽 + 3))))
        let 行 = max(0, Int((p.y - 3) / (129)))
        return 行 * 3 + 列
    }

    private func 点(_ 资产: PHAsset) {
        let id = 资产.localIdentifier
        if 多选 || 选择模式 {
            if 选中.contains(id) { 选中.removeAll { $0 == id } } else { 选中.append(id) }
        } else {
            选中 = [id]
        }
    }
}

/// 结果缩略图（按路径懒加载，100 张也不炸）
struct 结果格: View {
    let 路径: URL
    @State private var 图: UIImage?
    var body: some View {
        ZStack {
            Color.white
            if let 图 {
                Image(uiImage: 图).resizable().scaledToFit()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            guard 图 == nil else { return }
            图 = UIImage(contentsOfFile: 路径.path)
        }
    }
}

/// 批量页
struct 批量视图: View {
    @ObservedObject var 批: 批量引擎
    @Binding var 风格: 出图风格
    var 项们: [来源]
    var 关闭: () -> Void

    private var 用项: [来源] { 批.项们.isEmpty ? 项们 : 批.项们 }

    private let 调色们 = ["原色", "清爽", "鲜明", "暖调", "冷调", "黑白"]
    private let 比例们 = ["原比例", "1:1", "3:4", "4:3"]

    var body: some View {
        VStack(spacing: 0) {
            顶栏
            ScrollView {
                VStack(spacing: 0) {
                    规格区
                    分节标题(字: "调色")
                    chips(调色们, 选: 风格.调色) { 风格.调色 = $0 }
                    分节标题(字: "裁剪")
                    chips(比例们, 选: 风格.比例) { 风格.比例 = $0 }
                    分节标题(字: "白边宽度")
                    HStack {
                        Slider(value: Binding(
                            get: { 风格.边距 * 100 },
                            set: { 风格.边距 = $0 / 100 }), in: 1...15)
                            .tint(图来色.绿)
                        Text(String(format: "%.0f%%", 风格.边距 * 100))
                            .font(.system(size: 11)).foregroundStyle(图来色.次字).frame(width: 34)
                    }
                    .padding(.horizontal, 16)

                    分节标题(字: "输出边长")
                    chips(["原图", "2000", "1500", "1200"],
                          选: 风格.边长 == 0 ? "原图" : "\(风格.边长)") { t in
                        风格.边长 = (t == "原图") ? 0 : (Int(t) ?? 0)
                    }

                    分节标题(字: "文件上限")
                    chips(["7M", "10M", "20M", "30M"], 选: "\(风格.上限MB)M") { t in
                        风格.上限MB = Int(t.replacingOccurrences(of: "M", with: "")) ?? 7
                    }

                    分节标题(字: "精调")
                    滑条("增高", 值: $风格.增高, 上限: 0.25)
                    滑条("瘦腿", 值: $风格.瘦腿, 上限: 0.6)
                    操作区
                    结果区
                }
            }
        }
        .background(Color.white)
    }

    private var 顶栏: some View {
        HStack {
            Button { 关闭() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(图来色.字)
            }
            Text("批量出图").font(.system(size: 16, weight: .semibold)).foregroundStyle(图来色.字)
            Spacer()
            Text(批.状态).font(.system(size: 11)).foregroundStyle(图来色.次字).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
    }

    private var 规格区: some View {
        HStack(spacing: 10) {
            规格卡("白边图", "同原尺寸 + 白边", 选: 风格.规格名 == "白边") { 风格.规格名 = "白边" }
            规格卡("白底 800", "800×800 纯白底", 选: 风格.规格名 == "白底") { 风格.规格名 = "白底" }
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private func 规格卡(_ 名: String, _ 说明: String, 选: Bool, 点: @escaping () -> Void) -> some View {
        Button(action: 点) {
            VStack(spacing: 3) {
                Text(名).font(.system(size: 15, weight: .bold))
                Text(说明).font(.system(size: 10.5)).foregroundStyle(图来色.次字)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(选 ? 图来色.浅绿 : Color.white)
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(选 ? 图来色.绿 : 图来色.线, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .foregroundStyle(图来色.字)
    }

    private func chips(_ 项们: [String], 选: String, 点: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(项们, id: \.self) { s in
                    Button { 点(s) } label: {
                        Text(s).font(.system(size: 12.5, weight: s == 选 ? .bold : .medium))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(s == 选 ? 图来色.字 : 图来色.卡)
                            .foregroundStyle(s == 选 ? Color.white : 图来色.字)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func 滑条(_ 名: String, 值: Binding<Double>, 上限: Double) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(名).font(.system(size: 12)).foregroundStyle(图来色.字)
                Spacer()
                Text(String(format: "%.0f%%", 值.wrappedValue / 上限 * 100))
                    .font(.system(size: 11)).foregroundStyle(图来色.次字)
            }
            Slider(value: 值, in: 0...上限).tint(图来色.绿)
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
    }

    private var 操作区: some View {
        VStack(spacing: 8) {
            if 批.总数 > 0 {
                ProgressView(value: 批.进度).tint(图来色.绿).padding(.horizontal, 16)
            }
            HStack(spacing: 10) {
                if 批.跑着 {
                    Button {
                        批.停()
                    } label: {
                        Text("停下").font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(图来色.卡).foregroundStyle(图来色.字)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    Button {
                        Task { await 批.跑(用项, 风格: 风格) }
                    } label: {
                        Text("开始生成 \(用项.count) 张").font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(图来色.绿).foregroundStyle(图来色.字)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Button {
                    Task { _ = await 批.存相册() }
                } label: {
                    Text(批.已存 ? "已存" : "全部存相册").font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(批.产物.isEmpty ? 图来色.卡 : 图来色.字)
                        .foregroundStyle(批.产物.isEmpty ? 图来色.次字 : Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(批.产物.isEmpty || 批.存着)
            }
            .padding(.horizontal, 16)
            Text(风格.一句话 + " · 最多 \(风格.上限MB)MB/张")
                .font(.system(size: 10.5)).foregroundStyle(图来色.次字)
        }
        .padding(.top, 10)
    }

    private var 结果区: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(批.产物, id: \.self) { u in
                VStack(spacing: 3) {
                    结果格(路径: u)
                    if let 图 = UIImage(contentsOfFile: u.path) {
                        Text("\(Int(图.size.width))×\(Int(图.size.height)) · \(String(format: "%.1f", Double((try? Data(contentsOf: u))?.count ?? 0) / 1048576))MB")
                            .font(.system(size: 8.5))
                            .foregroundStyle(图来色.次字)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 30)
    }
}

// ===== 来自 编辑视图.swift =====
/// 单张编辑：出白底/白边，然后「用这套出全部」
struct 编辑视图: View {
    let 资产: PHAsset
    @Binding var 风格: 出图风格
    var 用这套出全部: () -> Void
    var 关闭: () -> Void

    @State private var 原图: UIImage?
    @State private var 成品: UIImage?
    @State private var 成品路径: URL?
    @State private var 跑着 = false
    @State private var 提示 = ""

    private let 调色们 = ["原色", "清爽", "鲜明", "暖调", "冷调", "黑白"]
    private let 比例们 = ["原比例", "1:1", "3:4", "4:3"]

    var body: some View {
        ZStack {
            图来色.编底.ignoresSafeArea()
            VStack(spacing: 0) {
                顶栏
                预览
                面板
            }
        }
        .task {
            if 原图 == nil {
                原图 = await 资产.取图(边长: 1200)
            }
        }
    }

    private var 顶栏: some View {
        HStack {
            Button { 关闭() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Text(提示.isEmpty ? 风格.一句话 : 提示)
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            Spacer()
            Button {
                Task { await 存一张() }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(图来色.编底)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(图来色.绿))
            }
            .disabled(成品 == nil)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
    }

    private var 预览: some View {
        ZStack {
            Color.black
            if let 图 = 成品 ?? 原图 {
                Image(uiImage: 图).resizable().scaledToFit().padding(8)
            } else {
                ProgressView().tint(.white)
            }
            if 跑着 {
                ProgressView().tint(图来色.绿)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var 面板: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(["白边", "白底"], id: \.self) { s in
                    Button {
                        风格.规格名 = s
                        Task { await 出图() }
                    } label: {
                        Text(s).font(.system(size: 14, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(风格.规格名 == s ? 图来色.绿 : Color.white.opacity(0.12))
                            .foregroundStyle(风格.规格名 == s ? 图来色.编底 : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                    }
                }
                Button {
                    用这套出全部()
                } label: {
                    Text("用这套出全部").font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Color.white).foregroundStyle(图来色.编底)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                }
            }
            row(调色们, 选: 风格.调色) { 风格.调色 = $0 }
            row(比例们, 选: 风格.比例) { 风格.比例 = $0 }
            HStack(spacing: 12) {
                slider("增高", 值: $风格.增高, 上限: 0.25)
                slider("瘦腿", 值: $风格.瘦腿, 上限: 0.6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(图来色.编底)
    }

    private func row(_ 项们: [String], 选: String, 点: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(项们, id: \.self) { s in
                    Button { 点(s) } label: {
                        Text(s).font(.system(size: 12.5, weight: s == 选 ? .bold : .medium))
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(s == 选 ? 图来色.绿 : Color.white.opacity(0.12))
                            .foregroundStyle(s == 选 ? 图来色.编底 : .white)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private func slider(_ 名: String, 值: Binding<Double>, 上限: Double) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(名).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.0f%%", 值.wrappedValue / 上限 * 100))
                    .font(.system(size: 10)).foregroundStyle(图来色.绿)
            }
            Slider(value: 值, in: 0...上限).tint(图来色.绿)
        }
    }

    // MARK: 出图

    private func 出图() async {
        guard !跑着 else { return }
        跑着 = true
        提示 = "正在出图…"
        guard let 数据 = await 资产.取数据() else {
            提示 = "这张读不出来"
            跑着 = false
            return
        }
        let 目录 = FileManager.default.temporaryDirectory
        let 入 = 目录.appendingPathComponent("单张_in.jpg")
        let 出 = 目录.appendingPathComponent("单张_out.jpg")
        try? 数据.write(to: 入)

        let 规 = 风格.规格值
        let 设 = 风格.修图
        let 字节 = await Task.detached(priority: .userInitiated) { () -> Int? in
            处理器.处理文件(入, 出: 出, 规格: 规, 设置: 设)
        }.value

        if let 字节, 字节 > 0, let 图 = UIImage(contentsOfFile: 出.path) {
            成品 = 图
            成品路径 = 出
            提示 = String(format: "%.1f MB · %d×%d", Double(字节) / 1048576, Int(图.size.width), Int(图.size.height))
        } else {
            提示 = "出图失败"
        }
        跑着 = false
    }

    private func 存一张() async {
        guard let p = 成品路径, let d = try? Data(contentsOf: p) else { return }
        let 权 = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard 权 == .authorized || 权 == .limited else {
            提示 = "没相册权限"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let 请求 = PHAssetCreationRequest.forAsset()
                let 选项 = PHAssetResourceCreationOptions()
                选项.uniformTypeIdentifier = "public.jpeg"
                请求.addResource(with: .photo, data: d, options: 选项)
            }
            提示 = "已存进相册"
        } catch {
            提示 = "存失败"
        }
    }
}

// ===== 来自 根视图.swift =====
struct 编辑目标: Identifiable {
    let id: String
    let 资产: PHAsset
}

/// 根视图：三个 Tab + 相册/编辑/批量三个覆盖层
struct 根视图: View {
    @StateObject private var 相 = 相册模型()
    @StateObject private var 批 = 批量引擎()

    @State private var 页 = 0                 // 0 修图 1 灵感 2 我的
    @State private var 风格 = 出图风格.读()
    @Environment(\.scenePhase) private var 场景

    @State private var 显示相册 = false
    @State private var 相册多选 = false
    @State private var 显示批量 = false
    @State private var 显示多选 = false
    @State private var 批项: [来源] = []
    @State private var 目标: 编辑目标?
    // 抠图页（2026-11-21 新增）：首页「智能抠图」原来走批量修图，现在走这里
    @State private var 抠图开 = false
    @State private var 抠图选: PhotosPickerItem?
    @State private var 抠图图: UIImage?
    @State private var 显示抠图 = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch 页 {
                case 0: 首页视图(开相册: 开相册, 开批量: 开批量, 风格: $风格)
                case 1: 灵感视图()
                default: 我的视图()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            底栏
        }
        .background(Color.white)
        .fullScreenCover(isPresented: $显示相册) {
            相册视图(相: 相, 多选: 相册多选) { 选 in
                显示相册 = false
                if 选.isEmpty { return }
                if 相册多选 {
                    批项 = 选.map { 来源.资产($0) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { 显示批量 = true }
                } else if let 一 = 选.first {
                    目标 = 编辑目标(id: 一.localIdentifier, 资产: 一)
                }
            } 取消: {
                显示相册 = false
            }
        }
        .fullScreenCover(isPresented: $显示批量) {
            批量视图(批: 批, 风格: $风格, 项们: 批项) {
                显示批量 = false
            }
        }
        .sheet(isPresented: $显示多选) {
            多选图 { 结果们 in
                显示多选 = false
                guard !结果们.isEmpty else { return }
                批项 = 结果们.map { 来源.结果($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { 显示批量 = true }
            }
        }
        .photosPicker(isPresented: $抠图开, selection: $抠图选, matching: .images)
        .onChange(of: 抠图选) { 新 in
            guard let 新 else { return }
            Task {
                if let 数据 = try? await 新.loadTransferable(type: Data.self),
                   let 图 = UIImage(data: 数据) {
                    抠图图 = 图
                    显示抠图 = true
                }
                抠图选 = nil
            }
        }
        .fullScreenCover(isPresented: $显示抠图) {
            if let 图 = 抠图图 {
                抠图页(原图: 图, 完成: { _ in
                    显示抠图 = false
                    抠图图 = nil
                }, 取消: {
                    显示抠图 = false
                    抠图图 = nil
                })
            }
        }
        .fullScreenCover(item: $目标) { t in
            编辑台(资产: t.资产, 风格: $风格, 用这套出全部: {
                // 带着这套参数去相册里挑要套用的那批
                目标 = nil
                相册多选 = true
                显示相册 = true
            }, 关闭: {
                目标 = nil
            })
        }
    }

    private func 开相册(_ 多选: Bool) {
        if 多选 {
            显示多选 = true          // 批量：系统选择器，可划选
        } else {
            相册多选 = false
            显示相册 = true          // 单张：自绘相册页
        }
    }

    private func 开批量(_ 规格: String) {
        风格.规格名 = 规格
        if 批项.isEmpty {
            显示多选 = true          // 系统选择器：能划着选，100 张也快
        } else {
            显示批量 = true
        }
    }

    private var 底栏: some View {
        HStack {
            ForEach(Array(["修图", "灵感", "我的"].enumerated()), id: \.offset) { i, 名 in
                Button { 页 = i } label: {
                    VStack(spacing: 3) {
                        Text(名)
                            .font(.system(size: 12, weight: 页 == i ? .bold : .medium))
                            .foregroundStyle(页 == i ? 图来色.字 : 图来色.次字)
                        Rectangle()
                            .fill(页 == i ? 图来色.绿 : Color.clear)
                            .frame(width: 18, height: 3)
                            .clipShape(Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color.white)
        .overlay(Rectangle().fill(图来色.线).frame(height: 1), alignment: .top)
    }
}

/// 灵感（先用占位卡）
struct 灵感视图: View {
    private let 卡们: [(String, Color)] = [
        ("白底商品图 800", Color(red: 0.79, green: 0.84, blue: 0.89)),
        ("白边主图", Color(red: 0.94, green: 0.90, blue: 0.84)),
        ("批量 100 张", Color(red: 0.85, green: 0.91, blue: 0.77)),
        ("消除水印", Color(red: 0.89, green: 0.84, blue: 0.92)),
        ("清透人像", Color(red: 0.84, green: 0.88, blue: 0.93)),
        ("暖调裤装", Color(red: 0.96, green: 0.91, blue: 0.86))
    ]
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text("灵感").font(.system(size: 17, weight: .bold)).foregroundStyle(图来色.字)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                    ForEach(Array(卡们.enumerated()), id: \.offset) { i, t in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 12).fill(t.1)
                                .frame(height: i % 2 == 0 ? 190 : 150)
                            Text(t.0).font(.system(size: 12)).foregroundStyle(图来色.字)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .background(Color.white)
    }
}

/// 我的
struct 我的视图: View {
    /// 开发者选项：打开后「去水印」页才会显示「本机/电脑/远程」和地址填写。
    /// 客户不需要那台电脑，默认关闭。
    @AppStorage("去水印.高级") private var 高级 = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 26))
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(图来色.浅绿))
                        .foregroundStyle(图来色.字)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("图来小店").font(.system(size: 18, weight: .bold)).foregroundStyle(图来色.字)
                        Text("图来 · 店铺版").font(.system(size: 11)).foregroundStyle(图来色.次字)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)

                Divider().overlay(图来色.线).padding(.horizontal, 16)
                行("白底规格说明", "800×800，主体占 92%，白度 ≥ 232")
                行("出图体积", "每张压到 7MB 以内")
                行("关于", "图来 v2 · 本地处理，不上传")
                Toggle(isOn: $高级) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("开发者选项").font(.system(size: 14, weight: .semibold)).foregroundStyle(图来色.字)
                        Text("显示「本机 / 电脑 / 远程」解析通道与地址设置")
                            .font(.system(size: 11.5)).foregroundStyle(图来色.次字)
                    }
                }
                .tint(图来色.字)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color.white)
                .overlay(Rectangle().fill(图来色.线).frame(height: 1), alignment: .bottom)
                Spacer(minLength: 30)
            }
        }
        .background(Color.white)
    }

    private func 行(_ 名: String, _ 值: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(名).font(.system(size: 14, weight: .semibold)).foregroundStyle(图来色.字)
            Text(值).font(.system(size: 11.5)).foregroundStyle(图来色.次字)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.white)
        .overlay(Rectangle().fill(图来色.线).frame(height: 1), alignment: .bottom)
    }
}


/// 批量的输入来源：自绘相册挑的，或系统选择器挑的
enum 来源 {
    case 资产(PHAsset)
    case 结果(PHPickerResult)

    func 取数据() async -> Data? {
        switch self {
        case .资产(let a): return await a.取数据()
        case .结果(let r): return await r.取数据()
        }
    }
}

extension PHPickerResult {
    func 取数据() async -> Data? {
        await withCheckedContinuation { (续: CheckedContinuation<Data?, Never>) in
            var 已回 = false
            itemProvider.loadFileRepresentation(forTypeIdentifier: "public.image") { url, _ in
                if 已回 { return }
                已回 = true
                guard let url else {
                    续.resume(returning: nil)
                    return
                }
                let 名 = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
                let 临时 = FileManager.default.temporaryDirectory.appendingPathComponent(名)
                try? FileManager.default.copyItem(at: url, to: 临时)
                let 数据 = try? Data(contentsOf: 临时)
                try? FileManager.default.removeItem(at: 临时)
                续.resume(returning: 数据)
            }
        }
    }
}

// ===== 来自 首页.swift =====
/// 首页（浅色，照手机上的醒图排版）
struct 首页视图: View {
    var 开相册: (Bool) -> Void
    var 开批量: (String) -> Void
    @Binding var 风格: 出图风格

    private let 四卡: [(String, String)] = [
        ("修实况 Live", "livephoto"), ("智能修图", "wand.and.stars"),
        ("AI 造型室", "person.crop.square"), ("拼图", "square.grid.2x2")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                英雄
                    .frame(height: 236)

                HStack(spacing: 12) {
                    Button {
                        开相册(false)
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(图来色.绿).frame(width: 30, height: 30)
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(图来色.字)
                            }
                            Text("导入照片").font(.system(size: 17, weight: .bold))
                        }
                    }
                    .buttonStyle(大按钮样式(底: 图来色.字, 字色: .white))

                    Button {
                        开相册(false)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "camera.fill").font(.system(size: 18, weight: .bold))
                            Text("相机").font(.system(size: 17, weight: .bold))
                        }
                    }
                    .buttonStyle(大按钮样式(底: 图来色.绿, 字色: 图来色.字))
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                HStack(spacing: 9) {
                    ForEach(四卡, id: \.0) { 项 in
                        Button {
                            if 项.0 == "智能修图" { 开相册(false) }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: 项.1).font(.system(size: 22, weight: .medium))
                                Text(项.0).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 76)
                            .background(图来色.浅绿)
                            .foregroundStyle(图来色.字)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                八宫格区 { 名 in
                    switch 名 {
                    case "批量修图": 开相册(true)
                    case "魔法消除", "瘦脸瘦身": 开相册(false)
                    case "智能抠图": 抠图开 = true
                    default: break
                    }
                }
                .padding(.top, 8)

                分节标题(字: "店铺工具", 右: "白底 / 白边 / 批量 都在这")
                HStack(spacing: 9) {
                    店铺卡("白底 800", "抖店纯白底", "square.dashed") {
                        风格.规格名 = "白底"; 开批量("白底")
                    }
                    店铺卡("白边图", "主体撑满 + 白边", "rectangle.inset.filled") {
                        风格.规格名 = "白边"; 开批量("白边")
                    }
                }
                .padding(.horizontal, 16)
                HStack(spacing: 9) {
                    店铺卡("批量 100 张", "一次选满一键出", "square.stack.3d.down.right") {
                        开相册(true)
                    }
                    店铺卡("消除水印", "涂一下就去掉", "wand.and.rays") {
                        开相册(false)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 9)

                分节标题(字: "为你推荐")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        推荐卡("白底图 800 · 抖店主图", Color(red: 0.79, green: 0.84, blue: 0.89))
                        推荐卡("白边图 · 一件不偏心", Color(red: 0.94, green: 0.90, blue: 0.84))
                        推荐卡("批量 100 张 · 一次出完", Color(red: 0.85, green: 0.91, blue: 0.77))
                        推荐卡("消除水印 · 涂一下就没", Color(red: 0.89, green: 0.84, blue: 0.92))
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 24)
            }
        }
        .background(Color.white)
    }

    private var 英雄: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.15, blue: 0.17),
                                    Color(red: 0.24, green: 0.28, blue: 0.32)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 8) {
                Text("◇ 图来 · 白底工坊")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
                Text("一键出白底\n抖店主图")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(.white)
                Text("800×800 纯白底 · 白边图 · 一次 100 张")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(18)
        }
        .clipped()
    }

    private func 店铺卡(_ 名: String, _ 说明: String, _ 图标: String,
                     _ 点: @escaping () -> Void) -> some View {
        Button(action: 点) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.6))
                        .frame(width: 34, height: 34)
                    Image(systemName: 图标).font(.system(size: 17, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(名).font(.system(size: 13.5, weight: .bold))
                    Text(说明).font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.37, green: 0.43, blue: 0.27))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(图来色.浅绿)
            .foregroundStyle(图来色.字)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func 推荐卡(_ 名: String, _ 色: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10).fill(色).frame(width: 118, height: 158)
            Text(名).font(.system(size: 11.5)).foregroundStyle(图来色.字)
                .frame(width: 118, alignment: .leading).lineLimit(2)
        }
    }
}

/// 八宫格
struct 八宫格区: View {
    var 点: (String) -> Void
    private let 项: [(String, String)] = [
        ("批量修图", "square.stack.3d.up.fill"),
        ("画质超清", "sparkles"),
        ("魔法消除", "wand.and.rays"),
        ("智能抠图", "person.crop.rectangle"),
        ("AI 修图", "photo.badge.checkmark"),
        ("瘦脸瘦身", "face.smiling"),
        ("所有工具", "square.grid.2x2")
    ]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 6) {
            ForEach(项, id: \.0) { t in
                Button { 点(t.0) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: t.1).font(.system(size: 21, weight: .medium))
                            .frame(height: 24)
                        Text(t.0).font(.system(size: 10.5)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(图来色.字)
                }
            }
        }
        .padding(.horizontal, 10)
    }
}

// ===== 编辑台 v3（实时滑块 · 消除 · 滤镜强度 · 文字） =====

struct 子项 {
    let 名: String
    let 键: WritableKeyPath<调节参数, Double>?
    let 图标: String
}

struct 编辑台: View {
    let 资产: PHAsset
    @Binding var 风格: 出图风格
    var 用这套出全部: () -> Void
    var 关闭: () -> Void

    @State private var 原CG: CGImage?
    @State private var 预览: UIImage?
    @State private var 参 = 调节参数()
    @State private var 主 = "人像"
    @State private var 子 = "磨皮"
    @State private var 滑块值 = 0.0
    @State private var 拖动中 = false
    @State private var 提示 = ""
    @State private var 原尺寸 = ""
    @State private var 跑着 = false

    // 滤镜
    @State private var 滤镜名 = "原图"
    @State private var 滤镜强 = 100.0

    // 消除
    @State private var 消除点: [CGPoint] = []     // 归一化 0~1
    @State private var 笔粗 = 26.0
    @State private var 擦着 = false

    // 涂鸦
    @State private var 涂层: [[CGPoint]] = []
    @State private var 笔画: [CGPoint] = []
    @State private var 涂色 = 0
    @State private var 涂粗 = 8.0

    // 文字
    @State private var 文字 = ""
    @State private var 字号 = 48.0
    @State private var 文字色 = 0            // 0 白 1 黑 2 绿
    @State private var 文字位 = 1            // 0 上 1 中 2 下

    @State private var 渲染任务: Task<Void, Never>?

    private let 主们 = ["人像", "滤镜", "调节", "裁剪", "消除", "文字", "涂鸦"]
    private let 比例们 = ["原图", "1:1", "3:2", "2:3", "3:4", "4:3", "9:16", "16:9"]
    private let 文字色们: [(String, Color)] = [("白", .white), ("黑", .black), ("绿", 图来色.绿)]
    private let 滤镜表: [(String, [(WritableKeyPath<调节参数, Double>, Double)])] = [
        ("原图", []),
        ("清爽", [(\调节参数.亮度, 4), (\调节参数.对比, 6), (\调节参数.饱和, 12), (\调节参数.色温, -4)]),
        ("鲜亮", [(\调节参数.对比, 12), (\调节参数.饱和, 25)]),
        ("暖调", [(\调节参数.亮度, 2), (\调节参数.饱和, 8), (\调节参数.色温, 18)]),
        ("冷调", [(\调节参数.对比, 6), (\调节参数.饱和, 4), (\调节参数.色温, -16)]),
        ("黑白", [(\调节参数.饱和, -100), (\调节参数.对比, 8)]),
        ("褪色", [(\调节参数.褪色, 30), (\调节参数.对比, -4)]),
        ("胶片", [(\调节参数.对比, 10), (\调节参数.饱和, -12), (\调节参数.色温, 8), (\调节参数.褪色, 26)]),
        ("光感", [(\调节参数.光感, 40), (\调节参数.亮度, 4)]),
        ("清透", [(\调节参数.亮度, 6), (\调节参数.阴影, 20), (\调节参数.褪色, 8)]
        )
    ]

    var body: some View {
        ZStack {
            图来色.编底.ignoresSafeArea()
            VStack(spacing: 0) {
                顶栏
                预览区
                面板
            }
        }
        .task { await 载图() }
    }

    // MARK: 顶栏
    private var 顶栏: some View {
        HStack(spacing: 14) {
            Button { 关闭() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            }
            Button { 复位() } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 17)).foregroundStyle(.white)
            }
            Spacer()
            Text(提示.isEmpty ? 原尺寸 : 提示)
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            Spacer()
            Button { Task { await 出图并保存() } } label: {
                Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold))
                    .foregroundStyle(图来色.编底)
                    .frame(width: 34, height: 34).background(Circle().fill(图来色.绿))
            }
            Button {
                风格.参 = 参
                用这套出全部()
            } label: {
                Text("出全部").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(图来色.编底)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Capsule().fill(.white))
            }
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 8)
    }

    // MARK: 预览
    private var 预览区: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let 图 = 预览 {
                    let 框 = 适配框(图.size, geo.size)
                    Image(uiImage: 图)
                        .resizable()
                        .frame(width: 框.width, height: 框.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    if 主 == "消除" {
                        消除层(框, geo.size)
                    }
                    涂鸦层(框, geo.size)
                        .allowsHitTesting(主 == "涂鸦")
                    if !文字.isEmpty {
                        叠文字(框, geo.size)
                    }
                } else {
                    ProgressView().tint(图来色.绿)
                }
                if 跑着 || 擦着 {
                    ProgressView().tint(图来色.绿).scaleEffect(0.85)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func 适配框(_ 尺寸: CGSize, _ 区: CGSize) -> CGRect {
        guard 尺寸.width > 0, 尺寸.height > 0 else { return CGRect(origin: .zero, size: 区) }
        let 比 = min((区.width - 16) / 尺寸.width, (区.height - 16) / 尺寸.height)
        let w = 尺寸.width * 比, h = 尺寸.height * 比
        return CGRect(x: (区.width - w) / 2, y: (区.height - h) / 2, width: w, height: h)
    }

    private func 消除层(_ 框: CGRect, _ 区: CGSize) -> some View {
        ZStack {
            Color.clear
            Canvas { 上, 大 in
                var 路 = Path()
                for (i, p) in 消除点.enumerated() {
                    let x = 框.minX + p.x * 框.width
                    let y = 框.minY + p.y * 框.height
                    if i == 0 { 路.move(to: CGPoint(x: x, y: y)) } else {
                        路.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                上.stroke(路, with: .color(图来色.绿.opacity(0.55)),
                        style: StrokeStyle(lineWidth: 笔粗, lineCap: .round, lineJoin: .round))
            }
            .allowsHitTesting(false)
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let p = CGPoint(
                                x: max(0, min(1, (v.location.x - 框.minX) / 框.width)),
                                y: max(0, min(1, (v.location.y - 框.minY) / 框.height)))
                            if 消除点.isEmpty || 距(消除点.last!, p) > 0.004 { 消除点.append(p) }
                        }
                )
        }
    }

    private var 涂色们: [(String, Color)] { [("白", .white), ("黑", .black), ("绿", 图来色.绿), ("红", .red)] }

    private func 涂鸦层(_ 框: CGRect, _ 区: CGSize) -> some View {
        let 色 = 涂色们[min(3, max(0, 涂色))].1
        return ZStack {
            Canvas { 上, _ in
                for 层 in 涂层 + (笔画.isEmpty ? [] : [笔画]) {
                    if 层.count < 2 { continue }
                    var 路 = Path()
                    for (i, p) in 层.enumerated() {
                        let x = 框.minX + p.x * 框.width
                        let y = 框.minY + p.y * 框.height
                        if i == 0 { 路.move(to: CGPoint(x: x, y: y)) } else { 路.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    上.stroke(路, with: .color(色),
                             style: StrokeStyle(lineWidth: 涂粗 * 框.width / 900, lineCap: .round, lineJoin: .round))
                }
            }
            .allowsHitTesting(false)
            if 主 == "涂鸦" {
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let p = CGPoint(
                                    x: max(0, min(1, (v.location.x - 框.minX) / 框.width)),
                                    y: max(0, min(1, (v.location.y - 框.minY) / 框.height)))
                                if 笔画.isEmpty || 距(笔画.last!, p) > 0.003 { 笔画.append(p) }
                            }
                            .onEnded { _ in
                                if 笔画.count > 1 { 涂层.append(笔画) }
                                笔画 = []
                            }
                    )
            }
        }
    }

    private func 距(_ a: CGPoint, _ b: CGPoint) -> Double {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }

    private func 叠文字(_ 框: CGRect, _ 区: CGSize) -> some View {
        let 色 = 文字色们[min(2, max(0, 文字色))].1
        let y: CGFloat = 文字位 == 0 ? 框.minY + 框.height * 0.1
            : (文字位 == 1 ? 框.midY : 框.maxY - 框.height * 0.14)
        return Text(文字)
            .font(.system(size: CGFloat(字号) * 框.width / 900, weight: .bold))
            .foregroundStyle(色)
            .shadow(color: .black.opacity(0.35), radius: 3)
            .position(x: 框.midX, y: y)
            .allowsHitTesting(false)
    }

    // MARK: 面板
    private var 面板: some View {
        VStack(spacing: 6) {
            if 需要滑块 { 滑块行 }
            子工具行
            主工具行
        }
        .padding(.bottom, 10)
        .background(图来色.编底)
    }

    private var 需要滑块: Bool { 主 == "人像" || 主 == "调节" || 主 == "滤镜" || 主 == "消除" }

    private var 滑块行: some View {
        HStack(spacing: 10) {
            Text(主 == "滤镜" ? "强度" : (主 == "消除" ? "笔粗" : 子))
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                .frame(width: 52, alignment: .leading)
            Slider(value: Binding(
                get: { 滑块值 },
                set: { 新 in
                    滑块值 = 新
                    应用滑块(新)
                    排渲染()
                }), in: 滑块范围, onEditingChanged: { 开始 in
                    拖动中 = 开始
                    if !开始 { 重画() }
                })
                .tint(图来色.绿)
            Text(String(format: "%.0f", 滑块值))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(图来色.绿).frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.top, 8)
    }

    private var 滑块范围: ClosedRange<Double> {
        switch 主 {
        case "滤镜": return 0...100
        case "消除": return 6...80
        default: return -100...100
        }
    }

    private func 应用滑块(_ 新: Double) {
        switch 主 {
        case "滤镜":
            滤镜强 = 新
            套滤镜(滤镜名, 强度: 新)
        case "消除":
            笔粗 = 新
        default:
            if let 键 = 当前键 { 参[keyPath: 键] = 新 }
        }
    }

    private var 当前键: WritableKeyPath<调节参数, Double>? {
        子表.first(where: { $0.名 == 子 })?.键
    }

    private var 子表: [子项] {
        switch 主 {
        case "人像":
            return [子项(名: "磨皮", 键: \调节参数.磨皮, 图标: "face.smiling"),
                    子项(名: "美白", 键: \调节参数.美白, 图标: "sun.max"),
                    子项(名: "瘦脸", 键: \调节参数.瘦脸, 图标: "person.crop.circle")]
        case "调节":
            return [子项(名: "原图", 键: nil, 图标: "arrow.counterclockwise"),
                    子项(名: "亮度", 键: \调节参数.亮度, 图标: "sun.max"),
                    子项(名: "对比度", 键: \调节参数.对比, 图标: "circle.lefthalf.filled"),
                    子项(名: "饱和度", 键: \调节参数.饱和, 图标: "drop"),
                    子项(名: "自然饱和", 键: \调节参数.自然饱和, 图标: "drop.halffull"),
                    子项(名: "曝光", 键: \调节参数.曝光, 图标: "camera.aperture"),
                    子项(名: "高光", 键: \调节参数.高光, 图标: "sun.min"),
                    子项(名: "阴影", 键: \调节参数.阴影, 图标: "moon"),
                    子项(名: "色温", 键: \调节参数.色温, 图标: "thermometer"),
                    子项(名: "色调", 键: \调节参数.色调, 图标: "paintpalette"),
                    子项(名: "清晰度", 键: \调节参数.清晰度, 图标: "square.stack.3d.up"),
                    子项(名: "锐化", 键: \调节参数.锐化, 图标: "triangle"),
                    子项(名: "纹理", 键: \调节参数.纹理, 图标: "square.grid.3x3"),
                    子项(名: "颗粒", 键: \调节参数.颗粒, 图标: "circle.grid.3x3"),
                    子项(名: "褪色", 键: \调节参数.褪色, 图标: "rectangle.filled.and.line.vertical"),
                    子项(名: "光感", 键: \调节参数.光感, 图标: "sparkles")]
        default:
            return []
        }
    }

    @ViewBuilder private var 子工具行: some View {
        switch 主 {
        case "滤镜":
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(滤镜表, id: \.0) { t in
                        Button {
                            滤镜名 = t.0
                            套滤镜(t.0, 强度: 滤镜强)
                        } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(滤镜名 == t.0 ? 图来色.绿.opacity(0.85) : Color.white.opacity(0.15))
                                    .frame(width: 54, height: 54)
                                    .overlay(Image(systemName: "camera.filters")
                                        .font(.system(size: 18))
                                        .foregroundStyle(滤镜名 == t.0 ? 图来色.编底 : .white))
                                Text(t.0).font(.system(size: 9.5))
                                    .foregroundStyle(滤镜名 == t.0 ? 图来色.绿 : .white.opacity(0.8))
                            }
                        }
                    }
                }.padding(.horizontal, 14)
            }
        case "裁剪":
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(比例们, id: \.self) { 比 in
                        Button { 裁(比) } label: {
                            Text(比).font(.system(size: 12.5, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.white.opacity(0.12)).foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    Button { 转90() } label: {
                        Image(systemName: "rotate.right").font(.system(size: 14))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.white.opacity(0.12)).foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    Button { 镜像() } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .font(.system(size: 13))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.white.opacity(0.12)).foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }.padding(.horizontal, 14)
            }
        case "消除":
            HStack(spacing: 10) {
                Button {
                    Task { await 做擦除() }
                } label: {
                    Text("开始擦除").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(图来色.编底)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(图来色.绿))
                }
                Button {
                    消除点.removeAll()
                } label: {
                    Text("清空").font(.system(size: 12.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                Spacer()
                Text("在图上涂掉要擦的地方").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }.padding(.horizontal, 14)
        case "涂鸦":
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(Array(涂色们.enumerated()), id: \.offset) { i, t in
                        Circle().fill(t.1).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(涂色 == i ? 图来色.绿 : Color.white.opacity(0.3), lineWidth: 2))
                            .onTapGesture { 涂色 = i }
                    }
                }
                Text("粗细").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                Slider(value: $涂粗, in: 2...40).tint(图来色.绿).frame(width: 110)
                Button { 涂层.removeAll(); 笔画 = [] } label: {
                    Text("清空").font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .foregroundStyle(.white)
                }
                Spacer()
            }.padding(.horizontal, 14)
        case "文字":
            VStack(spacing: 8) {
                TextField("输入文字", text: $文字)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.white.opacity(0.10))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                HStack(spacing: 10) {
                    Text("字号").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    Slider(value: $字号, in: 16...140).tint(图来色.绿)
                    HStack(spacing: 6) {
                        ForEach(Array(文字色们.enumerated()), id: \.offset) { i, t in
                            Circle().fill(t.1).frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(文字色 == i ? 图来色.绿 : Color.white.opacity(0.3), lineWidth: 2))
                                .onTapGesture { 文字色 = i }
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(Array(["上", "中", "下"].enumerated()), id: \.offset) { i, t in
                            Text(t).font(.system(size: 11))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(文字位 == i ? 图来色.绿 : Color.white.opacity(0.12))
                                .foregroundStyle(文字位 == i ? 图来色.编底 : .white)
                                .clipShape(Capsule())
                                .onTapGesture { 文字位 = i }
                        }
                    }
                }
            }.padding(.horizontal, 14)
        default:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(子表, id: \.名) { t in
                        Button { 点子项(t) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: t.图标).font(.system(size: 19))
                                Text(t.名).font(.system(size: 9.5)).lineLimit(1)
                            }
                            .frame(width: 62).padding(.vertical, 4)
                            .foregroundStyle(子 == t.名 ? 图来色.绿 : .white.opacity(0.85))
                        }
                    }
                }.padding(.horizontal, 10)
            }
        }
    }

    private var 主工具行: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(主们, id: \.self) { m in
                    Button { 选主(m) } label: {
                        VStack(spacing: 4) {
                            Text(m).font(.system(size: 14.5, weight: 主 == m ? .bold : .regular))
                                .foregroundStyle(主 == m ? 图来色.绿 : .white.opacity(0.8))
                            Rectangle().fill(主 == m ? 图来色.绿 : Color.clear)
                                .frame(width: 16, height: 2.5).clipShape(Capsule())
                        }
                    }
                }
                ForEach(["模版", "贴纸", "特效"], id: \.self) { m in
                    Text(m).font(.system(size: 14.5)).foregroundStyle(.white.opacity(0.28))
                }
            }.padding(.horizontal, 18)
        }.padding(.top, 4)
    }

    // MARK: 逻辑
    private func 载图() async {
        guard 原CG == nil else { return }
        guard let 图 = await 资产.取图(边长: 2000), let cg = 图.cgImage else {
            提示 = "这张读不出来"; return
        }
        原CG = cg
        原尺寸 = "\(cg.width)×\(cg.height)"
        重画()
    }

    private func 选主(_ m: String) {
        主 = m
        switch m {
        case "人像": 子 = "磨皮"; 滑块值 = 参.磨皮
        case "调节": 子 = "亮度"; 滑块值 = 参.亮度
        case "滤镜": 滑块值 = 滤镜强
        case "消除": 滑块值 = 笔粗
        default: break
        }
    }

    private func 点子项(_ t: 子项) {
        子 = t.名
        if let 键 = t.键 { 滑块值 = 参[keyPath: 键] }
        else if t.名 == "原图" { 参 = 调节参数(); 滑块值 = 0; 重画() }
    }

    private func 套滤镜(_ 名: String, 强度: Double) {
        let k = 强度 / 100
        for (k2, v) in 滤镜表.first(where: { $0.0 == 名 })?.1 ?? [] {
            参[keyPath: k2] = v * k
        }
        重画()
    }

    private func 复位() {
        参 = 调节参数(); 滑块值 = 0; 提示 = "已复位"; 重画()
    }

    private func 裁(_ 比: String) {
        guard let cg = 原CG, 比 != "原图" else { return }
        原CG = 修图.裁比例(cg, 比例: 比)
        提示 = "裁成 \(比)"
        重画()
    }

    private func 转90() {
        guard let cg = 原CG else { return }
        let w = cg.width, h = cg.height
        guard let 上 = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        上.translateBy(x: CGFloat(h) / 2, y: CGFloat(w) / 2)
        上.rotate(by: .pi / 2)
        上.draw(cg, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        原CG = 上.makeImage()
        重画()
    }

    private func 镜像() {
        guard let cg = 原CG else { return }
        let w = cg.width, h = cg.height
        guard let 上 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        上.translateBy(x: CGFloat(w), y: 0); 上.scaleBy(x: -1, y: 1)
        上.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        原CG = 上.makeImage()
        重画()
    }

    private func 做擦除() async {
        guard let cg = 原CG, !消除点.isEmpty else { 提示 = "先涂一下"; return }
        擦着 = true
        let 点 = 消除点
        let 粗 = 笔粗
        let w = cg.width, h = cg.height
        let 出 = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            var 掩 = [Bool](repeating: false, count: w * h)
            let 半径 = max(3, Int(Double(min(w, h)) * 粗 / 900))
            for p in 点 {
                let cx = Int(p.x * Double(w)), cy = Int(p.y * Double(h))
                let r2 = 半径 * 半径
                for y in max(0, cy - 半径)...min(h - 1, cy + 半径) {
                    for x in max(0, cx - 半径)...min(w - 1, cx + 半径) {
                        let dx = x - cx, dy = y - cy
                        if dx * dx + dy * dy <= r2 { 掩[y * w + x] = true }
                    }
                }
            }
            return 修图.平滑填补(cg, 掩)
        }.value
        if let 出 {
            原CG = 出
            消除点.removeAll()
            提示 = "擦好了"
            重画()
        } else {
            提示 = "擦除失败"
        }
        擦着 = false
    }

    private func 排渲染() {
        渲染任务?.cancel()
        渲染任务 = Task { await 渲染() }
    }

    private func 重画() {
        渲染任务?.cancel()
        渲染任务 = Task { await 渲染() }
    }

    private func 渲染() async {
        guard let cg = 原CG else { return }
        let 快照 = 参
        let 边长: CGFloat = 拖动中 ? 520 : 1400
        let 出 = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            修图.精调(缩(cg, 边长), 快照)
        }.value
        if let 出 {
            await MainActor.run { self.预览 = UIImage(cgImage: 出) }
        }
    }

    private func 缩(_ cg: CGImage, _ 最长: CGFloat) -> CGImage {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let m = max(w, h)
        if m <= 最长 { return cg }
        let 比 = 最长 / m
        let 新W = max(1, Int(w * 比)), 新H = max(1, Int(h * 比))
        guard let 上 = CGContext(data: nil, width: 新W, height: 新H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return cg }
        上.interpolationQuality = .high
        上.draw(cg, in: CGRect(x: 0, y: 0, width: 新W, height: 新H))
        return 上.makeImage() ?? cg
    }

    private func 出图并保存() async {
        guard let cg = 原CG else { return }
        跑着 = true; 提示 = "正在出图…"
        let 快照 = 参
        let 文字快照 = 文字
        let 字快照 = 字号
        let 色快照 = 文字色们[min(2, max(0, 文字色))].1
        let 位快照 = 文字位
        let 出 = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let 基 = 修图.精调(cg, 快照) else { return nil }
            if 文字快照.isEmpty && 涂层.isEmpty { return 基 }
            let 尺寸 = CGSize(width: 基.width, height: 基.height)
            let 格式 = UIGraphicsImageRendererFormat.default()
            格式.scale = 1
            let 渲染 = UIGraphicsImageRenderer(size: 尺寸, format: 格式)
            let 涂层快照 = 涂层
            let 涂色快照 = 涂色们[min(3, max(0, 涂色))].1
            let 涂粗快照 = 涂粗
            let 图 = 渲染.image { 上下文 in
                UIImage(cgImage: 基).draw(in: CGRect(origin: .zero, size: 尺寸))
                if !涂层快照.isEmpty {
                    let 线宽 = CGFloat(涂粗快照) * 尺寸.width / 900
                    上下文.cgContext.setLineCap(.round)
                    上下文.cgContext.setLineJoin(.round)
                    上下文.cgContext.setStrokeColor(UIColor(涂色快照).cgColor)
                    上下文.cgContext.setLineWidth(线宽)
                    for 层 in 涂层快照 where 层.count > 1 {
                        上下文.cgContext.beginPath()
                        for (i, p) in 层.enumerated() {
                            let pt = CGPoint(x: p.x * 尺寸.width, y: p.y * 尺寸.height)
                            if i == 0 { 上下文.cgContext.move(to: pt) } else { 上下文.cgContext.addLine(to: pt) }
                        }
                        上下文.cgContext.strokePath()
                    }
                }
                let 字 = UIFont.systemFont(ofSize: CGFloat(字快照) * 尺寸.width / 900, weight: .bold)
                let 属性: [NSAttributedString.Key: Any] = [.font: 字, .foregroundColor: 色快照]
                let 大小 = (文字快照 as NSString).size(withAttributes: 属性)
                let y = 位快照 == 0 ? 尺寸.height * 0.08
                    : (位快照 == 1 ? (尺寸.height - 大小.height) / 2 : 尺寸.height * 0.9 - 大小.height)
                (文字快照 as NSString).draw(at: CGPoint(x: (尺寸.width - 大小.width) / 2, y: y),
                                         withAttributes: 属性)
            }
            return 图.cgImage
        }.value
        guard let 出, let 数据 = 压JPEG(出) else {
            提示 = "出图失败"; 跑着 = false; return
        }
        let 路径 = FileManager.default.temporaryDirectory.appendingPathComponent("编辑出图.jpg")
        try? 数据.write(to: 路径)
        提示 = String(format: "%.1f MB · %d×%d", Double(数据.count) / 1048576, 出.width, 出.height)
        _ = await 存(路径)
        跑着 = false
    }

    private func 压JPEG(_ cg: CGImage, 上限: Int = 7 * 1024 * 1024) -> Data? {
        var 图 = cg
        var 质: CGFloat = 0.95
        var 数据 = UIImage(cgImage: 图).jpegData(compressionQuality: 质)
        while let d = 数据, d.count > 上限, 质 > 0.5 {
            质 -= 0.07
            数据 = UIImage(cgImage: 图).jpegData(compressionQuality: 质)
        }
        var 轮 = 0
        while let d = 数据, d.count > 上限, 轮 < 4 {
            轮 += 1
            let 新W = max(600, 图.width * 4 / 5), 新H = max(600, 图.height * 4 / 5)
            if let 上 = CGContext(data: nil, width: 新W, height: 新H, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                上.interpolationQuality = .high
                上.draw(图, in: CGRect(x: 0, y: 0, width: 新W, height: 新H))
                图 = 上.makeImage() ?? 图
            }
            数据 = UIImage(cgImage: 图).jpegData(compressionQuality: 0.9)
        }
        return 数据
    }

    private func 存(_ 路径: URL) async -> Bool {
        let 权 = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard 权 == .authorized || 权 == .limited else { 提示 = "没相册权限"; return false }
        guard let 数据 = try? Data(contentsOf: 路径) else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let 请求 = PHAssetCreationRequest.forAsset()
                let 选项 = PHAssetResourceCreationOptions()
                选项.uniformTypeIdentifier = "public.jpeg"
                请求.addResource(with: .photo, data: 数据, options: 选项)
            }
            提示 = "已存进相册"
            return true
        } catch {
            提示 = "存失败"
            return false
        }
    }
}

// ============================================================
//  精简版：只做店铺工具（白底 800 / 白边图 / 批量 100 / 消除水印）
// ============================================================

struct 首页2: View {
    var 开相册: (Bool, String) -> Void      // (多选?, 规格)
    @ObservedObject var 相: 相册模型
    @ObservedObject var 批: 批量引擎
    var 开我的: () -> Void
    var 开去水印: () -> Void

    // 新增功能的入口状态。
    // ⚠️ 注意：App 的根视图是 `根视图2 → 首页2`，`主界面` 那个 4 列网格页**没有被使用**。
    //    2026-11-15 之前把「一键增强 / 推脸」加在了 `主界面`，结果装机后看不到 —— 
    //    入口必须加在这个真正显示的页面里。
    @State private var 开一键增强 = false
    @State private var 开推脸 = false
    @State private var 开生图 = false
    @State private var 开词库 = false
    /// 上次崩溃停在哪一步（来自 诊断.swift 的埋点）；成功走完全程会自动清掉
    @State private var 崩溃线索: String? = 诊断.上次()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                头
                // 2026-11-16 改版：8 张卡平铺太乱 → 按用途分三组
                VStack(alignment: .leading, spacing: 6) {
                    分组标题("店铺出图", "买家只看主图，这三步做完就能上架")
                    VStack(spacing: 10) {
                        工具卡("白底 800", "800×800 纯白底，抖店主图直接用",
                            "square.dashed", 图来色.绿) { 开相册(true, "白底") }
                        工具卡("白边图", "主体撑满，四周留白边，一件不偏心",
                            "rectangle.inset.filled", Color(red: 0.92, green: 0.96, blue: 0.84)) { 开相册(true, "白边") }
                        工具卡("批量 100 张", "一次选满，跑完一键全部存相册",
                            "square.stack.3d.down.right", Color(red: 0.85, green: 0.91, blue: 0.77)) { 开相册(true, "白底") }
                    }
                    .padding(.horizontal, 16)

                    分组标题("修图增强", "AI 把糊的、歪的、有杂物的修干净")
                        .padding(.top, 18)
                    VStack(spacing: 10) {
                        工具卡("AI 超清", "AI 4× 放大 + 人脸修复，三档导出（归档/屏幕/放大）",
                            "sparkles", Color(red: 0.90, green: 0.82, blue: 0.96)) { 开一键增强 = true }
                        工具卡("推脸瘦身", "拖动人像局部变形，背景保持不动",
                            "hand.draw.fill", Color(red: 0.96, green: 0.86, blue: 0.86)) { 开推脸 = true }
                        工具卡("消除杂物", "涂一下补背景，可连电脑跑 LaMa",
                            "wand.and.rays", Color(red: 0.93, green: 0.90, blue: 0.85)) { 开相册(false, "消除") }
                    }
                    .padding(.horizontal, 16)

                    分组标题("AI 创作", "从零画一张，或者挑现成的词库")
                        .padding(.top, 18)
                    VStack(spacing: 10) {
                        工具卡("AI 生图", "用电脑显卡出图，几秒一张（手机和电脑同一 Wi-Fi）",
                            "paintbrush.pointed.fill", Color(red: 0.90, green: 0.88, blue: 0.98)) { 开生图 = true }
                        工具卡("提示词库", "动漫词条 + 成品模板，点选即用",
                            "square.grid.2x2.fill", Color(red: 0.88, green: 0.93, blue: 0.99)) { 开词库 = true }
                    }
                    .padding(.horizontal, 16)

                    分组标题("取图工具", "把素材收进来（正式上架前会单独评估一版）")
                        .padding(.top, 18)
                    VStack(spacing: 10) {
                        工具卡("去水印下载", "贴抖音/B站链接，视频图片一键存下来",
                            "link", Color(red: 0.90, green: 0.94, blue: 0.88)) { 开去水印() }
                    }
                    .padding(.horizontal, 16)
                }

                状态区
            }
        }
        .background(Color.white)
        .fullScreenCover(isPresented: $开一键增强) {
            一键增强页 { 开一键增强 = false }
        }
        .fullScreenCover(isPresented: $开推脸) {
            推脸页 { 开推脸 = false }
        }
        .fullScreenCover(isPresented: $开生图) {
            生图页 { 开生图 = false }
        }
        .fullScreenCover(isPresented: $开词库) {
            提示词库页 { 开词库 = false }
        }
    }

    private var 头: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("白底工坊").font(.system(size: 26, weight: .black)).foregroundStyle(图来色.字)
            Text("选图 → 出图 → 存相册 · v2026-11-15.1900")
                .font(.system(size: 12.5)).foregroundStyle(图来色.次字)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
    }

    private var 状态区: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 崩溃定位条：只在"上次没走完"时出现。点一下可清除。
            if let 上次 = 崩溃线索 {
                Button {
                    诊断.清()
                    崩溃线索 = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                        Text("上次停在：\(上次)").font(.system(size: 11)).lineLimit(2)
                        Spacer()
                        Text("清除").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color(red: 0.75, green: 0.25, blue: 0.15))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 1, green: 0.95, blue: 0.93)))
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(图来色.线)
            HStack {
                Text("上次").font(.system(size: 12, weight: .semibold)).foregroundStyle(图来色.字)
                Text(批.状态).font(.system(size: 12)).foregroundStyle(图来色.次字)
                Spacer()
                if 批.产物.count > 0 {
                    Button { Task { _ = await 批.存相册() } } label: {
                        Text(批.已存 ? "已存" : "存这 \(批.产物.count) 张")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(图来色.绿))
                            .foregroundStyle(图来色.字)
                    }
                }
            }
            HStack {
                Text("相册").font(.system(size: 12, weight: .semibold)).foregroundStyle(图来色.字)
                Text(相.被拒 ? "没授权，去 设置→图来→照片 打开"
                     : (相.已授权 ? "已开 · \(相.图们.count) 张" : "未授权"))
                    .font(.system(size: 12)).foregroundStyle(图来色.次字)
                Spacer()
                Button("我的") { 开我的() }
                    .font(.system(size: 12)).foregroundStyle(图来色.次字)
            }
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 30)
    }

    /// 分组标题（2026-11-16 首页改版用）：一行标题 + 一行小字说明
    private func 分组标题(_ 题: String, _ 副: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(题).font(.system(size: 15, weight: .heavy)).foregroundStyle(图来色.字)
            Text(副).font(.system(size: 11)).foregroundStyle(图来色.次字)
        }
        .padding(.horizontal, 16)
    }

    private func 工具卡(_ 名: String, _ 说明: String, _ 图标: String, _ 底: Color,
                     _ 点: @escaping () -> Void) -> some View {
        Button(action: 点) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.75))
                        .frame(width: 52, height: 52)
                    Image(systemName: 图标).font(.system(size: 24, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(名).font(.system(size: 17, weight: .bold))
                    Text(说明).font(.system(size: 11.5))
                        .foregroundStyle(Color(red: 0.35, green: 0.38, blue: 0.32))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.48, blue: 0.42))
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(底)
            .foregroundStyle(图来色.字)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// 极简相册：三列网格，点选，底部「用这 N 张」
struct 相册2: View {
    @ObservedObject var 相: 相册模型
    var 多选: Bool
    var 完成: ([PHAsset]) -> Void
    var 取消: () -> Void

    @State private var 选中: [String] = []
    @State private var 选择模式 = false
    @State private var 起格: Int?
    @State private var 基准: [String] = []
    @State private var 代理: ScrollViewProxy?
    @State private var 滚钟: Timer?
    @State private var 滚锚 = 0
    @State private var 区高: CGFloat = 600
    @State private var 行选 = false

    var body: some View {
        VStack(spacing: 0) {
            顶栏
            内容
            底栏
        }
        .background(Color.white)
        .task {
            if 相.被拒 { return }
            if !相.已授权 { await 相.开始() } else { await 相.读取(.全部) }
        }
    }

    private var 顶栏: some View {
        HStack {
            Button { 取消() } label: {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(图来色.字)
            }
            Spacer()
            Text("选照片").font(.system(size: 16, weight: .semibold)).foregroundStyle(图来色.字)
            Spacer()
            if true {
                Button(选择模式 ? "完成" : "选择") {
                    选择模式.toggle()
                    if !选择模式 { 起格 = nil }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(图来色.字)
            } else {
                Text("\(选中.count)/\(相.图们.count)")
                    .font(.system(size: 12)).foregroundStyle(图来色.次字)
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
    }

    @ViewBuilder private var 内容: some View {
        if 相.被拒 {
            VStack(spacing: 10) {
                Spacer()
                Text("没给相册权限").font(.system(size: 15, weight: .semibold))
                Text("设置 → 图来 → 照片 → 全部").font(.system(size: 12)).foregroundStyle(图来色.次字)
                Spacer()
            }
        } else if 相.图们.isEmpty {
            VStack(spacing: 10) {
                Spacer(); ProgressView()
                Text("正在读相册…").font(.system(size: 13)).foregroundStyle(图来色.次字)
                Spacer()
            }
        } else {
            ScrollViewReader { p in
                ScrollView {
                    网格
                }
                .scrollDisabled(false)
                .onAppear { 代理 = p }
            }
            .background(
                GeometryReader { g in
                    Color.clear.onAppear { 区高 = g.size.height }
                }
            )
        }
    }

    @ViewBuilder private var 网格: some View {
        let 格 = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(Array(相.图们.enumerated()), id: \.element.localIdentifier) { 序, 资产 in
                ZStack(alignment: .topTrailing) {
                    相册格(资产: 资产).frame(height: 126)
                    if 选中.contains(资产.localIdentifier) {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(图来色.绿, lineWidth: 3)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(图来色.绿, .white)
                            .padding(5)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { 点(资产) }
                .id(序)
            }
        }
        .padding(3)
        .coordinateSpace(name: "格2")

        格
    }

    private var 划选: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("格2"))
            .onChanged { v in
                if 起格 == nil {
                    起格 = 格号(v.startLocation)
                    基准 = 选中
                }
                guard let s0 = 起格 else { return }
                let a = min(s0, 格号(v.location)), b = max(s0, 格号(v.location))
                var 出 = 基准
                for i in a...b where i < 相.图们.count {
                    let id = 相.图们[i].localIdentifier
                    if !出.contains(id) { 出.append(id) }
                }
                选中 = 出

                // 拖到边缘 → 自动滚
                if v.location.y < 90 {
                    开始滚(-1)
                } else if v.location.y > 区高 - 90 {
                    开始滚(1)
                } else {
                    停滚()
                }
            }
            .onEnded { _ in
                起格 = nil
                停滚()
            }
    }

    private func 开始滚(_ 向: Int) {
        if 滚钟 != nil { return }
        let 总 = 相.图们.count
        滚锚 = 起格 ?? 0
        滚钟 = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { _ in
            DispatchQueue.main.async {
                guard 选择模式, 总 > 0 else { return }
                let 新 = max(0, min(总 - 1, 滚锚 + 向 * 3))
                if 新 == 滚锚 { return }
                滚锚 = 新
                代理?.scrollTo(新, anchor: .center)
                // 把滚到的那一行也选上
                for k in 新..<min(新 + 3, 总) {
                    let id = 相.图们[k].localIdentifier
                    if !选中.contains(id) { 选中.append(id) }
                }
            }
        }
    }

    private func 停滚() {
        滚钟?.invalidate()
        滚钟 = nil
    }

    private func 格号(_ p: CGPoint) -> Int {
        let 屏宽 = UIScreen.main.bounds.width
        let 格宽 = max(1, (屏宽 - 6 - 6) / 3)
        let 列 = max(0, min(2, Int((p.x - 3) / (格宽 + 3))))
        let 行 = max(0, Int((p.y - 3) / 129))
        return 行 * 3 + 列
    }

    private var 底栏: some View {
        HStack(spacing: 12) {
            if 多选 {
                Button {
                    let 全 = 相.图们.prefix(300).map { $0.localIdentifier }
                    if 选中.count >= 全.count { 选中 = [] } else { 选中 = 全 }
                } label: {
                    Text(选中.isEmpty ? "全选" : "取消全选")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(图来色.字)
                        .frame(width: 84, height: 50)
                        .background(图来色.卡)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Button {
                    行选.toggle()
                } label: {
                    Text(行选 ? "行选:开" : "行选")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(行选 ? 图来色.字 : 图来色.次字)
                        .frame(width: 64, height: 50)
                        .background(行选 ? 图来色.浅绿 : 图来色.卡)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            Button { 取消() } label: {
                Text("取消").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(图来色.字)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(图来色.卡).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Button {
                完成(相.图们.filter { 选中.contains($0.localIdentifier) })
            } label: {
                Text(选中.isEmpty ? "选一张" : "用这 \(选中.count) 张")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(图来色.字)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(选中.isEmpty ? 图来色.卡 : 图来色.绿)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(选中.isEmpty)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
    }

    private func 点(_ 资产: PHAsset) {
        let id = 资产.localIdentifier
        guard 多选 else { 选中 = [id]; return }
        if 行选 {
            guard let 序 = 相.图们.firstIndex(where: { $0.localIdentifier == id }) else { return }
            let 起 = (序 / 3) * 3
            let 止 = min(相.图们.count - 1, 起 + 2)
            let 行们 = (起...止).map { 相.图们[$0].localIdentifier }
            if 行们.allSatisfy({ 选中.contains($0) }) {
                选中.removeAll { 行们.contains($0) }
            } else {
                for x in 行们 where !选中.contains(x) { 选中.append(x) }
            }
        } else if 选中.contains(id) {
            选中.removeAll { $0 == id }
        } else {
            选中.append(id)
        }
    }
}

/// 消除水印：涂 → 擦 → 存
struct 消除页: View {
    let 资产: PHAsset
    var 关闭: () -> Void

    @State private var 原CG: CGImage?
    @State private var 图: UIImage?
    @State private var 点们: [CGPoint] = []
    @State private var 笔 = 26.0
    @State private var 跑着 = false
    @State private var 提示 = "在要擦的地方涂一下"
    @AppStorage("电脑修复.地址") private var 电脑地址 = 电脑修复.缺省地址
    @State private var 用电脑 = false        // false = 本机平滑填补，true = 传到电脑跑 LaMa
    @State private var 改地址 = false

    var body: some View {
        ZStack {
            图来色.编底.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { 关闭() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    }
                    Spacer()
                    Text(提示).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button { Task { await 存() } } label: {
                        Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold))
                            .foregroundStyle(图来色.编底)
                            .frame(width: 34, height: 34).background(Circle().fill(图来色.绿))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)

                GeometryReader { geo in
                    ZStack {
                        Color.black
                        if let 图 {
                            let 框 = 适框(图.size, geo.size)
                            Image(uiImage: 图).resizable()
                                .frame(width: 框.width, height: 框.height)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            Canvas { 上, _ in
                                guard 点们.count > 1 else { return }
                                var 路 = Path()
                                for (i, p) in 点们.enumerated() {
                                    let x = 框.minX + p.x * 框.width
                                    let y = 框.minY + p.y * 框.height
                                    if i == 0 { 路.move(to: CGPoint(x: x, y: y)) } else { 路.addLine(to: CGPoint(x: x, y: y)) }
                                }
                                上.stroke(路, with: .color(图来色.绿.opacity(0.55)),
                                         style: StrokeStyle(lineWidth: 笔, lineCap: .round, lineJoin: .round))
                            }
                            .allowsHitTesting(false)
                            Color.white.opacity(0.001).contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0).onChanged { v in
                                        let p = CGPoint(
                                            x: max(0, min(1, (v.location.x - 框.minX) / 框.width)),
                                            y: max(0, min(1, (v.location.y - 框.minY) / 框.height)))
                                        if 点们.isEmpty || 差(点们.last!, p) > 0.004 { 点们.append(p) }
                                    })
                        } else {
                            ProgressView().tint(图来色.绿)
                        }
                        if 跑着 { ProgressView().tint(图来色.绿) }
                    }
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Picker("引擎", selection: $用电脑) {
                            Text("本机").tag(false)
                            Text("电脑修").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 148)
                        Button { 改地址 = true } label: {
                            Image(systemName: "wifi.router").font(.system(size: 13, weight: .semibold))
                                .frame(width: 40, height: 30)
                                .background(Color.white.opacity(0.12)).foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Spacer()
                        Text(用电脑 ? 电脑修复.规范(电脑地址) : "手机本机算")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                    HStack(spacing: 10) {
                        Text("笔粗").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                        Slider(value: $笔, in: 6...80).tint(图来色.绿)
                    }
                    HStack(spacing: 10) {
                        Button {
                            Task { await 擦() }
                        } label: {
                            Text(用电脑 ? "电脑修" : "开始擦除").font(.system(size: 15, weight: .bold))
                                .frame(maxWidth: .infinity).frame(height: 50)
                                .background(图来色.绿).foregroundStyle(图来色.字)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Button {
                            Task { await 右下角擦() }
                        } label: {
                            Text("右下角").font(.system(size: 13, weight: .semibold))
                                .frame(width: 76, height: 50)
                                .background(Color.white.opacity(0.12)).foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Button { 点们.removeAll() } label: {
                            Text("重涂").font(.system(size: 13, weight: .semibold))
                                .frame(width: 60, height: 50)
                                .background(Color.white.opacity(0.12)).foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .task {
            guard 原CG == nil else { return }
            if let u = await 资产.取图(边长: 2000) {
                图 = u
                原CG = u.cgImage
            }
        }
        .alert("电脑地址", isPresented: $改地址) {
            TextField("192.168.1.12:8770", text: $电脑地址)
                .keyboardType(.URL)
            Button("存") { 电脑地址 = 电脑修复.规范(电脑地址) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("手机和电脑连同一个 Wi-Fi，电脑上先双击 start.bat；端口默认 8770")
        }
        .onChange(of: 用电脑) { 开 in
            guard 开 else { return }
            Task {
                let 在 = await 电脑修复.在不在(电脑地址)
                提示 = 在 ? "电脑在线，涂完点「电脑修」" : "电脑没回应，看看 start.bat 和 Wi-Fi"
            }
        }
    }

    private func 适框(_ 尺寸: CGSize, _ 区: CGSize) -> CGRect {
        guard 尺寸.width > 0, 尺寸.height > 0 else { return CGRect(origin: .zero, size: 区) }
        let 比 = min((区.width - 12) / 尺寸.width, (区.height - 12) / 尺寸.height)
        let w = 尺寸.width * 比, h = 尺寸.height * 比
        return CGRect(x: (区.width - w) / 2, y: (区.height - h) / 2, width: w, height: h)
    }

    private func 差(_ a: CGPoint, _ b: CGPoint) -> Double {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }

    private func 擦() async {
        guard let cg = 原CG else { 提示 = "图还没读好"; return }
        guard !点们.isEmpty else { 提示 = "先涂一下"; return }
        if 用电脑 {
            guard let 掩 = 电脑修复.笔迹掩码(宽: cg.width, 高: cg.height, 点们: 点们, 笔: 笔) else {
                提示 = "蒙版没画出来"; return
            }
            await 走电脑(cg, 掩)
        } else {
            await 走本机(cg, 点们, 笔)
        }
    }

    /// 一键圈住右下角（电脑版同口径 34% × 14%），按当前引擎走
    private func 右下角擦() async {
        guard let cg = 原CG else { 提示 = "图还没读好"; return }
        let w = cg.width, h = cg.height
        if 用电脑 {
            guard let 掩 = 电脑修复.右下角掩码(宽: w, 高: h) else { 提示 = "选区失败"; return }
            await 走电脑(cg, 掩)
        } else {
            var 掩 = [Bool](repeating: false, count: w * h)
            let x0 = Int(Double(w) * 0.66), y0 = Int(Double(h) * 0.86)
            guard x0 < w, y0 < h else { 提示 = "选区失败"; return }
            for y in y0..<h {
                for x in x0..<w { 掩[y * w + x] = true }
            }
            await 走本机掩(cg, 掩)
        }
    }

    private func 走电脑(_ cg: CGImage, _ 掩: CGImage) async {
        跑着 = true
        提示 = "传给电脑，等它算…"
        do {
            let 出 = try await 电脑修复.修(cg, 掩: 掩, 地址: 电脑地址)
            原CG = 出
            图 = UIImage(cgImage: 出)
            点们.removeAll()
            提示 = "电脑修好了，还能再涂"
        } catch {
            提示 = (error as? LocalizedError)?.errorDescription ?? "电脑那边没成"
        }
        跑着 = false
    }

    private func 走本机(_ cg: CGImage, _ 点: [CGPoint], _ 粗: Double) async {
        let w = cg.width, h = cg.height
        var 掩 = [Bool](repeating: false, count: w * h)
        let 半径 = max(3, Int(Double(min(w, h)) * 粗 / 900))
        for p in 点 {
            let cx = Int(p.x * Double(w)), cy = Int(p.y * Double(h))
            for y in max(0, cy - 半径)...min(h - 1, cy + 半径) {
                for x in max(0, cx - 半径)...min(w - 1, cx + 半径) {
                    let dx = x - cx, dy = y - cy
                    if dx * dx + dy * dy <= 半径 * 半径 { 掩[y * w + x] = true }
                }
            }
        }
        await 走本机掩(cg, 掩)
    }

    private func 走本机掩(_ cg: CGImage, _ 掩: [Bool]) async {
        跑着 = true
        let 出 = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            修图.平滑填补(cg, 掩)
        }.value
        if let 出 {
            原CG = 出
            图 = UIImage(cgImage: 出)
            点们.removeAll()
            提示 = "擦好了，可以再涂一次"
        } else {
            提示 = "擦除失败"
        }
        跑着 = false
    }

    private func 存() async {
        guard let cg = 原CG else { return }
        guard let 数据 = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95) else { return }
        let 权 = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard 权 == .authorized || 权 == .limited else { 提示 = "没相册权限"; return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let 请求 = PHAssetCreationRequest.forAsset()
                let 选项 = PHAssetResourceCreationOptions()
                选项.uniformTypeIdentifier = "public.jpeg"
                请求.addResource(with: .photo, data: 数据, options: 选项)
            }
            提示 = "已存进相册"
        } catch { 提示 = "存失败" }
    }
}

/// 精简版根视图
struct 根视图2: View {
    @StateObject private var 相 = 相册模型()
    @StateObject private var 批 = 批量引擎()

    @State private var 风格 = 出图风格.读()
    @Environment(\.scenePhase) private var 场景
    @State private var 显示相册 = false
    @State private var 显示多选 = false
    @State private var 待开批 = false
    @State private var 多选 = true
    @State private var 显示批量 = false
    @State private var 显示消除 = false
    @State private var 显示去水印 = false
    @State private var 批项: [来源] = []
    @State private var 消除资产: PHAsset?

    var body: some View {
        首页2(开相册: 开相册, 相: 相, 批: 批, 开我的: {}, 开去水印: { 显示去水印 = true })
            .task { if !相.已授权 && !相.被拒 { await 相.开始() } }
            .fullScreenCover(isPresented: $显示去水印) {
                去水印页 { 显示去水印 = false }
            }
            .fullScreenCover(isPresented: $显示多选) {
                多选图 { 结果们 in
                    显示多选 = false
                    guard !结果们.isEmpty else { return }
                    批项 = 结果们.map { 来源.结果($0) }
                    批.清空()
                    批.项们 = 批项
                    待开批 = true          // 等选择器真正关掉再开批量
                }
            }
            .onChange(of: 显示多选) { 开 in
                if !开 && 待开批 {
                    待开批 = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { 显示批量 = true }
                }
            }
            .onChange(of: 显示相册) { 开 in
                if !开 && 待开批 {
                    待开批 = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { 显示批量 = true }
                }
            }
            .onChange(of: 风格) { 新 in 新.存() }
            .onChange(of: 场景) { 新 in
                if 新 == .active { Task { await 相.读取(.全部) } }
            }
            .fullScreenCover(isPresented: $显示相册) {
                相册2(相: 相, 多选: 多选) { 选 in
                    显示相册 = false
                    guard !选.isEmpty else { return }
                    if 风格.规格名 == "消除" {
                        消除资产 = 选.first
                        显示消除 = true
                    } else {
                        批项 = 选.map { 来源.资产($0) }
                        批.清空()
                        批.项们 = 批项
                        待开批 = true
                    }
                } 取消: { 显示相册 = false }
            }
            .fullScreenCover(isPresented: $显示批量) {
                批量视图(批: 批, 风格: $风格, 项们: 批项) {
                    显示批量 = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { 显示相册 = true }
                }
            }
            .fullScreenCover(isPresented: $显示消除) {
                if let 资产 = 消除资产 {
                    消除页(资产: 资产) { 显示消除 = false }
                }
            }
    }

    private func 开相册(_ 多: Bool, _ 规格: String) {
        多选 = 多
        风格.规格名 = (规格 == "消除") ? "消除" : 规格
        显示相册 = true             // 一律用自己的相册页（有「选择」+ 连选 + 自动滚）
    }
}