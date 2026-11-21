import Foundation
import Vision
import CoreGraphics
import CoreImage
import UIKit

/// 「AI 4×（人脸）」：先用 Vision 找出人脸，把每张脸对齐成 512×512，
/// 喂给 GFPGAN 修（模型进 512、出 512，它本身不放大），再放回放大后的底图对应位置。
///
/// 为什么单独一支：RealESRGAN 那支（`超分.swift`）做的是「整图放大」，它不知道
/// 哪块是人脸，对真人的眼睛、牙齿这种高频细节基本无能为力；GFPGAN 是在 FFHQ 人脸
/// 上训的，所以脸必须按 FFHQ 模板摆正、固定 512 边长送进去，效果才和训练时一样。
///
/// 关键顺序（2026-11-14 按官方实现核对过）：
///   ① 整图先 4 倍（RealESRGAN 或 Lanczos）
///   ② **从 4 倍底图上**裁出脸那一块（尺寸 = 原图脸框 × 4）
///   ③ 缩到 512 送 GFPGAN（它只接受 512）
///   ④ 出来的 512 放大回 ② 那么大，羽化后贴回
/// 这样脸的细节是按 4 倍尺寸重建的；如果反过来从原图裁再放大到 4 倍，脸会糊。
enum 人脸增强 {
    static let 模板边 = 512          // GFPGAN 输入边长（FFHQ 对齐模板）
    static let 出边 = 512            // GFPGAN 输出边长（和输入一样，它不做放大）
    /// 输出总像素上限（按物理内存自适应）。
    ///
    /// 商用场景的输入是**相机照**，不是抖音那种 1023~1440 宽的小图：
    /// 一张 12 MP 照片（4032×3024）：
    ///   - 2× → 48.8 MP（约 195 MB RGB 缓冲），现代机型可以吃下
    ///   - 4× → 192 MP（约 768 MB），必崩
    /// 所以 42 MP 的旧上限会把 12 MP 照片判成「不放大」（倍率兜底 1），
    /// 客户点了一键增强却看到尺寸没变 —— 最伤客诉的失败方式。
    ///
    /// 这里按物理内存分档：≥4 GB 放宽到 50 MP（12 MP 可得 2×），
    /// 小内存机型保持 42 MP 保守值。
    static let 上限像素: Double = {
        let 字节 = Double(ProcessInfo.processInfo.physicalMemory)
        let gb = 字节 / 1_073_741_824.0
        return gb >= 4.0 ? 50_000_000.0 : 42_000_000.0
    }()
    /// 脸太小就别修了：512 的模板缩到这么小一张脸上，修出来的细节还不如原样
    static let 最小脸边 = 40.0
    /// 贴回时多带的一圈上下文（像素，按原图尺度）；GFPGAN 会重绘边界，
    /// 不留余量的话脸和旁边头发/背景的接缝会露出来
    static let 素材 = 8

    private static var 人脸模型缓存: MLModel?
    private static var 找过 = false

    static func 有人脸模型() -> Bool { 人脸模型() != nil }

    static func 人脸模型() -> MLModel? {
        if let 人脸模型缓存 { return 人脸模型缓存 }
        if 找过 { return nil }
        找过 = true
        guard let 址 = Bundle.main.url(forResource: "GFPGAN", withExtension: "mlmodelc") ??
                       Bundle.main.url(forResource: "GFPGAN", withExtension: "mlpackage") else { return nil }
        let 配 = MLModelConfiguration()
        配.computeUnits = .all
        人脸模型缓存 = try? MLModel(contentsOf: 址, configuration: 配)
        return 人脸模型缓存
    }

    // MARK: - 主链

