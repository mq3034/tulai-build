import SwiftUI
import UIKit
import CoreGraphics

/// 抠图页：进来先算候选，用户点哪个抠哪个，点 ✅ 出结果。
///
/// 为什么要有这一页（2026-11-21）：原来首页的「智能抠图」格子走的是批量修图流程，
/// 用户点了以后进不了抠图；而白底 800 只能出固定尺寸白底。这条主线一直缺一块。
///
/// 候选来自两路（见 端侧候选.swift）：系统前景实例 + 我们模型的连通块。
/// 真机实测显示两者互补：系统实例在「两人正面」能分开、在「背影小人物」全废；
/// 我们的连通块正好相反。
struct 抠图页: View {
    let 原图: UIImage
    var 完成: (CGImage?) -> Void
    var 取消: () -> Void

    @State private var 工作图: UIImage?
    @State private var 候选们: [抠图候选] = []
    @State private var 着色们: [Int: UIImage] = [:]
    @State private var 选中: Set<Int> = []
    @State private var 忙 = true
    @State private var 提示 = "正在识别画面里的东西…"
    @State private var 结果图: UIImage?      // 抠出来的透明图（有值就切到结果视图）
    @State private var 合成掩膜: CGImage?    // 等着回传给调用方

    private let 工作长边: CGFloat = 1200

    var body: some View {
        Group {
            if let 成品 = 结果图 {
                结果视图(成品)
            } else {
                编辑视图
            }
        }
    }

    private func 结果视图(_ 成品: UIImage) -> some View {
        VStack(spacing: 12) {
            Text("抠好了").font(.headline)
            ZStack {
                Color(white: 0.92)
                Image(uiImage: 棋盘图(成品.size)).resizable().scaledToFit()
                Image(uiImage: 成品).resizable().scaledToFit()
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 12) {
                Button("重选") { 结果图 = nil }
                    .buttonStyle(.bordered)
                Button("保存到相册") {
                    UIImageWriteToSavedPhotosAlbum(成品, nil, nil, nil)
                    提示 = "已保存（若没看到，请检查相册权限）"
                }
                .buttonStyle(.borderedProminent)
                Button("完成") { 完成(合成掩膜) }
                    .buttonStyle(.bordered)
            }
            .padding(.bottom, 20)
        }
    }

