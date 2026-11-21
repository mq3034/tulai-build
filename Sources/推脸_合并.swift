import Foundation
import Vision
import CoreGraphics
import UIKit

/// 「推脸」核心：人像分割 + 干净背景补全 + 硬遮罩 + 严格分层合成。
///
/// v2 架构（2026-11-15 按醒图操作录像重做，电脑端参考实现见
/// `I:\拣货\推脸验证\v2\ref.mjs`，三项量化指标已达标）：
///   ① **干净背景**：先把人从底图抹掉并补全（优先电脑 LaMa，回退本机平滑填补），
///      人移开后的原地永远露出"本来就没有人"的背景，不会留残影。
///   ② **硬遮罩**：分割结果 二值化 → 填洞 → 外扩 → 只留 2px 羽化。
///      除这 2px 外遮罩只有 0/1 —— 这是"背景不被拖走"的前提。
///   ③ **严格分层合成**：s = clamp(p - D)，alpha 取【采样位置】的遮罩值；
///      a<=0.02 → 输出干净背景；否则 人层[s]*a + 干净背景[p]*(1-a)。
///      整体拖人时 D 全图恒定；局部推脸时 D 乘遮罩（背景 D=0）。
///   ④ **位移限幅**：单次和累积都设上限，超了不响应。
///   ⑤ **CPU 实现**：不碰 Metal/CIKL 自定义着色器（编译期风险高、不好调试）。
///      编辑分辨率长边 1200，够拖得动。
///
/// 已知取舍：
///   · 编辑分辨率固定 1200 长边，输出也用它（不是原图分辨率）
///   · 干净背景的质量取决于补全：电脑 LaMa 好，本机平滑填补只能算"不露残影"
enum 推脸 {

    /// 编辑与输出的长边（一期统一用这个分辨率，够看清效果、也够快）
    static let 长边 = 1200

    /// 单次拖动允许的最大位移，按「短边 × 该系数」，再乘强度滑杆
    ///
    /// 2026-11-15 真机反馈"推不到一边去"：原来是 0.06，屏幕上几乎看不出移动。
    /// 醒图允许的幅度大得多（能整块拉走），所以放开到 0.15。
    static let 单次位移系数: Float = 0.05
    /// 【拖人】专用的上限（2026-11-16 用户反馈"只能推到固定位置"）
    ///
    /// 醒图的推脸能一路把人推到画面外，我们之前用 0.15/0.30 把位移卡死了
    /// （短边 900 的图最多推 270px，推到头就不动）。
    /// 拖人是**整块平移**，被推走的区域由补好的干净背景填上，所以放大到接近整张画面是安全的：
    ///   · 单次 0.5 —— 一次手势可以推半个短边
    ///   · 累积 0.95 —— 总共能推到画面边缘
    /// 局部推脸（非整体）仍然保持 0.15/0.30：那是形变，推太狠会崩。
    static let 拖人单次系数: Float = 0.50
    static let 拖人累积系数: Float = 0.95

    /// 累积位移上限
    ///
    /// 同样从 0.10 放开到 0.30。代价是拉太狠会出现拉伸糊（像醒图那样），
    /// 但"推不动"比"推过头"更让人以为功能坏了。
    static let 累积位移系数: Float = 0.12
    /// 遮罩向外膨胀的半径（按短边比例）= max(2, 短边 * 0.008)
    ///
    /// 为什么要膨胀：遮罩外严格不动 → 发丝/手臂边缘被判成背景时，
    /// 那块就"卡在原地"，看起来像旁边多了一个不动的人。
    /// 向外扩几像素把这些边缘纳入可动范围，代价是紧贴人像的一圈背景会轻微跟随。
    /// 2026-11-15 v2：0.012 → 0.008。配合「二值化 + 填洞 + 硬边」，
    /// 膨胀只负责盖住分割缺口，不再兼做"柔化过渡"。
    /// 遮罩"内缩"系数（负=往人里面收）。
    ///
    /// 2026-11-16 用户实测反馈"绿幕边缘一圈白边"：原来是**膨胀** 8px，
    /// 把约 7 万个背景像素划进了"可动区"，合成时背景被一起拖走 → 白边。
    /// 改成往内收 2px：边缘紧贴原图线条，不碰背景。
    /// 0 = 不外扩也不内缩，只留 1px 羽化。
    ///
    /// 演进史（都是真机反馈）：
    ///   外扩 8px → 背景被拖走 → 白边
    ///   内缩 2px → 背景吃进人物边缘 → 切边/淡边（217% 放大能看出来）
    ///   0        → 边界就是真实边界，最干净
    static let 遮罩内缩像素 = 0

    /// 遮罩边缘羽化半径（v2 只做一次半径 2 的盒式模糊）。
    ///
    /// 过渡带总宽 ≈ 4px（边界两侧各 2px）。实测软带离二值边界最远 2px，
    /// 软带像素占比 1.16%（< 3%）。背景像素合成时采样到的 alpha 几乎必为 0 ——
    /// 这是「拖人时背景不被整块拖走」的前提，别为了"柔和"再加大它。
    /// 羽化半径：只留 1px（羽化越大越糊边）
    static let 遮罩羽化半径 = 1

    /// 一次编辑会话的全部状态
    final class 会话 {
        let 宽: Int
        let 高: Int
        /// 源像素，RGBA 每像素 4 字节
        let 源: [UInt8]
        /// 人像遮罩，0~1（0 = 背景，必须原样不动；1 = 可动）
        /// 注意是 var：用户手动画的保护/放开会改它
        var 遮罩: [Float]
        /// 分割出来的原始遮罩（手动画之前的样子），"重置/反选"都以它为基准
        let 基准遮罩: [Float]
        /// 手动画的修正量：> 0 表示加保护，< 0 表示放开，0 = 没动过
        var 涂改: [Float]
        /// 「干净背景」：人已经被补全抹掉的底图（RGBA）。
        ///
        /// 为什么必须有这一层：人和背景在同一张图里时，人一移动，原地就露出"原本的人"
        /// （残影）。醒图的做法是把人先抹掉、把背景补全，人层再叠上去 —— 推多远都干净。
        /// 这就是 2026-11-15 看它的操作录像后才确认的架构差异。
        let 背景: [UInt8]
        /// 遮罩快照：渲染在后台线程读，必须给它一份不会被主线程改的副本
        private var 快照缓存: [Float]?
        private var 快照代数 = 0
        private var 遮罩代数 = 0
        /// 位移场（输出像素 → 源像素的偏移）
        var dx: [Float]
        var dy: [Float]
        /// 参考尺度：短边像素，用于换算 σ 和限幅
        let 尺度: Float
        /// 检测到人脸时的人脸宽度（像素），没有则为 0
        let 脸宽: Float
        /// 遮罩来源：端侧-isnetis / 电脑-精确抠像 / vision-person / u2netp-general / 无
        /// （界面用来解释"为什么能推动漫"，以及这次是不是离线跑的）
        let 遮罩来源: String
        /// 抠像本身花了多少毫秒（端侧模型/电脑请求），界面显示出来方便验收
        let 遮罩毫秒: Int

