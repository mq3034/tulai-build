import Foundation
import Vision
import CoreImage
import CoreGraphics

/// 端侧「可点的东西」——一个候选 = 一张掩膜 + 一点描述。
///
/// 为什么要有这个：抠图页要让用户「点哪个抠哪个」，
/// 所以必须先把画面拆成**若干个独立候选**，而不是一张大掩膜。
struct 抠图候选 {
    let 掩膜: CGImage      // 与输入同尺寸的灰度图，白=前景
    let 面积比: Float      // 占画面比例，用来排序/过滤
    let 中心: CGPoint      // 归一化坐标（0~1），界面画高亮用
    let 来源: String       // "系统实例" / "我们的连通块"
}

/// iOS 17 系统「前景实例掩膜」：把画面拆成若干**独立的东西**。
///
/// 2026-11-21 真机实测（三张双人测试图）：
///   · 两人正面并排、大小正常  → 两个都能分别抠出来 ✅
///   · 一人被门挡住            → 只抠出前面那个 ⚠️
///   · 两人背影、人物小、低对比 → 一个都抠不出来 ❌
/// ⇒ 可用但不稳定，必须和「我们自己的连通块候选」互补（见 端侧候选.swift）。
///
/// 注意：allInstances 是**所有实例的并集**，直接用会"把所有人抠成一坨"。
///       要逐个实例调 generateMaskedImage(ofInstances:) 才是"一个东西一张图"。
enum 端侧主体 {

    static var 可用: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    /// 逐个实例返回候选（不稳定时返回空数组，调用方应再试我们的连通块）
    static func 候选(_ cg: CGImage) -> [抠图候选] {
        guard #available(iOS 17.0, *) else { return [] }
        let 宽 = cg.width, 高 = cg.height
        guard 宽 > 0, 高 > 0 else { return [] }

        let 处 = VNImageRequestHandler(cgImage: cg, options: [:])
        let 请 = VNGenerateForegroundInstanceMaskRequest()
        do { try 处.perform([请]) } catch { return [] }
        guard let 果 = 请.results?.first, !果.allInstances.isEmpty else { return [] }

        let 上 = CIContext(options: [.useSoftwareRenderer: false])
        var 出: [抠图候选] = []
        for 号 in 果.allInstances {
            let 集 = IndexSet(integer: 号)
            guard let 缓 = try? 果.generateMaskedImage(ofInstances: 集, from: 处,
                                                      croppedToInstancesExtent: false) else { continue }
            let ci = CIImage(cvPixelBuffer: 缓)
            guard let 图 = 上.createCGImage(ci, from: ci.extent) else { continue }
            guard let 灰 = 取Alpha(图, 宽: 宽, 高: 高) else { continue }
            if let 描 = 描述(灰) { 出.append(抠图候选(掩膜: 灰, 面积比: 描.0, 中心: 描.1, 来源: "系统实例")) }
        }
        return 出
    }

    /// 全部实例的并集（旧接口，保留兼容：推脸那条链还在用）
    static func 掩膜(_ cg: CGImage) -> CGImage? {
        let 们 = 候选(cg)
        guard !们.isEmpty else { return nil }
        if 们.count == 1 { return 们[0].掩膜 }
        // 多个时合并成一张（推脸只需要"人大概在哪"）
        let 宽 = cg.width, 高 = cg.height, 数 = 宽 * 高
        var 合 = [UInt8](repeating: 0, count: 数)
        for c in 们 {
            var 单 = [UInt8](repeating: 0, count: 数)
            guard let 布 = CGContext(data: &单, width: 宽, height: 高, bitsPerComponent: 8,
                                    bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            布.draw(c.掩膜, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
            for i in 0..<数 where 单[i] > 合[i] { 合[i] = 单[i] }
        }
        return 灰度图(合, 宽: 宽, 高: 高)
    }

    // MARK: - 工具

    /// 掩膜的面积比 与 质心（归一化）
    static func 描述(_ 图: CGImage) -> (Float, CGPoint)? {
        let 宽 = 图.width, 高 = 图.height, 数 = 宽 * 高
        guard 数 > 0 else { return nil }
        var 缓 = [UInt8](repeating: 0, count: 数)
        guard let 布 = CGContext(data: &缓, width: 宽, height: 高, bitsPerComponent: 8,
                                bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        布.draw(图, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
        var 计 = 0, 加x = 0, 加y = 0
        for y in 0..<高 {
            let 基 = y * 宽
            for x in 0..<宽 where 缓[基 + x] > 128 {
                计 += 1; 加x += x; 加y += y
            }
        }
        guard 计 > 0 else { return nil }
        let 比 = Float(计) / Float(数)
        let 心 = CGPoint(x: Double(加x) / Double(计) / Double(宽),
                         y: Double(加y) / Double(计) / Double(高))
        return (比, 心)
    }

    private static func 取Alpha(_ 图: CGImage, 宽: Int, 高: Int) -> CGImage? {
        let 数 = 宽 * 高
        var rgba = [UInt8](repeating: 0, count: 数 * 4)
        let 画好: Bool = rgba.withUnsafeMutableBytes { 原 in
            guard let 布 = CGContext(data: 原.baseAddress, width: 宽, height: 高,
                                    bitsPerComponent: 8, bytesPerRow: 宽 * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            布.draw(图, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
            return true
        }
        guard 画好 else { return nil }
        var 灰 = [UInt8](repeating: 0, count: 数)
        for i in 0..<数 { 灰[i] = rgba[i * 4 + 3] }
        return 灰度图(灰, 宽: 宽, 高: 高)
    }

    static func 灰度图(_ 值: [UInt8], 宽: Int, 高: Int) -> CGImage? {
        guard 宽 > 0, 高 > 0, 值.count >= 宽 * 高 else { return nil }
        guard let 供 = CGDataProvider(data: Data(值) as CFData) else { return nil }
        return CGImage(width: 宽, height: 高, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: 供,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