    private var 编辑视图: some View {
        VStack(spacing: 0) {
            HStack {
                钮("取消") { 取消() }
                Spacer()
                Text("抠图").font(.headline)
                Spacer()
                钮(忙 ? "…" : "完成", 禁用: 忙 || 选中.isEmpty) { 收尾() }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            ZStack {
                Color.black.opacity(0.02)
                if let 图 = 工作图 {
                    GeometryReader { 几何 in
                        let 框 = 适配框(图.size, 在: 几何.size)
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: 图).resizable().scaledToFit()
                            ForEach(Array(候选们.enumerated()), id: \.offset) { 序, _ in
                                if let 色 = 着色们[序] {
                                    Image(uiImage: 色)
                                        .resizable().scaledToFit()
                                        .opacity(选中.contains(序) ? 1.0 : 0.5)
                                }
                            }
                        }
                        .frame(width: 几何.size.width, height: 几何.size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { 值 in
                            let 宽 = max(框.width, 1), 高 = max(框.height, 1)
                            let x = (值.location.x - 框.minX) / 宽
                            let y = (值.location.y - 框.minY) / 高
                            guard x >= 0, x <= 1, y >= 0, y <= 1 else { return }
                            点选(CGPoint(x: x, y: y))
                        })
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 6) {
                Text(提示).font(.footnote).foregroundStyle(.secondary)
                if !候选们.isEmpty {
                    Text("已选 \(选中.count) 个 · 点图上任意一个东西来选中/取消")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 12)
        }
        .task { await 准备() }
    }

    // MARK: - 准备

    private func 准备() async {
        await MainActor.run { 忙 = true; 提示 = "正在识别画面里的东西…" }
        let 原 = 原图
        let 长边 = 工作长边
        let 结果: (UIImage?, [抠图候选]) = await Task.detached(priority: .userInitiated) {
            guard let 缩 = 等比缩图(原, 到长边: 长边), let cg = 缩.cgImage else { return (nil, []) }
            let 粗 = 端侧抠图MODNet.优先遮罩(cg)?.遮罩           // 我们自己的模型（可能为 nil）
            var 粗图: CGImage? = nil
            if let 浮 = 粗 { 粗图 = 浮转灰度(浮, 宽: cg.width, 高: cg.height) }
            let 们 = 端侧候选.全部(cg, 粗掩膜: 粗图)
            return (缩, 们)
        }.value

        var 色表: [Int: UIImage] = [:]
        let 色们: [UIColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal]
        for (i, c) in 结果.1.enumerated() {
            if let 图 = 着色图(c.掩膜, 色: 色们[i % 色们.count]) { 色表[i] = 图 }
        }

        await MainActor.run {
            工作图 = 结果.0
            候选们 = 结果.1
            着色们 = 色表
            忙 = false
            if 结果.1.isEmpty {
                提示 = "这张图没识别出可抠的东西，试试别张，或用画笔手刷"
            } else {
                提示 = "找到 \(结果.1.count) 个可抠的东西（已默认选中最大的那个）"
                if let 首 = 结果.1.first, let 最大 = 结果.1.firstIndex(of: 首) { 选中 = [最大] }
            }
        }
    }

    // MARK: - 交互

    private func 点选(_ 点: CGPoint) {
        // 从后往前找（面积小的在后，优先选小的，避免点小东西时被大块吞掉）
        for i in stride(from: 候选们.count - 1, through: 0, by: -1) {
            if 端侧候选.命中(候选们[i], 归一化点: 点) {
                if 选中.contains(i) { 选中.remove(i) } else { 选中.insert(i) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }
        }
    }

    private func 收尾() {
        guard let 图 = 工作图, let cg = 图.cgImage else { 完成(nil); return }
        let 选 = 选中.sorted().compactMap { $0 < 候选们.count ? 候选们[$0] : nil }
        guard let 合 = 端侧候选.合成(选, 宽: cg.width, 高: cg.height) else { 完成(nil); return }
        // 工作尺寸的掩膜 ↔ 原图尺寸：这里直接按工作图输出（后续若要原分辨率，放大掩膜即可）
        合成掩膜 = 合
        if let 成品 = 抠透明图(图, 掩膜: 合) { 结果图 = 成品 }
    }

    // MARK: - 小工具

    private func 钮(_ 文: String, 禁用: Bool = false, 做: @escaping () -> Void) -> some View {
        Button(做) {
            Text(文).font(.body.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(禁用 ? Color.gray.opacity(0.15) : Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
        }
        .disabled(禁用)
    }

    private func 适配框(_ 尺寸: CGSize, 在 可用: CGSize) -> CGRect {
        guard 尺寸.width > 0, 尺寸.height > 0 else { return .zero }
        let 比 = min(可用.width / 尺寸.width, 可用.height / 尺寸.height)
        let 宽 = 尺寸.width * 比, 高 = 尺寸.height * 比
        return CGRect(x: (可用.width - 宽) / 2, y: (可用.height - 高) / 2, width: 宽, height: 高)
    }
}

// MARK: - 文件级小工具（与视图解耦，便于复用）

/// 等比缩到指定长边
func 等比缩图(_ 图: UIImage, 到长边: CGFloat) -> UIImage? {
    let w = 图.size.width, h = 图.size.height
    guard w > 0, h > 0 else { return nil }
    let 比 = min(1, 长边 / max(w, h))
    if 比 >= 1 { return 图 }
    let 新 = CGSize(width: w * 比, height: h * 比)
    let 格 = UIGraphicsImageRendererFormat.default(); 格.scale = 1
    return UIGraphicsImageRenderer(size: 新, format: 格).image { _ in
        图.draw(in: CGRect(origin: .zero, size: 新))
    }
}

/// 0~1 浮点 alpha → 同尺寸灰度 CGImage
func 浮转灰度(_ 浮: [Float], 宽: Int, 高: Int) -> CGImage? {
    let 数 = 宽 * 高
    guard 浮.count >= 数, 宽 > 0, 高 > 0 else { return nil }
    var 八 = [UInt8](repeating: 0, count: 数)
    for i in 0..<数 { 八[i] = UInt8(max(0, min(255, 浮[i] * 255))) }
    return 端侧主体.灰度图(八, 宽: 宽, 高: 高)
}

/// 灰度掩膜 → 半透明着色图（界面高亮用）
func 着色图(_ 掩膜: CGImage, 色: UIColor) -> UIImage? {
    let 宽 = 掩膜.width, 高 = 掩膜.height, 数 = 宽 * 高
    guard 数 > 0 else { return nil }
    var 值 = [UInt8](repeating: 0, count: 数)
    guard let 布 = CGContext(data: &值, width: 宽, height: 高, bitsPerComponent: 8,
                            bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    布.draw(掩膜, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    色.getRed(&r, green: &g, blue: &b, alpha: &a)
    var rgba = [UInt8](repeating: 0, count: 数 * 4)
    for i in 0..<数 {
        rgba[i * 4 + 0] = UInt8(r * 255)
        rgba[i * 4 + 1] = UInt8(g * 255)
        rgba[i * 4 + 2] = UInt8(b * 255)
        rgba[i * 4 + 3] = UInt8(Double(值[i]) * 0.55)
    }
    return rgba.withUnsafeMutableBytes { 原 -> UIImage? in
        guard let 布2 = CGContext(data: 原.baseAddress, width: 宽, height: 高,
                                 bitsPerComponent: 8, bytesPerRow: 宽 * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = 布2.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 原图 + 掩膜 → 带 alpha 的 UIImage（透明背景）
func 抠透明图(_ 图: UIImage, 掩膜: CGImage) -> UIImage? {
    guard let cg = 图.cgImage else { return nil }
    let 宽 = cg.width, 高 = cg.height, 数 = 宽 * 高
    // 取原图 RGBA
    var 原 = [UInt8](repeating: 0, count: 数 * 4)
    guard let 布1 = CGContext(data: &原, width: 宽, height: 高, bitsPerComponent: 8,
                             bytesPerRow: 宽 * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    布1.draw(cg, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
    // 取掩膜灰度（与图同尺寸；不同尺寸时先缩）
    var 灰 = [UInt8](repeating: 0, count: 数)
    guard let 布2 = CGContext(data: &灰, width: 宽, height: 高, bitsPerComponent: 8,
                             bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                             bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    布2.draw(掩膜, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
    for i in 0..<数 {
        原[i * 4 + 3] = UInt8(Double(原[i * 4 + 3]) * Double(灰[i]) / 255.0)
    }
    return 原.withUnsafeMutableBytes { 址 -> UIImage? in
        guard let 布3 = CGContext(data: 址.baseAddress, width: 宽, height: 高, bitsPerComponent: 8,
                                 bytesPerRow: 宽 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let 出 = 布3.makeImage() else { return nil }
        return UIImage(cgImage: 出)
    }
}

/// 棋盘格底图（看透明区域用）
func 棋盘图(_ 尺寸: CGSize) -> UIImage {
    let 格: CGFloat = 10
    let 渲染 = UIGraphicsImageRenderer(size: 尺寸)
    return 渲染.image { 上下文 in
        let c = 上下文.cgContext
        c.setFillColor(UIColor(white: 0.86, alpha: 1).cgColor)
        c.fill(CGRect(origin: .zero, size: 尺寸))
        c.setFillColor(UIColor(white: 0.72, alpha: 1).cgColor)
        var y: CGFloat = 0
        var 行 = 0
        while y < 尺寸.height {
            var x: CGFloat = (行 % 2 == 0) ? 0 : 格
            while x < 尺寸.width {
                c.fill(CGRect(x: x, y: y, width: 格, height: 格))
                x += 格 * 2
            }
            y += 格; 行 += 1
        }
    }
}