        init(宽: Int, 高: Int, 源: [UInt8], 遮罩: [Float], 尺度: Float, 脸宽: Float,
             遮罩来源: String = "无", 遮罩毫秒: Int = 0, 背景: [UInt8]? = nil) {
            self.宽 = 宽
            self.高 = 高
            self.源 = 源
            self.遮罩 = 遮罩
            self.基准遮罩 = 遮罩
            self.涂改 = [Float](repeating: 0, count: 宽 * 高)
            self.背景 = 背景 ?? 源
            self.遮罩来源 = 遮罩来源
            self.遮罩毫秒 = 遮罩毫秒
            self.dx = [Float](repeating: 0, count: 宽 * 高)
            self.dy = [Float](repeating: 0, count: 宽 * 高)
            self.尺度 = 尺度
            self.脸宽 = 脸宽
        }

        /// 取位移场快照（主线程调用）。
        /// 为什么必须复制：渲染在后台线程跑，手势在主线程改 dx/dy；
        /// Swift 数组被写入时可能重新分配缓冲区，后台持有的裸指针会立刻悬垂 → 崩。
        /// 源像素和遮罩初始化后不再变，所以只需复制这两个。
        func 位移快照() -> ([Float], [Float]) { (dx, dy) }

        /// 遮罩快照（主线程调用）。只有遮罩真的变过才复制，避免每帧拷 5MB。
        func 遮罩快照() -> [Float] {
            if let c = 快照缓存, 快照代数 == 遮罩代数 { return c }
            let c = 遮罩
            快照缓存 = c
            快照代数 = 遮罩代数
            return c
        }

        /// 把「涂改」合并进遮罩。
        ///
        /// v2 的语义（3.1 第 6 步）：**可动 = 1 - 保护值**
        ///   · 加保护（涂改 > 0）：可动 = 基准可动 × (1 - 保护值)
        ///     —— 背景处基准已经是 0，乘多少还是 0，所以涂保护永远不会把背景"涂成能动"。
        ///   · 放开（涂改 < 0）：可动 = 基准 + 放开量 × (1 - 基准)
        ///     —— 把背景拉进可动范围（用户显式要求这块可以动）。
        func 应用涂改() {
            let n = 宽 * 高
            for i in 0..<n {
                let d = 涂改[i]
                let 基 = 基准遮罩[i]
                if d > 0 {
                    遮罩[i] = min(1, max(0, 基 * (1 - min(1, d))))
                } else if d < 0 {
                    遮罩[i] = min(1, max(0, 基 + min(1, -d) * (1 - 基)))
                } else {
                    遮罩[i] = 基
                }
            }
            遮罩代数 += 1
        }

        /// 局部涂一笔（画保护或放开），只改涂改层
        func 涂(_ x: Int, _ y: Int, 半径: Int, 加保护: Bool) {
            let n = 宽 * 高
            guard x >= 0, y >= 0, x < 宽, y < 高 else { return }
            let r2 = 半径 * 半径
            for yy in max(0, y - 半径)...min(高 - 1, y + 半径) {
                let dy = yy - y
                for xx in max(0, x - 半径)...min(宽 - 1, x + 半径) {
                    let dx2 = xx - x
                    if dx2 * dx2 + dy * dy > r2 { continue }
                    let i = yy * 宽 + xx
                    let 目标: Float = 加保护 ? 1 : -1
                    // 笔刷软边：越靠边越轻
                     let 强 = 1 - Float(dx2 * dx2 + dy * dy) / Float(max(1, r2))
                    涂改[i] = min(1, max(-1, 涂改[i] + 目标 * 强 * 0.5))
                }
            }
            _ = n
        }

        func 反选() {
            for i in 涂改.indices { 涂改[i] = 0 }
            for i in 遮罩.indices { 遮罩[i] = 1 - 基准遮罩[i] }
            遮罩代数 += 1
        }

        func 重置遮罩() {
            for i in 涂改.indices { 涂改[i] = 0 }
            遮罩 = 基准遮罩
            遮罩代数 += 1
        }
        func 清空位移() {
            for i in dx.indices { dx[i] = 0; dy[i] = 0 }
        }

        var 有变形: Bool {
            for i in dx.indices where dx[i] != 0 || dy[i] != 0 { return true }
            return false
        }
    }

    // MARK: - 准备

