import Foundation
import CoreML
import CoreGraphics

/// 端侧显著性（u2netp）：回答「该抠谁」。
///
/// 为什么加这一层（2026-11-21 实测）：
///   端侧分割（isnetis）与 端侧抠图MODNet 都是「分割」模型，回答"这块是不是前景"；
///   日落/逆光这类图里天空面积大、对比强，它们会选天空。服务端 24 张目检：
///   显著性优先 17/24（71%），原「分割优先」14/24（58%），修好 3 个"抠天空"的错、0 回归。
///
/// 与 端侧分割 的关系：两个都留。
///   - u2netp（本文件，约 2~3MB）决定"抠谁"，覆盖不合理时自动跳过；
///   - 端侧分割（84MB，动漫专用）在下一步兜底；
///   - 边缘由 推脸.软遮罩() 精修（已有）。
///
/// 模型规格（Tools/convert_u2netp.py 产出）：
///   输入  input: MultiArray Float32 1x3x320x320（**已归一化**，((x/255)-mean)/std）
///   输出  mask : MultiArray 1x1x320x320（未归一化，需 (d-min)/(max-min)）
///   注意：归一化在 Swift 里做 —— CoreML ImageType 只支持"标量 scale + 逐通道 bias"，
///         表达不出逐通道 scale，硬塞会把颜色搞错。
enum 端侧显著性 {

    private static var 模型: MLModel?

    /// 模型是否随包（false ⇒ 调用方跳过本步，行为与改动前一致）
    static var 可用: Bool {
        Bundle.main.url(forResource: "u2netp", withExtension: "mlmodelc") != nil
    }

    static func 预热() {
        _ = 模型或空()
    }

    private static func 模型或空() -> MLModel? {
        if let m = 模型 { return m }
        guard let 址 = Bundle.main.url(forResource: "u2netp", withExtension: "mlmodelc") else { return nil }
        let 配置 = MLModelConfiguration()
        配置.computeUnits = .all
        guard let m = try? MLModel(contentsOf: 址, configuration: 配置) else { return nil }
        模型 = m
        return m
    }

    /// 与 端侧分割.跑 同签名：入图 → 同尺寸灰度 CGImage（白=前景）。同步阻塞。
    static func 跑(_ cg: CGImage) -> CGImage? {
        guard let m = 模型或空() else { return nil }
        let 宽 = cg.width, 高 = cg.height
        guard 宽 > 0, 高 > 0 else { return nil }

        // ① 缩到 320x320（直接拉伸，不补边：u2netp 是这么训的）
        let 边 = 320
        var rgb = [UInt8](repeating: 0, count: 边 * 边 * 3)
        let 画好: Bool = rgb.withUnsafeMutableBytes { 原 in
            guard let 布 = CGContext(data: 原.baseAddress, width: 边, height: 边,
                                    bitsPerComponent: 8, bytesPerRow: 边 * 3,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            布.interpolationQuality = .high
            布.draw(cg, in: CGRect(x: 0, y: 0, width: 边, height: 边))
            return true
        }
        guard 画好 else { return nil }

        // ② 归一化：(x/255 - mean) / std，按 RGB 平铺到 CHW
        let 均: [Float] = [0.485, 0.456, 0.406]
        let 差: [Float] = [0.229, 0.224, 0.225]
        guard let 入 = try? MLMultiArray(shape: [1, 3, 边 as NSNumber, 边 as NSNumber],
                                         dataType: .float32) else { return nil }
        let 指针 = 入.dataPointer.bindMemory(to: Float.self, capacity: 3 * 边 * 边)
        for c in 0..<3 {
            let 基 = c * 边 * 边
            for i in 0..<(边 * 边) {
                指针[基 + i] = (Float(rgb[i * 3 + c]) / 255 - 均[c]) / 差[c]
            }
        }

        // ③ 推理
        guard let 输入 = try? MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: 入)]),
              let 出 = try? m.prediction(from: 输入),
              let 特征 = 出.featureValue(for: "mask")?.multiArrayValue else { return nil }
        guard 特征.dataType == .float32 else { return nil }   // 转出来若是 fp16，这里要改读 .float16

        // ④ min-max 归一化（u2netp 的 d0 不是 sigmoid 输出）
        let 数 = 边 * 边
        guard 特征.count >= 数 else { return nil }
        let 值 = 特征.dataPointer.bindMemory(to: Float.self, capacity: 数)
        var 小 = Float.greatestFiniteMagnitude, 大 = -Float.greatestFiniteMagnitude
        for i in 0..<数 { let v = 值[i]; if v < 小 { 小 = v }; if v > 大 { 大 = v } }
        let 跨 = max(大 - 小, 1e-6)

        // ⑤ 放回原尺寸
        var 八 = [UInt8](repeating: 0, count: 数)
        for i in 0..<数 {
            let v = (值[i] - 小) / 跨
            八[i] = UInt8(max(0, min(255, v * 255)))
        }
        guard let 小图 = 灰度图(八, 宽: 边, 高: 边) else { return nil }
        return 缩灰度(小图, 宽: 宽, 高: 高)
    }

    // MARK: - 工具（与 端侧分割.swift 同写法：不要交局部指针）

    private static func 灰度图(_ 值: [UInt8], 宽: Int, 高: Int) -> CGImage? {
        guard 宽 > 0, 高 > 0, 值.count >= 宽 * 高 else { return nil }
        guard let 供 = CGDataProvider(data: Data(值) as CFData) else { return nil }
        return CGImage(width: 宽, height: 高, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: 供,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func 缩灰度(_ 图: CGImage, 宽: Int, 高: Int) -> CGImage? {
        guard let 布 = CGContext(data: nil, width: 宽, height: 高, bitsPerComponent: 8,
                                bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        布.interpolationQuality = .high
        布.draw(图, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
        return 布.makeImage()
    }
}
