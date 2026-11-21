import Foundation
import CoreML
import UIKit
import CoreGraphics

/// Real-ESRGAN（anime 6B）4 倍超分：Core ML 分块推理。
/// 模型 RealESRGAN.mlmodelc 由 Codemagic 的 convert-model 流程生成后放进包里；
/// 没放进来时 有模型() 返回 false，界面自动退回 Lanczos 放大。
enum 超分 {
    static let 块 = 256           // 模型输入边长
    static let 重叠 = 32          // 相邻块重叠的源像素（块边被 padding 污染的区域丢掉）
    static let 缩放 = 4           // 模型固定 4 倍

    private static var 缓存: MLModel?
    private static var 找过 = false

    static func 有模型() -> Bool { 模型() != nil }

    static func 模型() -> MLModel? {
        if let 缓存 { return 缓存 }
        if 找过 { return nil }
        找过 = true
        guard let 址 = Bundle.main.url(forResource: "RealESRGAN", withExtension: "mlmodelc") ??
                       Bundle.main.url(forResource: "RealESRGAN", withExtension: "mlpackage") else { return nil }
        let 配 = MLModelConfiguration()
        配.computeUnits = .all
        缓存 = try? MLModel(contentsOf: 址, configuration: 配)
        return 缓存
    }

    /// 4 倍放大一张图（同步，调用方放到后台线程）
    static func 跑(_ cg: CGImage, 进度: ((Double) -> Void)? = nil) -> CGImage? {
        guard let 型 = 模型() else { return nil }
        let 宽 = cg.width, 高 = cg.height
        guard 宽 > 0, 高 > 0 else { return nil }
        let 大宽 = 宽 * 缩放, 大高 = 高 * 缩放
        guard let 布 = CGContext(data: nil, width: 大宽, height: 大高, bitsPerComponent: 8,
                                bytesPerRow: 大宽 * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        布.interpolationQuality = .high
        布.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        布.fill(CGRect(x: 0, y: 0, width: 大宽, height: 大高))

        let 步 = 块 - 重叠
        let 列 = 起点们(长: 宽, 步: 步)
        let 行 = 起点们(长: 高, 步: 步)
        var 做 = 0
        let 总 = max(列.count * 行.count, 1)

        for y0 in 行 {
            for x0 in 列 {
                做 += 1
                defer { 进度?(Double(做) / Double(总)) }
                guard let 入 = 切块(cg, x0: x0, y0: y0),
                      let 出 = 推一块(入, 型: 型) else { continue }
                let 左丢 = x0 > 0 ? 重叠 / 2 : 0
                let 上丢 = y0 > 0 ? 重叠 / 2 : 0
                let 右丢 = (x0 + 块 < 宽) ? 重叠 / 2 : 0
                let 下丢 = (y0 + 块 < 高) ? 重叠 / 2 : 0
                // 图比块还小时，右边/下边只能取到图边界
                let 取宽 = min(块 - 左丢 - 右丢, 宽 - x0 - 左丢)
                let 取高 = min(块 - 上丢 - 下丢, 高 - y0 - 上丢)
                guard 取宽 > 0, 取高 > 0 else { continue }
                let 裁 = CGRect(x: 左丢 * 缩放, y: 上丢 * 缩放,
                               width: 取宽 * 缩放, height: 取高 * 缩放)
                guard let 片 = 出.cropping(to: 裁) else { continue }
                // CG 坐标原点在左下，这里把「从上往下数」的行号翻过来
                let 落 = CGRect(x: (x0 + 左丢) * 缩放,
                               y: 大高 - (y0 + 上丢 + 取高) * 缩放,
                               width: 取宽 * 缩放, height: 取高 * 缩放)
                布.draw(片, in: 落)
            }
        }
        return 布.makeImage()
    }

    /// 块的起点：均匀铺满（第一块贴左上、最后一块贴右下），块与块之间至少重叠 重叠 像素
    private static func 起点们(长: Int, 步: Int) -> [Int] {
        guard 长 > 块 else { return [0] }
        let 跨度 = Double(长 - 块)
        let 段数 = max(1, Int((跨度 / Double(步)).rounded(.up)))
        let 份数 = 段数 + 1
        return (0..<份数).map { i in
            Int((Double(i) * 跨度 / Double(份数 - 1)).rounded())
        }
    }

    /// 从原图切一块 块×块（越界部分由贴边块保证不会出现）
    private static func 切块(_ cg: CGImage, x0: Int, y0: Int) -> CGImage? {
        guard let 布 = CGContext(data: nil, width: 块, height: 块, bitsPerComponent: 8, bytesPerRow: 块 * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        布.interpolationQuality = .high
        布.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        布.fill(CGRect(x: 0, y: 0, width: 块, height: 块))
        // 图片左上角对齐块左上角：块顶 = 块，图顶 = 块 - y0 → 向下平移 y0
        布.draw(cg, in: CGRect(x: -x0, y: y0 - (cg.height - 块),
                             width: cg.width, height: cg.height))
        return 布.makeImage()
    }

    private static func 推一块(_ 入: CGImage, 型: MLModel) -> CGImage? {
        guard let 入缓 = 像素缓冲(块) else { return nil }
        guard 画进图(入, 缓: 入缓, 宽: 块, 高: 块) else { return nil }
        guard let 输入 = try? MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: 入缓)]) else { return nil }
        guard let 果 = try? 型.prediction(from: 输入),
              let 值 = 果.featureValue(for: "out") else { return nil }
        if let 缓 = 值.imageBufferValue {
            return 出图(缓)
        }
        if let 阵 = 值.multiArrayValue, let 缓 = 像素缓冲(块 * 缩放) {
            guard 写到数组(阵, 缓: 缓, 宽: 块 * 缩放, 高: 块 * 缩放) else { return nil }
            return 出图(缓)
        }
        return nil
    }

    private static func 像素缓冲(_ 边: Int) -> CVPixelBuffer? {
        var 缓: CVPixelBuffer?
        let 属: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let 码 = CVPixelBufferCreate(kCFAllocatorDefault, 边, 边, kCVPixelFormatType_32BGRA,
                                   属 as CFDictionary, &缓)
        return 码 == kCVReturnSuccess ? 缓 : nil
    }

    private static func 位图(_ 缓: CVPixelBuffer) -> CGContext? {
        CVPixelBufferLockBaseAddress(缓, [])
        guard let 底 = CVPixelBufferGetBaseAddress(缓) else {
            CVPixelBufferUnlockBaseAddress(缓, [])
            return nil
        }
        return CGContext(data: 底, width: CVPixelBufferGetWidth(缓), height: CVPixelBufferGetHeight(缓),
                         bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(缓),
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func 画进图(_ 图: CGImage, 缓: CVPixelBuffer, 宽: Int, 高: Int) -> Bool {
        guard let 布 = 位图(缓) else { return false }
        布.interpolationQuality = .high
        布.draw(图, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
        CVPixelBufferUnlockBaseAddress(缓, [])
        return true
    }

    private static func 出图(_ 缓: CVPixelBuffer) -> CGImage? {
        guard let 布 = 位图(缓) else { return nil }
        let 图 = 布.makeImage()
        CVPixelBufferUnlockBaseAddress(缓, [])
        return 图
    }

    /// 多数组输出（1,3,H,W，值 0~255）→ 像素缓冲
    private static func 写到数组(_ 阵: MLMultiArray, 缓: CVPixelBuffer, 宽: Int, 高: Int) -> Bool {
        let 形 = 阵.shape.map { $0.intValue }
        guard 形.count == 4, 形[0] == 1 else { return false }
        let 通道前 = 形[1] == 3
        let 通道后 = 形[3] == 3
        guard 通道前 || 通道后 else { return false }
        guard 阵.count == 3 * 宽 * 高 else { return false }
        let 指 = 阵.dataPointer
        CVPixelBufferLockBaseAddress(缓, [])
        guard let 底 = CVPixelBufferGetBaseAddress(缓) else {
            CVPixelBufferUnlockBaseAddress(缓, [])
            return false
        }
        let 行字节 = CVPixelBufferGetBytesPerRow(缓)
        for y in 0..<高 {
            let 行 = 底.advanced(by: y * 行字节).assumingMemoryBound(to: UInt8.self)
            for x in 0..<宽 {
                for c in 0..<3 {
                    let 序 = 通道前 ? ((c * 高 + y) * 宽 + x) : (((y * 宽 + x) * 3) + c)
                    let v: Float
                    switch 阵.dataType {
                    case .float32:
                        v = 指.advanced(by: 序 * 4).assumingMemoryBound(to: Float.self).pointee
                    case .float16:
                        let 半 = 指.advanced(by: 序 * 2).assumingMemoryBound(to: UInt16.self).pointee
                        v = Float(Float16(bitPattern: 半))
                    case .double:
                        v = Float(指.advanced(by: 序 * 8).assumingMemoryBound(to: Double.self).pointee)
                    default:
                        CVPixelBufferUnlockBaseAddress(缓, [])
                        return false
                    }
                    let o = x * 4 + (2 - c)   // BGRA：c=0(R)→+2, c=1(G)→+1, c=2(B)→+0
                    行[o] = 夹(v)
                }
                行[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(缓, [])
        return true
    }

    private static func 夹(_ v: Float) -> UInt8 {
        if v.isNaN { return 0 }
        return UInt8(max(0, min(255, v.rounded())))
    }

    // MARK: - 人脸增强（v108 新增，只加不改）
    //
    // 逻辑全在 `人脸.swift`；这里只转个手，菜单那边不用去认识两个类型。
    // 用的是同一个 RealESRGAN 打底（`跑` 里面会调），再叠 GFPGAN。

    /// 包里有没有 GFPGAN.mlmodelc（没有就退回普通「AI 4×」）
    static func 有人脸增强() -> Bool { 人脸增强.有人脸模型() }

    /// 「AI 4×（人脸）」：4 倍底图 + 逐张人脸修复。
    /// 同步执行，调用方放到后台线程。进度 0~1。
    static func 跑人脸(_ cg: CGImage, 进度: ((Double) -> Void)? = nil) -> CGImage? {
        人脸增强.跑(cg, 修超分: true, 进度: 进度)
    }
}