    /// 把用户选的图变成可编辑会话：归正方向 → 缩到长边 1200 → 分割 →
    /// 硬遮罩（二值化+填洞+外扩+2px 羽化）→ 补全干净背景。
    /// 同步执行，调用方放后台线程。
    /// 准备会话。
    /// - Parameter 补全背景: true 时先做一次「把人抹掉 + 补全背景」，
    ///   之后推多远都不会露出残影（醒图的架构）。
    static func 准备(_ 图: UIImage, 补全背景: Bool = true) async -> 会话? {
        guard let 正 = 归正方向(图) else { return nil }
        guard let 缩 = 等比缩(正, 到长边: 长边) else { return nil }
        guard let (宽, 高, 源) = 读像素(缩) else { return nil }

        var 遮罩 = [Float](repeating: 1, count: 宽 * 高)   // 分割失败就整幅可编辑
        var 用遮罩 = false
        var 遮罩来源 = "无"
        var 遮罩毫秒 = 0

        // ⓪ 端侧精确抠像（2026-11-16 晚：把 8770 上那个 isnetis 转成 Core ML 打进包里）
        //    同一个 onnx、同一套归一化（resize 1024 → /255-0.5），所以出的遮罩和电脑**一样**，
        //    但不用连电脑、不受 Wi-Fi 影响。这一步在准备会话时只跑一次，之后拖动都是纯内存。
        if 端侧分割.可用 {
            let t0 = Date()
            if let 本掩 = 端侧分割.跑(缩),
               let (宽2, 高2, 源2) = 读像素(本掩), 宽2 == 宽, 高2 == 高 {
                var 浮 = [Float](repeating: 0, count: 宽 * 高)
                for i in 0..<(宽 * 高) { 浮[i] = Float(源2[i * 4]) / 255.0 }   // R 通道 = 白度
                let 覆盖 = 浮.reduce(Float(0)) { $0 + ($1 > 0.5 ? 1 : 0) } / Float(宽 * 高)
                if 覆盖 > 0.01 {
                    遮罩 = 软遮罩(浮, 引导: 源, 宽: 宽, 高: 高)
                    用遮罩 = true
                    遮罩来源 = "端侧-isnetis"
                    let 毫秒 = Int(Date().timeIntervalSince(t0) * 1000)
                    遮罩毫秒 = 毫秒
                    诊断.记("推脸：遮罩来自端侧模型（离线），覆盖 \(Int(覆盖*100))%，\(毫秒)ms")
                } else {
                    诊断.记("推脸：端侧模型没分到人（覆盖 \(Int(覆盖*100))%），往下走")
                }
            } else {
                诊断.记("推脸：端侧模型调用失败，往下走")
            }
        }

        // ⓪' 端侧没有/失败 → 再问电脑要**精确抠像**（2026-11-16 修"绿幕贴合度"）
        //    Vision 给的是显著性热力图 → 边缘一圈蓝边、发丝贴不住；
        //    电脑上跑动漫专用分割（isnetis，约 1 秒），边缘能贴到发丝。
        //    电脑不在就往下走本地逻辑，不阻塞。
        let t1 = Date()
        if !用遮罩, await 电脑修复.在不在(), let pc掩 = try? await 电脑修复.分割(缩) {
            if let (宽2, 高2, 源2) = 读像素(pc掩), 宽2 == 宽, 高2 == 高 {
                var 浮 = [Float](repeating: 0, count: 宽 * 高)
                for i in 0..<(宽 * 高) { 浮[i] = Float(源2[i * 4]) / 255.0 }   // R 通道 = 白度
                let 覆盖 = 浮.reduce(Float(0)) { $0 + ($1 > 0.5 ? 1 : 0) } / Float(宽 * 高)
                if 覆盖 > 0.01 {
                    遮罩 = 软遮罩(浮, 引导: 源, 宽: 宽, 高: 高)
                    用遮罩 = true
                    遮罩来源 = "电脑-精确抠像"
                    遮罩毫秒 = Int(Date().timeIntervalSince(t1) * 1000)
                    诊断.记("推脸：遮罩来自电脑抠像，覆盖 \(Int(覆盖*100))%")
                }
            }
        }

        // ① 电脑不在/失败 → 本地 Vision 人像分割（免费、快、真人最准）
        if !用遮罩, let m = 分割遮罩(缩) {
            let 放大 = 缩放到(遮罩: m.数据, 从宽: m.宽, 高: m.高, 到宽: 宽, 高: 高)
            let 覆盖 = 放大.reduce(Float(0)) { $0 + ($1 > 0.5 ? 1 : 0) } / Float(宽 * 高)
            if 覆盖 > 0.01 {
                遮罩 = 软遮罩(放大, 引导: 源, 宽: 宽, 高: 高)
                用遮罩 = true
                遮罩来源 = "vision-person"
            }
        }

        // ② Vision 没分到人（动漫/物体/宠物）→ 用通用主体分割（u2netp）
        //    这正是客户拿动漫图时"背景保护失效"的根因；醒图就是靠通用分割覆盖这些场景的。
        if !用遮罩, 通用分割.可用(), let m = 通用分割.跑(缩) {
            let 覆盖 = m.reduce(Float(0)) { $0 + ($1 > 0.5 ? 1 : 0) } / Float(m.count)
            if 覆盖 > 0.01 {
                遮罩 = 软遮罩(m, 引导: 源, 宽: 宽, 高: 高)
                用遮罩 = true
                遮罩来源 = "u2netp-general"
            }
        }

        let 尺度 = Float(min(宽, 高))
        let 脸宽 = 探测脸宽(缩) * Float(宽) / Float(缩.width)
        let 终遮罩 = 用遮罩 ? 遮罩 : [Float](repeating: 1, count: 宽 * 高)

        // 背景补全：把"人"从底图里抹掉，后面的合成才有干净的底。
        var 背景像素: [UInt8] = 源
        if 补全背景, 用遮罩 {
            // 补背景用的掩码要比"合成遮罩"**大一圈**。
            //
            // 2026-11-16 用户实测：抹掉人之后，原位置留了一圈淡淡的轮廓影。
            // 原因是人像边缘那 1~2px 抗锯齿像素没被盖住，LaMa 把它们的线条
            // "顺着延"进洞里 → 看起来像水印。
            // 实测：外扩 9px 有影，外扩 25px（短边 2.4%）干净 —— 统一按 2.2% 取。
            let 补半径 = max(6, Int((Float(min(宽, 高)) * 0.022).rounded()))
            let 补浮 = 最大值滤波(最大值滤波(终遮罩, 宽: 宽, 高: 高, 半径: 补半径, 横向: true),
                                宽: 宽, 高: 高, 半径: 补半径, 横向: false)
            let 是 = 补浮.map { $0 > 0.5 }
            var 补好: CGImage?
            // ① 优先电脑 LaMa（质量最好，你 App 里已有这条通路）
            if await 电脑修复.在不在() {
                诊断.记("推脸：调电脑 LaMa 补背景（掩码外扩 \(补半径)px）")
                if let 掩图 = 造掩图(补浮, 宽: 宽, 高: 高) {
                    补好 = try? await 电脑修复.修(缩, 掩: 掩图)
                }
            }
            // ② 电脑不在或用不了 → 本机平滑填补（离线可用，质量一般但不会露残影）
            if 补好 == nil {
                诊断.记("推脸：本机平滑填补背景")
                补好 = 修图.平滑填补(缩, 是)
            }
            if let 补好, let 三 = 读像素(补好), 三.0 == 宽, 三.1 == 高 {
                背景像素 = 三.2
            }
        }

        return 会话(宽: 宽, 高: 高, 源: 源,
                   遮罩: 终遮罩,
                   尺度: 尺度, 脸宽: 脸宽, 遮罩来源: 遮罩来源,
                   遮罩毫秒: 遮罩毫秒, 背景: 背景像素)
    }

    /// 软遮罩（2026-11-16 晚，对齐醒图的抠图细度）。
    ///
    /// 和 `硬遮罩` 的区别只有一个，但决定成败：**不二值化**。
    /// isnetis 输出本来就是 0~1 的软概率，发丝处是一条 4~8px 的渐变带；
    /// 二值化（>=0.5 → 1）会把它切成硬线，细节当场死掉 —— 这就是"我们的边永远长不出丝"的原因。
    ///
    /// 流程：
    ///   ① 对比度拉伸：0.15~0.85 → 0~1（内部饱和成 1、背景压成 0，中间保留渐变）
    ///   ② 填洞：软图二值化后填洞，洞内直接给 1（躯干中间别被穿孔）
    ///   ③ 引导滤波：以**原图灰度**为引导，半径 4px，把 alpha 对齐到真实边缘（发丝级）
    ///
    /// 为什么用引导滤波而不是羽化：羽化只是糊，糊出来的边和真实边缘无关；
    /// 引导滤波让 alpha 跟随原图的亮度边缘，细发丝、衣褶都能贴住。
    private static func 软遮罩(_ 入: [Float], 引导: [UInt8], 宽: Int, 高: Int) -> [Float] {
        let n = 宽 * 高
        guard n > 0, 入.count == n, 引导.count >= n * 4 else { return 入 }

        // ① 只压低端、不做均匀拉伸：模型给的软边本身就是发丝状的，
        //    均匀拉伸会把它抹成「均匀一圈」——实测过渡带 9px，鬼影就是这一圈。
        var p = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let v = (入[i] - 0.05) / 0.90
            p[i] = min(1, max(0, v))
        }

