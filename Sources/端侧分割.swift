import CoreML
import CoreVideo
import UIKit

/// 端侧精确抠像：把 8770 服务上那个 isnetis（`animeseg.onnx`）搬到手机里。
///
/// 为什么做（2026-11-16）：好看的关键是「模型」，不是「架构」。
/// 现在唯一的精确抠像在**电脑**上（`/api/segment`），人一出门/换个 Wi-Fi 就退化成
/// Vision 显著性热力图，边缘一圈蓝边。把同一个模型转成 Core ML 放进 App，
/// 离线也能贴到发丝，而且不会因为电脑没开就变糊。
///
/// 口径必须和电脑侧**逐位对齐**（否则端侧和电脑出的遮罩不一样）：
///     原图 → resize 1024×1024（不保比例，LANCZOS 同款）→ RGB/255 - 0.5
/// 归一化交给 Core ML 的 ImageType 做（scale=1/255，bias=-0.5），
/// 所以这里只负责把图摆成 1024×1024 的 RGB 像素缓冲。
///
/// 模型来源：`Tools/animeseg.onnx.part*` → `Tools/convert_segment.py`（Codemagic convert-seg
/// 工作流，macOS 上转）→ `Models/Seg.mlmodelc`（fp16，约 84MB）。
enum 端侧分割 {
    /// 模型固定输入边长（与 8770 服务的 /api/segment 一致）
    static let 边 = 1024

    private static var 模型: MLModel?
    private static let 锁 = NSLock()

    /// 模型有没有打进包里（构建时没放模型就自动退回电脑 / Vision，不会崩）
    static var 可用: Bool {
        Bundle.main.url(forResource: "Seg", withExtension: "mlmodelc") != nil
    }

    /// 提前把模型加载好（首次加载 1~2 秒，别让用户等在图里）
    static func 预热() {
        _ = 模型或空()
    }

    private static func 模型或空() -> MLModel? {
        锁.lock()
        defer { 锁.unlock() }
        if let 模型 { return 模型 }
        guard let 址 = Bundle.main.url(forResource: "Seg", withExtension: "mlmodelc") else { return nil }
        let 配置 = MLModelConfiguration()
        配置.computeUnits = .all          // 能上神经引擎就上
        guard let m = try? MLModel(contentsOf: 址, configuration: 配置) else { return nil }
        模型 = m
        return m
    }