    /// 入口：底图 4 倍 → 找人脸 → 逐张修 → 贴回。
    /// 全程同步，调用方放到后台线程。
    static func 跑(_ cg: CGImage,
                  修超分: Bool = true,
                  进度: ((Double) -> Void)? = nil) -> CGImage? {
        let 宽 = cg.width, 高 = cg.height
        guard 宽 > 0, 高 > 0 else { return nil }

        // ① 底图：有 RealESRGAN 就走它，没模型退回 Lanczos（和菜单里那档一致）。
        //    倍率先算好：4 倍会把总像素撑爆的长图（1440×12000 会变成 6900 万像素）
        //    自动降到 3 或 2，跟「放大 N×」那档用同一个上限。
        let 倍率 = 定倍率(宽: 宽, 高: 高)
        var 底: CGImage?
        if 修超分, 倍率 == 4, 超分.有模型() {
            底 = 超分.跑(cg, 进度: nil)
        }
        if 底 == nil {
            底 = 修图.放大(cg, 倍: CGFloat(倍率))
        }
        guard let 底图 = 底 else { return nil }
        let 倍 = Double(底图.width) / Double(宽)

        // ② 找人脸：原图上找，再把框乘 倍 换算到放大图坐标
        let 脸们 = 找人脸(cg)
        guard let 型 = 人脸模型(), !脸们.isEmpty else { return 底图 }

        // ②.5 只对"真脸"启用 GFPGAN。
        //   2026-11-15 用户反馈：动漫/插画的脸上会出现一条白糊——GFPGAN 是按真人先验训的，
        //   喂进去动漫脸它会"脑补"出一张真人脸，结果是糊掉。判据用 Vision 的关键点：
        //   真脸能稳定出 76 个点，动漫脸常常只有框、点极少甚至没有。
        guard 像真脸(cg) else {
            诊断.记("超清：判定不是真人脸，跳过 GFPGAN（只做超分）")
            return 底图
        }

        进度?(0.05)
        guard let 布 = 新画布(宽: 底图.width, 高: 底图.height) else { return 底图 }
        布.interpolationQuality = .high
        布.draw(底图, in: CGRect(x: 0, y: 0, width: 底图.width, height: 底图.height))

        // ③ 逐张修 + 贴回
        for (i, 脸) in 脸们.enumerated() {
            defer { 进度?(0.05 + 0.95 * Double(i + 1) / Double(脸们.count)) }
            let 原框 = 扩框(脸, 宽: 宽, 高: 高)
            // 底图坐标（左上原点）：原图框 × 倍
            let 大框 = CGRect(x: 原框.origin.x * 倍, y: 原框.origin.y * 倍,
                              width: 原框.width * 倍, height: 原框.height * 倍)
            // 从**底图**裁（不是原图）：保证脸的细节是按 4 倍尺寸重建的
            guard let 入 = 切对齐(底图, 框: 大框) else { continue }
            guard let 修好 = 推一块(入, 型: 型) else { continue }
            guard let 片 = 修好.cropping(to: CGRect(x: 0, y: 0, width: 出边, height: 出边)) else { continue }

            // ②.6 逐脸体检：修完的脸如果和原块差太多，说明模型在瞎编，直接不用这一块。
            //   这是"宁可不修，也不能糊脸"的兜底。
            let 差 = 块差异(入, 片)
            if 差 > 58 {
                诊断.记("超清：第 \(i+1) 张脸修得离谱（差异 \(Int(差))），已跳过")
                continue
            }
            guard let 羽 = 羽化(片, 宽: Int(大框.width.rounded()), 高: Int(大框.height.rounded())) else { continue }
            // 左上原点 → CG 左下原点
            let 落 = CGRect(x: 大框.origin.x,
                            y: Double(底图.height) - 大框.origin.y - 大框.height,
                            width: 大框.width, height: 大框.height)
            布.draw(羽, in: 落)
        }

        // ④ 边界保护：脸被画到图外时 CGContext 会裁掉，但框右/下越界会让
        //    部分块取不到图，这里不生成新图，直接返回底图尺寸的画布
        return 布.makeImage() ?? 底图
    }

    // MARK: - 真脸判定 / 修复质量体检

    /// 供自检调用（内部实现见下）
    static func 像真脸公开(_ cg: CGImage) -> Bool { 像真脸(cg) }

    /// 像不像真人脸：要求 Vision 关键点检出足够多的点。
    /// 动漫/插画常常只有 bbox 没有稳定关键点，用这个把它们挡在 GFPGAN 外面。
    private static func 像真脸(_ cg: CGImage) -> Bool {
        let 请求 = VNDetectFaceLandmarksRequest()
        let 句柄 = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        guard (try? 句柄.perform([请求])) != nil, let 观们 = 请求.results, !观们.isEmpty else { return false }
        // 至少一张脸的轮廓点够多（真人通常 60+）
        for 观 in 观们 {
            guard let 点 = 观.landmarks else { continue }
            let n = (点.faceContour?.pointCount ?? 0) + (点.leftEye?.pointCount ?? 0)
                  + (点.rightEye?.pointCount ?? 0) + (点.nose?.pointCount ?? 0)
            if n >= 24 { return true }
        }
        return false
    }