        // ② 实心核：离边界足够远的内部直接压成 1（内部必须是全实心，否则整块会半透明）
        let 核径 = max(2, Int((Float(min(宽, 高)) * 0.006).rounded()))
        let 实心 = 最小值滤波(最小值滤波(p, 宽: 宽, 高: 高, 半径: 核径, 横向: true),
                           宽: 宽, 高: 高, 半径: 核径, 横向: false)
        for i in 0..<n { if 实心[i] > 0.5 { p[i] = 1 } }

        // ③ 只在带内做引导滤波（带外保持 0/1，不再给背景拉出灰边）
        var 带 = [UInt8](repeating: 0, count: n)
        for i in 0..<n { 带[i] = (p[i] > 0.02 && p[i] < 0.98) ? 1 : 0 }
        带 = 最大值滤波(带.map { Float($0) }, 宽: 宽, 高: 高, 半径: 3, 横向: true)
            .map { UInt8($0 > 0.5 ? 1 : 0) }
        var 灰 = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let o = i * 4
            灰[i] = (0.299 * Float(引导[o]) + 0.587 * Float(引导[o + 1]) + 0.114 * Float(引导[o + 2])) / 255
        }
        let r = max(2, Int((Float(min(宽, 高)) * 0.004).rounded()))
        let eps: Float = 0.0020
        let 均灰 = 盒模糊(灰, 宽: 宽, 高: 高, 半径: r)
        let 均p = 盒模糊(p, 宽: 宽, 高: 高, 半径: r)
        var 灰方 = [Float](repeating: 0, count: n)
        var 灰p = [Float](repeating: 0, count: n)
        for i in 0..<n { 灰方[i] = 灰[i] * 灰[i]; 灰p[i] = 灰[i] * p[i] }
        let 均灰方 = 盒模糊(灰方, 宽: 宽, 高: 高, 半径: r)
        let 均灰p = 盒模糊(灰p, 宽: 宽, 高: 高, 半径: r)
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let 方差 = 均灰方[i] - 均灰[i] * 均灰[i]
            let 协方差 = 均灰p[i] - 均灰[i] * 均p[i]
            a[i] = 协方差 / (方差 + eps)
            b[i] = 均p[i] - a[i] * 均灰[i]
        }
        let 均a = 盒模糊(a, 宽: 宽, 高: 高, 半径: r)
        let 均b = 盒模糊(b, 宽: 宽, 高: 高, 半径: r)

        // ④ 带子压窄 4 倍（以 0.5 为中心）：过渡带从 ~9px → ~2px。
        //    宽度就是鬼影宽度：9px 看着像「描边」，2px 看着像「丝」。
        var 出 = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let 精 = 均a[i] * 灰[i] + 均b[i]
            let v = 带[i] == 1 ? 0.5 + (精 - 0.5) * 4.0 : p[i]
            出[i] = min(1, max(0, v))
        }
        return 出
    }

    /// 硬遮罩处理（v2，对应电脑端参考实现 `I:\拣货\推脸验证\v2\ref.mjs`）。
    ///
    /// 真机问题（2026-11-15）：分割输出是浮点软边，外沿一圈 0.05~0.95 的半透明带
    /// 会让那块背景"既不算人也不算背景"：拖人时被带着走（大斜楔子），
    /// 局部推时又被判成背景卡住不动。所以遮罩必须先变硬。
    ///
    /// 流程（顺序不能换）：
    ///   ① 二值化：>= 0.5 → 1，否则 0
    ///   ② 填洞：被 1 包围的 0 区域填成 1（4 邻域 flood fill + 反向）
    ///   ③ 外扩：dilate 半径 = max(2, 短边 * 0.008)
    ///   ④ 只做 2px 羽化（单次盒式模糊半径 2）
    ///
    /// 电脑端实测：软带占比 1.16%（< 3%），软带离二值边界最远 2px，
    /// 缺口 41/41 被膨胀盖回、内部洞 113/113 被填回。
    /// 注意：**不要**再改回"三次模糊 + 平方收敛"的老做法，那会重新造出宽过渡带。
    private static func 硬遮罩(_ 入: [Float], 宽: Int, 高: Int) -> [Float] {
        let n = 宽 * 高
        guard n > 0, 入.count == n else { return 入 }

        // ① 二值化
        var 二 = [UInt8](repeating: 0, count: n)
        for i in 0..<n { 二[i] = 入[i] >= 0.5 ? 1 : 0 }

        // ② 填洞
        填洞(&二, 宽: 宽, 高: 高)

        // ③ 往内收（腐蚀），不要外扩。
        //    外扩会把背景划进可动区 → 拖动时背景被拽出白边（实测 7 万像素）。
        //    内收 2px 的代价是纯色边缘可能少 1~2px，但拖完看是干净的。
        let 内缩 = max(0, Int(遮罩内缩像素))
        var 浮 = [Float](repeating: 0, count: n)
        for i in 0..<n { 浮[i] = Float(二[i]) }
        var 张 = 浮
        if 内缩 > 0 {
            // 最小值滤波 = 腐蚀（横一遍 + 竖一遍）
            张 = 最小值滤波(最小值滤波(浮, 宽: 宽, 高: 高, 半径: 内缩, 横向: true),
                          宽: 宽, 高: 高, 半径: 内缩, 横向: false)
        }

        // ④ 只做一次 1px 盒式模糊
        var 羽 = 盒模糊(张, 宽: 宽, 高: 高, 半径: 遮罩羽化半径)
        for i in 0..<n { 羽[i] = min(1, max(0, 羽[i])) }
        return 羽
    }

    /// 形态学填洞：把「被 1 完全包围的 0」填成 1。
    ///
    /// 做法：从画面四边对 0 做 4 邻域 flood fill，标出所有**能连到边界**的背景；
    /// 剩下没被标到的 0 就是被主体包住的洞（分割模型经常在躯干/头发中间漏一块）。
    ///
    /// ⚠️ 这里先把 inout 参数拷成局部变量再操作：Swift 的嵌套函数捕获 inout 参数
    ///    有并发/逃逸限制，直接闭包捕获会编译不过（踩过的坑）。
    private static func 填洞(_ 遮: inout [UInt8], 宽: Int, 高: Int) {
        let n = 宽 * 高
        guard n > 0, 遮.count == n else { return }
        var 二 = 遮                       // 局部副本，最后再写回
        var 外 = [UInt8](repeating: 0, count: n)   // 1 = 能从画面边界连到的背景
        var 队 = [Int]()
        队.reserveCapacity(n / 4)

        func 压(_ i: Int) {
            if 二[i] == 0 && 外[i] == 0 { 外[i] = 1; 队.append(i) }
        }
        for x in 0..<宽 { 压(x); 压((高 - 1) * 宽 + x) }
        for y in 0..<高 { 压(y * 宽); 压(y * 宽 + 宽 - 1) }

        var 头 = 0
        while 头 < 队.count {
            let i = 队[头]
            头 += 1
            let x = i % 宽
            let y = i / 宽
            if x > 0 { 压(i - 1) }
            if x < 宽 - 1 { 压(i + 1) }
            if y > 0 { 压(i - 宽) }
            if y < 高 - 1 { 压(i + 宽) }
        }
        for i in 0..<n where 二[i] == 0 && 外[i] == 0 { 二[i] = 1 }
        遮 = 二
    }

    /// 遮罩是不是真的分出了人（用于界面提示）
    static func 有人像(_ s: 会话) -> Bool {
        var 人 = 0
        for v in s.遮罩 where v > 0.5 { 人 += 1 }
        return 人 > s.宽 * s.高 / 100      // 至少 1% 的像素是人
    }

    /// 造一张"白=人"的灰度蒙版（给电脑 LaMa 用）
    ///
    /// ⚠️ 内存安全（之前闪退的根因）：**不能**把局部数组的指针交给 CGContext 再
    ///    `makeImage()` —— CGImage 会引用那块内存，而局部数组函数返回就释放，
    ///    之后一显示就 EXC_BAD_ACCESS。正确做法：让 CGContext 自己分配内存，
    ///    再把像素 memcpy 进去，图像生命周期由 CGImage/上下文自己管。
    static func 造掩图(_ 遮: [Float], 宽: Int, 高: Int) -> CGImage? {
        let n = 宽 * 高
        guard 宽 > 0, 高 > 0, 遮.count == n else { return nil }
        var g = [UInt8](repeating: 0, count: n)
        for i in 0..<n { g[i] = 遮[i] > 0.5 ? 255 : 0 }
        let 空 = CGColorSpaceCreateDeviceGray()
        guard let 布 = CGContext(data: nil, width: 宽, height: 高,
                                bitsPerComponent: 8, bytesPerRow: 宽, space: 空,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let 目标 = 布.data else { return nil }
        g.withUnsafeBytes { raw in
            if let 源 = raw.baseAddress, raw.count >= n { memcpy(目标, 源, n) }
        }
        return 布.makeImage()
    }

    /// 保护区域可视化：绿色 = 被保护、不会动（语义和醒图一致）。
    /// 用户看不到遮罩时，任何"没反应"都无法归因；这个开关把原因摊在屏幕上。
    static func 遮罩图(_ s: 会话, 遮罩 遮参数: [Float]) -> UIImage? {
        var 出 = [UInt8](repeating: 0, count: s.宽 * s.高 * 4)
        s.源.withUnsafeBufferPointer { 源 in
            遮参数.withUnsafeBufferPointer { 遮 in
                出.withUnsafeMutableBufferPointer { 目 in
                    // 语义和醒图对齐：**画出来的是"被保护"的区域（背景），不是主体。**
                    //
                    // 为什么这样更好：分割漏判时，漏掉的一块背景跟着动几乎看不出来；
                    // 而漏掉的一块人物留在原地，会像"旁边多了一个不动的人"，极其刺眼。
                    // 所以让"保护"是显式的、可看见的，"可动"是默认的。
                    for i in 0..<(s.宽 * s.高) {
                        let p = i * 4
                        let 可动 = 遮[i]
                        if 可动 >= 0.5 {
                            // 主体：原色显示（能动）
                            目[p] = 源[p]; 目[p+1] = 源[p+1]; 目[p+2] = 源[p+2]
                        } else {
                            // 背景：绿色蒙层 = 被保护，不会动
                            目[p] = UInt8(Float(源[p]) * 0.30 + 30)
                            目[p+1] = UInt8(min(255, Float(源[p+1]) * 0.55 + 120))
                            目[p+2] = UInt8(Float(源[p+2]) * 0.30 + 20)
                        }
                        目[p+3] = 255
                    }
                }
            }
        }
        return 由像素(出, 宽: s.宽, 高: s.高)
    }

    /// 外向场权重（2026-11-17，对齐醒图「4.0S」）：
    ///   剪影内 = 1（主体刚性、不打折）；剪影外按到剪影的距离线性衰减到 0；
    ///   带宽 = 4 × 本次位移（蓝发实测：W_out=4S 时 ΔD 0.25px、硬台阶 0、无折叠）。
    /// 距离用多源 BFS（8 邻域）近似像素距离；只在「整体拖动 + 背景保护」时调用。
    /// ⚠️ 性能：每次拖动都重算约 O(宽×高)，大图可能 50~100ms；先上真机看手感，
    ///    卡的话把结果缓存到会话里（遮罩变化/换图时失效）。
    static func 外向场权重(遮罩: [Float], 宽: Int, 高: Int, 带宽: Float) -> [Float] {
        let n = 宽 * 高
        var 距 = [Int32](repeating: -1, count: n)
        for i in 0..<n where 遮罩[i] >= 0.5 { 距[i] = 0 }
        var 队 = [Int32]()
        队.reserveCapacity(max(16, n / 8))
        for y in 0..<高 {
            for x in 0..<宽 {
                let i = y * 宽 + x
                if 距[i] == 0 { continue }
                var 邻剪影 = false
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || ny < 0 || nx >= 宽 || ny >= 高 { continue }
                        if 距[ny * 宽 + nx] == 0 { 邻剪影 = true }
                    }
                }
                if 邻剪影 { 距[i] = 1; 队.append(Int32(i)) }
            }
        }
        var 头 = 0
        while 头 < 队.count {
            let i = Int(队[头]); 头 += 1
            let x = i % 宽, y = i / 宽
            let nd = 距[i] + 1
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                let nx = x + dx, ny = y + dy
                if nx < 0 || ny < 0 || nx >= 宽 || ny >= 高 { continue }
                let j = ny * 宽 + nx
                if 距[j] == -1 { 距[j] = nd; 队.append(Int32(j)) }
            }
        }
        var w = [Float](repeating: 0, count: n)
        let 带 = max(1, 带宽)
        for i in 0..<n {
            if 距[i] <= 0 { w[i] = 1 }
            else { w[i] = max(0, 1 - Float(距[i]) / 带) }
        }
        return w
    }

    /// 在图片坐标 (cx, cy) 处施加一次拖动，向量 (vx, vy)。
    /// - Parameters:
    ///   - 半径系数: 由「大小」滑杆控制，0.5~2.0
    ///   - 强度: 0.3~1.0
    ///   - 背景保护: 开启时位移再乘遮罩（遮罩为 0 处位移必为 0）
    static func 施加(_ s: 会话, 中心 cx: Float, _ cy: Float,
                    向量 vx: Float, _ vy: Float,
                    半径系数: Float, 强度: Float, 背景保护: Bool,
                    整体: Bool = false) {
        // σ：以脸宽优先，没有脸就用短边
        // 2026-11-16 晚：σ 从「短边×0.14」降到「×0.06」。
        // 实测（电脑端四组对照 I:\拣货\推脸验证\液化实验）：0.14 的影响半径 3σ≈整张图，
        // 头被拉走时肩膀/腰跟着动 → 人像被纵向剪切；0.06 时只有笔刷附近变形，接近醒图。
        let 基准 = s.脸宽 > 10 ? s.脸宽 * 0.35 : s.尺度 * 0.06
        let σ = max(2, 基准 * 半径系数)

        // 单次限幅（拖人用更大的一档，见 拖人单次系数 的注释）
        let 单限 = s.尺度 * (整体 ? 拖人单次系数 : 单次位移系数) * 强度
        var dxv = vx, dyv = vy
        let 长 = (dxv * dxv + dyv * dyv).squareRoot()
        if 长 > 单限, 长 > 0 {
            let k = 单限 / 长
            dxv *= k; dyv *= k
        }

        let 累限 = s.尺度 * (整体 ? 拖人累积系数 : 累积位移系数)

        // 【整体平移】醒图的「快速推脸」实测是整块移动人，不是局部液化。
        //   为什么必须支持：局部高斯位移一旦大于笔刷半径，原地会留下另一半人，
        //   看起来像"两个她"（2026-11-15 本地复现证实）。
        //   v2：整体平移**不做高斯衰减、不乘遮罩**，只把 D 铺满整张图。
        if 整体 {
            // ⚠️ 位移必须**全图恒定**，不能乘遮罩。
            //   反向映射的含义是"输出像素 p 去 p-D 取色"：
            //     · 只有把 D 铺满整张图，人才能"出现在新位置"；
            //     · 乘了遮罩就只有原位置有 D，人只会从原地消失、不会出现在新处
            //       （2026-11-15 本地复现：整块平移后人不见了/变成两个）。
            //   背景像素因为采样到的 alpha=0，输出仍是干净背景，不会被带动。
            var 总x = s.dx[0] + vx
            var 总y = s.dy[0] + vy
            let 长 = (总x * 总x + 总y * 总y).squareRoot()
            if 长 > 累限, 长 > 0 { let k = 累限 / 长; 总x *= k; 总y *= k }
            // 2026-11-17 v15（对齐醒图 4.0S）：开背景保护时不再全图恒定，
            //   剪影内 W=1（主体刚性），剪影外 W 线性衰减，带宽 = 4×本次位移。
            //   这样背景是"连续大拖 + 无台阶"，而不是整张图一起平移。
            var 权重场: [Float]? = nil
            if 背景保护 {
                let 幅 = (总x * 总x + 总y * 总y).squareRoot()
                权重场 = 外向场权重(遮罩: s.遮罩, 宽: s.宽, 高: s.高,
                                     带宽: max(1, 4 * 幅))
            }
            for i in 0..<(s.宽 * s.高) {
                if let w = 权重场 {
                    s.dx[i] = 总x * w[i]
                    s.dy[i] = 总y * w[i]
                } else {
                    s.dx[i] = 总x
                    s.dy[i] = 总y
                }
            }
            return
        }

        let r = Int((σ * 3).rounded())
        let x0 = max(0, Int(cx) - r), x1 = min(s.宽 - 1, Int(cx) + r)
        let y0 = max(0, Int(cy) - r), y1 = min(s.高 - 1, Int(cy) + r)
        guard x0 <= x1, y0 <= y1 else { return }

        let 分母 = 2 * σ * σ
        for y in y0...y1 {
            let dyy = Float(y) - cy
            for x in x0...x1 {
                let dxx = Float(x) - cx
                let 距2 = dxx * dxx + dyy * dyy
                if 距2 > Float(r * r) { continue }
                let i = y * s.宽 + x
                let w = exp(-距2 / 分母)
                // 2026-11-16 v14：部分位移收窄到 alpha 0.35~0.75。
                //   原来「权重 = w × alpha」会让 9px 软带整条都只走一半 → 旧位置留一圈鬼影；
                //   收窄后 alpha<0.35 完全不动、>0.75 完全跟着走，鬼影从「一圈」变「一条线」。
                let 权重 = 背景保护 ? w * min(1, max(0, (s.遮罩[i] - 0.35) / 0.40)) : w
                if 权重 < 0.001 { continue }

                var nx = s.dx[i] + dxv * 权重
                var ny = s.dy[i] + dyv * 权重
                let 现有 = (nx * nx + ny * ny).squareRoot()
                if 现有 > 累限, 现有 > 0 {
                    let k = 累限 / 现有
                    nx *= k; ny *= k
                }
                s.dx[i] = nx
                s.dy[i] = ny
            }
        }
    }

    // MARK: - 渲染

    /// 按当前位移场渲染一帧（v2 严格分层合成，对应参考实现 `ref.mjs` 的 渲染()）。
    ///
    /// 对每个输出像素 p：
    ///   s = clamp(p - D[p])          // 反向映射：只做画面边界夹取，**不做**「回拉进遮罩」
    ///   a = 遮罩[s]                   // alpha 取【采样位置】的值
    ///   if a <= 0.02:  out = 干净背景[p]      // 采样到背景 → 干净背景原样
    ///   else:          out = 人层[s]*a + 干净背景[p]*(1-a)
    ///
    /// 为什么必须这样（2026-11-15 真机问题的根因）：
    ///   · 「拖人」的 D 是全图恒定的。只要 alpha 从**采样位置**取、且遮罩是硬的（0/1），
    ///     背景像素采样到的 a 必然是 0 → 输出干净背景 → 背景不会被整块拖走（大斜楔子消失）。
    ///   · alpha 若从「输出位置」取、或保留 `w<=0.0005 就早退` 的老写法，背景会被位移场带跑。
    ///   · 人移开的原地：采样到的 a=0 → 输出干净背景（人已被抹掉），不会留残影。
    ///
    /// 背景保护关闭时退回「整图变形」：alpha 恒为 1、底图用原图。
    /// - Parameter 纯形变: true 时**不做遮罩合成**（alpha 恒 1、底图用原图）。
    ///   为什么：醒图的「推脸」是液化——只搬运像素，不再拿遮罩把采样到背景的像素换成补好的背景。
    ///   一旦做合成，大位移时采样点落出人体就会「抽丝/露假背景」（2026-11-16 真机截图 + 电脑端四组对照证实）。
    static func 渲染(_ s: 会话, 遮罩 遮参数: [Float], dx DX参数: [Float], dy DY参数: [Float], 背景保护: Bool, 纯形变: Bool = false) -> UIImage? {
        let 宽 = s.宽, 高 = s.高
        // 防御：位移场长度必须和画面一致，否则下面的裸指针访问会越界（直接崩）
        guard 宽 > 0, 高 > 0,
              DX参数.count == 宽 * 高, DY参数.count == 宽 * 高,
              遮参数.count == 宽 * 高 else { return nil }

        var 出 = [UInt8](repeating: 0, count: 宽 * 高 * 4)
        let 宽末 = Float(宽 - 1)
        let 高末 = Float(高 - 1)
        // 底图：开保护时用「干净背景」（人已抹掉），关保护时退回原图（整图变形）
        let 底 = (背景保护 && !纯形变) ? s.背景 : s.源

        s.源.withUnsafeBufferPointer { 源 in
            底.withUnsafeBufferPointer { 底图 in
                遮参数.withUnsafeBufferPointer { 遮 in
                    DX参数.withUnsafeBufferPointer { DX in
                        DY参数.withUnsafeBufferPointer { DY in
                            出.withUnsafeMutableBufferPointer { 目 in
                                for y in 0..<高 {
                                    let 基 = y * 宽
                                    for x in 0..<宽 {
                                        let i = 基 + x
                                        let p = i * 4

                                        // 没有位移 = 恒等变换（原样输出）。
                                        // 不写这个快路径也能对，但静态首帧会因 2px 羽化带
                                        // 混入一点「补洞色」，白白多出一圈细边。
                                        if DX[i] == 0 && DY[i] == 0 {
                                            目[p] = 源[p]; 目[p+1] = 源[p+1]; 目[p+2] = 源[p+2]; 目[p+3] = 255
                                            continue
                                        }

                                        // 反向映射：只做画面边界夹取（不做「回拉进遮罩」）
                                        let sx = min(max(Float(x) - DX[i], 0), 宽末)
                                        let sy = min(max(Float(y) - DY[i], 0), 高末)

                                        // 【关键】alpha 取采样位置的遮罩值
                                        let a: Float = 纯形变 ? 1 : (背景保护 ? 双线性标量(遮, 宽, 高, sx, sy) : 1)
                                        if a <= 0.02 {
                                            // 采样到背景 → 输出干净背景（背景不会被拖走）
                                            目[p] = 底图[p]; 目[p+1] = 底图[p+1]; 目[p+2] = 底图[p+2]; 目[p+3] = 255
                                        } else {
                                            // 人层取自采样位置，背景取输出位置
                                            let 混合 = 双线性(源, 宽, 高, sx, sy)
                                            let ia = 1 - a
                                            目[p]   = UInt8(min(255, max(0, Float(混合.0) * a + Float(底图[p])   * ia).rounded()))
                                            目[p+1] = UInt8(min(255, max(0, Float(混合.1) * a + Float(底图[p+1]) * ia).rounded()))
                                            目[p+2] = UInt8(min(255, max(0, Float(混合.2) * a + Float(底图[p+2]) * ia).rounded()))
                                            目[p+3] = 255
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return 由像素(出, 宽: 宽, 高: 高)
    }

    // MARK: - 底层工具

    /// 单通道（遮罩）双线性采样
    private static func 双线性标量(_ 源: UnsafeBufferPointer<Float>, _ 宽: Int, _ 高: Int,
                                 _ x: Float, _ y: Float) -> Float {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Float(x0), fy = y - Float(y0)
        let xa = min(max(x0, 0), 宽 - 1), xb = min(max(x0 + 1, 0), 宽 - 1)
        let ya = min(max(y0, 0), 高 - 1), yb = min(max(y0 + 1, 0), 高 - 1)
        let a = 源[ya * 宽 + xa] * (1 - fx) + 源[ya * 宽 + xb] * fx
        let b = 源[yb * 宽 + xa] * (1 - fx) + 源[yb * 宽 + xb] * fx
        return a * (1 - fy) + b * fy
    }

    private static func 双线性(_ 源: UnsafeBufferPointer<UInt8>, _ 宽: Int, _ 高: Int,
                              _ x: Float, _ y: Float) -> (UInt8, UInt8, UInt8) {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Float(x0), fy = y - Float(y0)
        let xa = min(max(x0, 0), 宽 - 1), xb = min(max(x0 + 1, 0), 宽 - 1)
        let ya = min(max(y0, 0), 高 - 1), yb = min(max(y0 + 1, 0), 高 - 1)
        let p00 = (ya * 宽 + xa) * 4, p10 = (ya * 宽 + xb) * 4
        let p01 = (yb * 宽 + xa) * 4, p11 = (yb * 宽 + xb) * 4
        var 出 = (UInt8(0), UInt8(0), UInt8(0))
        let 通道 = [0, 1, 2]
        var 值 = [Float](repeating: 0, count: 3)
        for (k, c) in 通道.enumerated() {
            let a = Float(源[p00 + c]) * (1 - fx) + Float(源[p10 + c]) * fx
            let b = Float(源[p01 + c]) * (1 - fx) + Float(源[p11 + c]) * fx
            值[k] = a * (1 - fy) + b * fy
        }
        出 = (UInt8(min(255, max(0, 值[0]).rounded())),
             UInt8(min(255, max(0, 值[1]).rounded())),
             UInt8(min(255, max(0, 值[2]).rounded())))
        return 出
    }

    static func 归正方向(_ 图: UIImage) -> UIImage? {
        if 图.imageOrientation == .up { return 图 }
        let 格式 = UIGraphicsImageRendererFormat.default()
        格式.scale = 1
        格式.opaque = false
        return UIGraphicsImageRenderer(size: 图.size, format: 格式).image { _ in
            图.draw(in: CGRect(origin: .zero, size: 图.size))
        }
    }

    static func 等比缩(_ 图: UIImage, 到长边 长边: Int) -> CGImage? {
        guard let cg = 图.cgImage else { return nil }
        let 长 = max(cg.width, cg.height)
        if 长 <= 长边 { return cg }
        let k = Double(长边) / Double(长)
        let w = max(1, Int((Double(cg.width) * k).rounded()))
        let h = max(1, Int((Double(cg.height) * k).rounded()))
        guard let 布 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        布.interpolationQuality = .high
        布.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return 布.makeImage()
    }

    static func 读像素(_ cg: CGImage) -> (Int, Int, [UInt8])? {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let 布 = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            布.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, buf) : nil
    }

    /// 像素 → UIImage。
    ///
    /// ⚠️ 2026-11-15 踩过的崩溃：早先版本把 `CGContext(data: 局部数组的指针)` 交出去，
    ///    函数一返回局部数组就释放，`makeImage()` 得到的 CGImage 还指着那块已释放内存，
    ///    SwiftUI 一显示就 EXC_BAD_ACCESS **直接闪退**（现象：选完图点确认立刻退）。
    ///    正确做法：让 CGContext **自己分配**内存，再把像素拷进去 —— 这样
    ///    "谁拥有这块内存"是清晰的，图像的生命周期由 CGImage 自己管。
    static func 由像素(_ buf: [UInt8], 宽 w: Int, 高 h: Int) -> UIImage? {
        guard w > 0, h > 0, buf.count >= w * h * 4 else { return nil }
        guard let 布 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let 目标 = 布.data else { return nil }
        buf.withUnsafeBytes { raw in
            if let 源 = raw.baseAddress, raw.count >= w * h * 4 {
                memcpy(目标, 源, w * h * 4)
            }
        }
        guard let cg = 布.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Vision

    /// 人像分割，返回原始尺寸的遮罩（0~255）
    static func 分割遮罩(_ cg: CGImage) -> (宽: Int, 高: Int, 数据: [Float])? {
        let 请求 = VNGeneratePersonSegmentationRequest()
        请求.qualityLevel = .accurate
        请求.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([请求])
        } catch {
            return nil
        }
        guard let 观 = 请求.results?.first else { return nil }
        let pb = 观.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let 行 = CVPixelBufferGetBytesPerRow(pb)
        var 数据 = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let 行首 = base.advanced(by: y * 行).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                数据[y * w + x] = Float(行首[x]) / 255
            }
        }
        return (w, h, 数据)
    }

    /// 最大人脸宽度（像素）
    static func 探测脸宽(_ cg: CGImage) -> Float {
        let 请求 = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([请求])) != nil else { return 0 }
        let 框们 = (请求.results ?? []).map { $0.boundingBox }
        guard let 最 = 框们.max(by: { $0.width < $1.width }) else { return 0 }
        return Float(最.width) * Float(cg.width)
    }

    // MARK: - 小工具

    static func 缩放到(遮罩: [Float], 从宽 sw: Int, 高 sh: Int, 到宽 dw: Int, 高 dh: Int) -> [Float] {
        guard sw > 0, sh > 0, dw > 0, dh > 0 else { return [Float](repeating: 0, count: max(0, dw * dh)) }
        if sw == dw && sh == dh { return 遮罩 }
        var 出 = [Float](repeating: 0, count: dw * dh)
        for y in 0..<dh {
            let sy = min(sh - 1, Int(Float(y) * Float(sh) / Float(dh)))
            for x in 0..<dw {
                let sx = min(sw - 1, Int(Float(x) * Float(sw) / Float(dw)))
                出[y * dw + x] = 遮罩[sy * sw + sx]
            }
        }
        return 出
    }

    /// 可分离的最大值滤波（形态学膨胀）。
    /// 膨胀能把"主体边缘外一圈"纳入可动区域，这是修"残留不动块"的关键。
    /// 最小值滤波 = 形态学**腐蚀**（2026-11-16：遮罩往内收，避免把背景划进可动区）
    static func 最小值滤波(_ 入: [Float], 宽 w: Int, 高 h: Int, 半径 r: Int, 横向: Bool) -> [Float] {
        guard r > 0, w > 1, h > 1 else { return 入 }
        var 出 = [Float](repeating: 1, count: w * h)
        if 横向 {
            for y in 0..<h {
                for x in 0..<w {
                    var m: Float = 1
                    let a = max(0, x - r), b = min(w - 1, x + r)
                    for k in a...b { let v = 入[y * w + k]; if v < m { m = v } }
                    出[y * w + x] = m
                }
            }
        } else {
            for y in 0..<h {
                let a = max(0, y - r), b = min(h - 1, y + r)
                for x in 0..<w {
                    var m: Float = 1
                    for k in a...b { let v = 入[k * w + x]; if v < m { m = v } }
                    出[y * w + x] = m
                }
            }
        }
        return 出
    }

    static func 最大值滤波(_ 入: [Float], 宽 w: Int, 高 h: Int, 半径 r: Int, 横向: Bool) -> [Float] {
        guard r > 0, w > 1, h > 1 else { return 入 }
        var 出 = [Float](repeating: 0, count: w * h)
        if 横向 {
            for y in 0..<h {
                for x in 0..<w {
                    var m: Float = 0
                    let a = max(0, x - r), b = min(w - 1, x + r)
                    for k in a...b { let v = 入[y * w + k]; if v > m { m = v } }
                    出[y * w + x] = m
                }
            }
        } else {
            for y in 0..<h {
                let a = max(0, y - r), b = min(h - 1, y + r)
                for x in 0..<w {
                    var m: Float = 0
                    for k in a...b { let v = 入[k * w + x]; if v > m { m = v } }
                    出[y * w + x] = m
                }
            }
        }
        return 出
    }

    /// 一次盒式模糊（边缘按 clamp 处理）
    static func 盒模糊(_ 入: [Float], 宽 w: Int, 高 h: Int, 半径 r: Int) -> [Float] {
        guard r > 0, w > 1, h > 1 else { return 入 }
        var 中 = [Float](repeating: 0, count: w * h)
        var 出 = [Float](repeating: 0, count: w * h)
        let 窗 = Float(2 * r + 1)
        // 横向
        for y in 0..<h {
            var 和: Float = 0
            for x in -r...r { 和 += 入[y * w + min(max(x, 0), w - 1)] }
            for x in 0..<w {
                中[y * w + x] = 和 / 窗
                和 -= 入[y * w + min(max(x - r, 0), w - 1)]
                和 += 入[y * w + min(max(x + r + 1, 0), w - 1)]
            }
        }
        // 纵向
        for x in 0..<w {
            var 和: Float = 0
            for y in -r...r { 和 += 中[min(max(y, 0), h - 1) * w + x] }
            for y in 0..<h {
                出[y * w + x] = 和 / 窗
                和 -= 中[min(max(y - r, 0), h - 1) * w + x]
                和 += 中[min(max(y + r + 1, 0), h - 1) * w + x]
            }
        }
        return 出
    }
}
