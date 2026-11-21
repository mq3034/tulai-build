import Foundation
import CoreImage
import CoreGraphics

/// 轻修观感：只调对比 / 饱和 / 锐度，**不改分辨率、不改画风结构**。
///
/// 为什么单独一支：
///   商用级「画质修复」的观感里，有一大块不是分辨率，而是调色——人脸修复后
///   皮肤会偏平（GFPGAN 倾向平滑），不补一点对比和锐度，成品会显得"发闷、像蜡像"。
///   这一步不产生新细节，只把已有细节推到正常观看的距离能被看见。
///
/// 边界：
///   - 只做轻微调整（对比 1.03、饱和 1.04、锐化半径 1.2 强度 0.35），
///     目标是"看不出被修过"，而不是"一眼变鲜艳"
///   - 失败一律返回 nil，调用方退回原图，绝不因为调色失败让整个保存失败
///   - 不改变尺寸与色彩空间，避免下游编码/HEIF 转换出问题
enum 调色 {
    /// 复用一个 CIContext：每次新建都要重新编译内核，批量处理时会明显拖慢。
    private static let 场 = CIContext(options: [CIContextOption.useSoftwareRenderer: false])

    /// 轻微观感提升。
    /// - Parameter cg: 待处理图（一般是 AI 放大/修脸之后的结果）
    /// - Returns: 处理后的图；任何一步失败返回 nil
    static func 轻修(_ cg: CGImage) -> CGImage? {
        let 入 = CIImage(cgImage: cg)
        var 图 = 入

        // ① 对比 + 饱和：把被平均掉的层次拉回来一点
        if let 输出 = CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: 图,
            kCIInputSaturationKey: 1.04,
            kCIInputContrastKey: 1.03,
            kCIInputBrightnessKey: 0.0,
        ])?.outputImage {
            图 = 输出
        }

        // ② 轻度锐化：半径小、强度低，只找回一点边缘，不制造白边
        if let 输出 = CIFilter(name: "CIUnsharpMask", parameters: [
            kCIInputImageKey: 图,
            kCIInputRadiusKey: 1.2,
            kCIInputIntensityKey: 0.35,
        ])?.outputImage {
            图 = 输出
        }

        // ③ 用原图 extent 渲染，避免滤镜链把边界撑大
        return 场.createCGImage(图, from: 入.extent)
    }
}