    /// 两张同尺寸图（512×512）的平均绝对差，抽稀采样，快。
    private static func 块差异(_ a: CGImage, _ b: CGImage) -> Double {
        let n = 64
        var 甲 = [UInt8](repeating: 0, count: n * n * 4)
        var 乙 = [UInt8](repeating: 0, count: n * n * 4)
        func 画(_ 图: CGImage, _ 到: inout [UInt8]) -> Bool {
            到.withUnsafeMutableBytes { raw -> Bool in
                guard let 布 = CGContext(data: raw.baseAddress, width: n, height: n,
                                        bitsPerComponent: 8, bytesPerRow: n * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                布.interpolationQuality = .low
                布.draw(图, in: CGRect(x: 0, y: 0, width: n, height: n))
                return true
            }
        }
        guard 画(a, &甲), 画(b, &乙) else { return 0 }
        var 和 = 0.0
        for i in stride(from: 0, to: n * n * 4, by: 4) {
            for c in 0..<3 { 和 += Double(abs(Int(甲[i+c]) - Int(乙[i+c]))) }
        }
        return 和 / Double(n * n * 3)
    }

    // MARK: - 找人脸

    /// 底图倍率：先试 4，超过 `上限像素` 就往下退到 3、2，最小 1。
    /// 和 `去水印页.存相册图` 里「放大 N×」那档同一套算法。
    private static func 定倍率(宽: Int, 高: Int) -> Int {
        let 源像素 = Double(宽 * 高)
        guard 源像素 > 0 else { return 1 }
        if 源像素 * 16 <= 上限像素 { return 4 }
        if 源像素 * 9 <= 上限像素 { return 3 }
        if 源像素 * 4 <= 上限像素 { return 2 }
        return 1
    }

    /// Vision 的人脸检测。坐标系：Vision 原点在左下、归一化 0~1；
    /// 这里统一换成「左上原点、原图像素」的框，后面换算方便。
    private static func 找人脸(_ cg: CGImage) -> [CGRect] {
        let 请求 = VNDetectFaceRectanglesRequest()
        请求.revision = VNDetectFaceRectanglesRequestRevision3
        let 句柄 = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try 句柄.perform([请求])
        } catch {
            return []
        }
        guard let 观 = 请求.results else { return [] }
        let 宽 = Double(cg.width), 高 = Double(cg.height)
        return 观.compactMap { o -> CGRect? in
            let b = o.boundingBox
            let 框 = CGRect(x: b.origin.x * 宽,
                            y: (1 - b.origin.y - b.height) * 高,
                            width: b.width * 宽,
                            height: b.height * 高)
            // Vision 给的是内脸（眉眼到下巴那圈），外面还有额头、发际线；
            // 外扩到 1.55 倍并整体上移一点，才能把额头和头发带进来
            return 扩框成外层(框, 宽: 宽, 高: 高)
        }
    }

    private static func 扩框成外层(_ 框: CGRect, 宽: Double, 高: Double) -> CGRect? {
        let 边 = max(框.width, 框.height) * 1.55
        guard 边 > 0 else { return nil }
        let 中心x = 框.midX
        let 中心y = 框.midY - 框.height * 0.06       // 人脸中心比内脸框偏上一点
        return 裁进图(CGRect(x: 中心x - 边 / 2, y: 中心y - 边 / 2, width: 边, height: 边), 宽: 宽, 高: 高)
    }

    /// 贴回前再带一圈上下文
    private static func 扩框(_ 框: CGRect, 宽: Int, 高: Int) -> CGRect {
        let 边 = max(框.width, 框.height) + Double(素材) * 2
        let r = CGRect(x: 框.midX - 边 / 2, y: 框.midY - 边 / 2, width: 边, height: 边)
        return 裁进图(r, 宽: Double(宽), 高: Double(高)) ?? 框
    }

    /// 把框裁进图内；脸在边角时框会变小（正方形保持）
    /// 注意：这里不动 `min(宽,高)` 的上限，图本身就比脸小的情况留给 `切对齐` 处理
    private static func 裁进图(_ 框: CGRect, 宽: Double, 高: Double) -> CGRect? {
        let 边 = min(max(框.width, 框.height), min(宽, 高))
        guard 边 >= 最小脸边 else { return nil }
        var x = 框.origin.x
        var y = 框.origin.y
        x = max(0, min(x, 宽 - 边))
        y = max(0, min(y, 高 - 边))
        return CGRect(x: x, y: y, width: 边, height: 边)
    }

    // MARK: - 切块 / 贴回