    /// 跑一次，返回**和入图同尺寸**的灰度遮罩（白 255 = 前景），失败返回 nil。
    /// 同步阻塞，调用方放后台线程。
    static func 跑(_ cg: CGImage) -> CGImage? {
        guard let m = 模型或空() else { return nil }
        let 宽 = cg.width, 高 = cg.height
        guard 宽 > 0, 高 > 0 else { return nil }

        // ① **补边**成正方形再缩到 1024，不要拉伸。
        //    2026-11-16 实测（电脑端 7 张竖图）：直接压成 1024² 时有 3 张掩码为空
        //    （max 0.33、>0.5 占 0%），同一张图改成补边后只剩 1 张失败。
        //    原因：竖图压扁会把人物横向拉宽 1.5~2 倍，isnetis 直接认不出。
        let 方边 = max(宽, 高)
        let 比 = Float(边) / Float(方边)
        let 绘宽 = max(1, Int((Float(宽) * 比).rounded()))
        let 绘高 = max(1, Int((Float(高) * 比).rounded()))
        let 左 = (边 - 绘宽) / 2
        let 上 = (边 - 绘高) / 2
        guard let 方 = 画补边(cg, 绘宽: 绘宽, 绘高: 绘高, 左: 左, 上: 上) else { return nil }
        // ② 装进 CVPixelBuffer（Core ML ImageType 只吃缓冲区，不吃 CGImage）
        guard let 缓 = 像素缓冲(方) else { return nil }
        // ③ 预测
        guard let 供 = try? MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: 缓)]),
              let 果 = try? m.prediction(from: 供),
              let 掩 = 果.featureValue(for: "mask")?.multiArrayValue,
              掩.count >= 边 * 边 else { return nil }

        // ④ 概率 → 0~255（和电脑侧 clip(0,1)*255 一致）
        //
        // ⚠️ 这个模型的输出是 **Float16** 的 MultiArray（mlprogram + fp16 存储，
        //    见 Seg.mlmodelc/metadata.json：MultiArray (Float16 1×1×1024×1024)）。
        //    只按 Float32 读会读出垃圾值，所以三种宽度都接。
        let 数 = 边 * 边
        var 字节 = [UInt8](repeating: 0, count: 数)
        switch 掩.dataType {
        case .float32:
            掩.dataPointer.withMemoryRebound(to: Float32.self, capacity: 数) { p in
                for i in 0..<数 { 字节[i] = 量化(p[i]) }
            }
        case .float16:
            掩.dataPointer.withMemoryRebound(to: Float16.self, capacity: 数) { p in
                for i in 0..<数 { 字节[i] = 量化(Float(p[i])) }
            }
        case .double:
            掩.dataPointer.withMemoryRebound(to: Double.self, capacity: 数) { p in
                for i in 0..<数 { 字节[i] = 量化(Float(p[i])) }
            }
        default:
            return nil
        }
        guard let 方灰 = 灰度图(字节, 宽: 边, 高: 边) else { return nil }
        // ② 把掩码从「补边后的 1024²」裁回原图区域（补边是居中的，所以左右/上下对称）
        guard let 灰 = 方灰.cropping(to: CGRect(x: 左, y: 上, width: 绘宽, height: 绘高)) else { return nil }
        if 绘宽 == 宽 && 绘高 == 高 { return 灰 }
        return 缩灰度(灰, 宽: 宽, 高: 高)
    }

    /// 0~1 概率 → 0~255（和电脑侧 np.clip(0,1)*255 一致）
    private static func 量化(_ v: Float) -> UInt8 {
        if v <= 0 { return 0 }
        if v >= 1 { return 255 }
        return UInt8(v * 255 + 0.5)
    }

    // MARK: - 像素搬运

    /// CGImage → 1024² 画布（居中、四周黑边），**不拉伸**
    private static func 画补边(_ 图: CGImage, 绘宽: Int, 绘高: Int, 左: Int, 上: Int) -> CGImage? {
        guard let 布 = CGContext(data: nil, width: 边, height: 边, bitsPerComponent: 8,
                                bytesPerRow: 边 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        布.setFillColor(CGColor(gray: 0, alpha: 1))
        布.fill(CGRect(x: 0, y: 0, width: 边, height: 边))
        布.interpolationQuality = .high
        布.draw(图, in: CGRect(x: 左, y: 上, width: 绘宽, height: 绘高))
        return 布.makeImage()
    }

    /// CGImage → 指定尺寸的 RGB 图（自己分配内存，不碰局部数组指针）
    private static func 画(_ 图: CGImage, 宽: Int, 高: Int) -> CGImage? {
        guard let 布 = CGContext(data: nil, width: 宽, height: 高, bitsPerComponent: 8,
                                bytesPerRow: 宽 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        布.interpolationQuality = .high
        布.draw(图, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
        return 布.makeImage()
    }

    /// CGImage → 32BGRA 的 CVPixelBuffer（Core ML 的标准入口）
    private static func 像素缓冲(_ 图: CGImage) -> CVPixelBuffer? {
        let 宽 = 图.width, 高 = 图.height
        var 出: CVPixelBuffer?
        let 属性: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let 状态 = CVPixelBufferCreate(kCFAllocatorDefault, 宽, 高,
                                     kCVPixelFormatType_32BGRA, 属性 as CFDictionary, &出)
        guard 状态 == kCVReturnSuccess, let 缓 = 出 else { return nil }
        CVPixelBufferLockBaseAddress(缓, [])
        defer { CVPixelBufferUnlockBaseAddress(缓, []) }
        guard let 基 = CVPixelBufferGetBaseAddress(缓) else { return nil }
        guard let 布 = CGContext(data: 基, width: 宽, height: 高, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(缓),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        布.draw(图, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
        return 缓
    }

    /// 单通道字节 → 灰度 CGImage（用 CGDataProvider(CFData)，别交局部指针）
    private static func 灰度图(_ 值: [UInt8], 宽: Int, 高: Int) -> CGImage? {
        guard 宽 > 0, 高 > 0, 值.count >= 宽 * 高 else { return nil }
        guard let 供 = CGDataProvider(data: Data(值) as CFData) else { return nil }
        return CGImage(width: 宽, height: 高, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: 供,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 灰度图缩放（遮罩从 1024 回到原图尺寸）
    private static func 缩灰度(_ 图: CGImage, 宽: Int, 高: Int) -> CGImage? {
        guard let 布 = CGContext(data: nil, width: 宽, height: 高, bitsPerComponent: 8,
                                bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        布.interpolationQuality = .high
        布.draw(图, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
        return 布.makeImage()
    }
}