    /// 从 `源` 裁出框内那一块（框是左上原点的正方形，单位是源图像素），缩放到 512×512。
    /// 只做缩放不做旋转：GFPGAN 的 FFHQ 模板对正脸（左右近似对称）够用。
    private static func 切对齐(_ 源: CGImage, 框: CGRect) -> CGImage? {
        guard 框.width >= 4, 框.height >= 4 else { return nil }
        // 左上原点 → CG 左下原点
        let 裁框 = CGRect(x: 框.origin.x,
                         y: Double(源.height) - 框.origin.y - 框.height,
                         width: 框.width, height: 框.height).integral
        guard let 片 = 源.cropping(to: 裁框) else { return nil }
        guard let 布 = CGContext(data: nil, width: 模板边, height: 模板边, bitsPerComponent: 8,
                                bytesPerRow: 模板边 * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        布.interpolationQuality = .high
        布.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        布.fill(CGRect(x: 0, y: 0, width: 模板边, height: 模板边))
        布.draw(片, in: CGRect(x: 0, y: 0, width: 模板边, height: 模板边))
        return 布.makeImage()
    }

    /// 推一次 512×512：和 `超分.swift` 的 `推一块` 同一条路（像素缓冲进出）
    private static func 推一块(_ 入: CGImage, 型: MLModel) -> CGImage? {
        var 入缓: CVPixelBuffer?
        let 属: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let 码 = CVPixelBufferCreate(kCFAllocatorDefault, 模板边, 模板边, kCVPixelFormatType_32BGRA,
                                   属 as CFDictionary, &入缓)
        guard 码 == kCVReturnSuccess, let 缓 = 入缓 else { return nil }

        CVPixelBufferLockBaseAddress(缓, [])
        if let 底 = CVPixelBufferGetBaseAddress(缓) {
            let 布 = CGContext(data: 底, width: CVPixelBufferGetWidth(缓), height: CVPixelBufferGetHeight(缓),
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(缓),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            布?.interpolationQuality = .high
            布?.draw(入, in: CGRect(x: 0, y: 0, width: 模板边, height: 模板边))
        }
        CVPixelBufferUnlockBaseAddress(缓, [])

        guard let 输入 = try? MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: 缓)]) else { return nil }
        guard let 果 = try? 型.prediction(from: 输入),
              let 值 = 果.featureValue(for: "out") else { return nil }
        guard let 出缓 = 值.imageBufferValue else { return nil }

        CVPixelBufferLockBaseAddress(出缓, [])
        var 图: CGImage?
        if let 底 = CVPixelBufferGetBaseAddress(出缓) {
            let 布 = CGContext(data: 底,
                               width: CVPixelBufferGetWidth(出缓), height: CVPixelBufferGetHeight(出缓),
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(出缓),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            图 = 布?.makeImage()
        }
        CVPixelBufferUnlockBaseAddress(出缓, [])
        return 图
    }

    /// 缩到贴回尺寸并羽化边缘。
    /// 羽化半径按框边长的 6% 走，脸框越大过渡越宽；用 CIFilter 的高斯模糊
    /// 生成一张遮罩再乘回去，比手写逐像素的循环快得多。
    private static func 羽化(_ 片: CGImage, 宽: Int, 高: Int) -> CGImage? {
        guard 宽 > 8, 高 > 8 else { return nil }
        let 场 = CIContext(options: [.useSoftwareRenderer: false])
        var 图 = CIImage(cgImage: 片)
        let 缩 = CIFilter.lanczosScaleTransform()
        缩.inputImage = 图
        缩.scale = Float(宽) / Float(片.width)
        缩.aspectRatio = (Float(高) / Float(宽)) * (Float(片.width) / Float(片.height))
        if let o = 缩.outputImage { 图 = o.cropped(to: CGRect(x: 0, y: 0, width: 宽, height: 高)) }

        let 半径 = Double(min(宽, 高)) * 0.06
        let 内 = CGRect(x: 半径, y: 半径, width: Double(宽) - 半径 * 2, height: Double(高) - 半径 * 2)
        guard let 遮 = CIFilter(name: "CIRoundedRectangleGenerator",
                                parameters: [kCIInputExtentKey: CIVector(cgRect: 内),
                                             "inputRadius": 半径 * 1.6,
                                             "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 1)])?.outputImage else {
            return 图.cropped(to: CGRect(x: 0, y: 0, width: 宽, height: 高)).cgImage(宽: 宽, 高: 高, 场: 场)
        }
        let 模 = 遮.applyingGaussianBlur(sigma: 半径 * 0.9)
        guard let 混 = CIFilter(name: "CIBlendWithMask",
                                parameters: [kCIInputImageKey: 图,
                                             kCIInputBackgroundImageKey: CIImage.empty(),
                                             kCIInputMaskImageKey: 模])?.outputImage else { return nil }
        return 场.createCGImage(混, from: CGRect(x: 0, y: 0, width: 宽, height: 高))
    }

    private static func 新画布(宽: Int, 高: Int) -> CGContext? {
        CGContext(data: nil, width: 宽, height: 高, bitsPerComponent: 8, bytesPerRow: 宽 * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }
}

private extension CIImage {
    func cgImage(宽: Int, 高: Int, 场: CIContext) -> CGImage? {
        场.createCGImage(self, from: CGRect(x: 0, y: 0, width: 宽, height: 高))
    }
}
