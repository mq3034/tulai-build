import Foundation
import CoreGraphics

/// 抠图候选的两个来源，以及它们的合并规则。
///
/// 为什么需要两路（2026-11-21 三张双人图真机实测）：
///   系统实例：两人正面并排 → 两个都能抠；一人被挡 → 只出前面那个；两人背影小人物低对比 → **一个都出不来**
///   我们的连通块：同一张「背影」图 → **两块都干净**
///   ⇒ 单靠任何一方都会失手，必须互补。
enum 端侧候选 {

    /// 最小候选面积比（占画面）。小于它的连通块当噪声丢掉。
    static let 最小面积比: Float = 0.008

    /// 合并两路候选并按面积从大到小排。
    /// - Parameters:
    ///   - cg: 工作尺寸的图（长边约 1200）
    ///   - 粗掩膜: 我们自己的模型（isnetis/显著性）出的灰度掩膜；nil 则只用系统实例
    static func 全部(_ cg: CGImage, 粗掩膜: CGImage?) -> [抠图候选] {
        var 出 = 端侧主体.候选(cg)                    // ① 系统实例（可能为空）
        if let 粗 = 粗掩膜 {
            出 += 连通块候选(粗)                      // ② 我们的连通块
        }
        出 = 去重(出)
        出.sort { $0.面积比 > $1.面积比 }
        return 出
    }

    /// 把一张灰度掩膜拆成若干**不连通**的块，每块一个候选。
    static func 连通块候选(_ 掩膜: CGImage) -> [抠图候选] {
        let 宽 = 掩膜.width, 高 = 掩膜.height, 数 = 宽 * 高
        guard 数 > 0 else { return [] }
        var 值 = [UInt8](repeating: 0, count: 数)
        guard let 布 = CGContext(data: &值, width: 宽, height: 高, bitsPerComponent: 8,
                                bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        布.draw(掩膜, in: CGRect(x: 0, y: 0, width: 宽, height: 高))

        var 标记 = [Int32](repeating: 0, count: 数)   // 0=没标
        var 当前: Int32 = 0
        var 栈 = [Int](), 面积 = [Int32: Int]()
        let 最小像素 = Int(Float(数) * 最小面积比)

        for 起 in 0..<数 where 值[起] > 128 && 标记[起] == 0 {
            当前 += 1
            var 计 = 0
            栈.removeAll(keepingCapacity: true); 栈.append(起)
            标记[起] = 当前
            while let p = 栈.popLast() {
                计 += 1
                let x = p % 宽, y = p / 宽
                // 4 邻域
                if x > 0 { let q = p - 1; if 值[q] > 128 && 标记[q] == 0 { 标记[q] = 当前; 栈.append(q) } }
                if x < 宽 - 1 { let q = p + 1; if 值[q] > 128 && 标记[q] == 0 { 标记[q] = 当前; 栈.append(q) } }
                if y > 0 { let q = p - 宽; if 值[q] > 128 && 标记[q] == 0 { 标记[q] = 当前; 栈.append(q) } }
                if y < 高 - 1 { let q = p + 宽; if 值[q] > 128 && 标记[q] == 0 { 标记[q] = 当前; 栈.append(q) } }
            }
            面积[当前] = 计
        }

        var 出: [抠图候选] = []
        for (号, 计) in 面积 where 计 >= 最小像素 {
            // 只保留这一块的掩膜
            var 单 = [UInt8](repeating: 0, count: 数)
            var 加x = 0, 加y = 0
            for i in 0..<数 where 标记[i] == 号 {
                单[i] = 255; 加x += i % 宽; 加y += i / 宽
            }
            guard let 图 = 端侧主体.灰度图(单, 宽: 宽, 高: 高) else { continue }
            let 比 = Float(计) / Float(数)
            let 心 = CGPoint(x: Double(加x) / Double(计) / Double(宽),
                             y: Double(加y) / Double(计) / Double(高))
            出.append(抠图候选(掩膜: 图, 面积比: 比, 中心: 心, 来源: "我们的连通块"))
        }
        return 出
    }

    /// 去掉"同一块东西被两路都给出"的重复候选：面积重叠率 > 0.65 视为重复，保留先出现的（系统实例）。
    static func 去重(_ 候选们: [抠图候选]) -> [抠图候选] {
        var 留: [抠图候选] = []
        for c in 候选们 {
            var 重复 = false
            for k in 留 {
                if 重叠率(c.掩膜, k.掩膜) > 0.65 { 重复 = true; break }
            }
            if !重复 { 留.append(c) }
        }
        return 留
    }

    /// 两张掩膜的 IoU（粗采样，每 4 像素取一个，够用且快）
    static func 重叠率(_ a: CGImage, _ b: CGImage) -> Float {
        let 宽 = min(a.width, b.width), 高 = min(a.height, b.height)
        guard 宽 > 0, 高 > 0 else { return 0 }
        var 甲 = [UInt8](repeating: 0, count: 宽 * 高)
        var 乙 = [UInt8](repeating: 0, count: 宽 * 高)
        for (图, 目标) in [(a, 0), (b, 1)] {
            var 缓 = 目标 == 0 ? 甲 : 乙
            guard let 布 = CGContext(data: &缓, width: 宽, height: 高, bitsPerComponent: 8,
                                    bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
            布.draw(图, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
            if 目标 == 0 { 甲 = 缓 } else { 乙 = 缓 }
        }
        var 交 = 0, 并 = 0
        var i = 0
        while i < 甲.count {
            let p = 甲[i] > 128, q = 乙[i] > 128
            if p || q { 并 += 1; if p && q { 交 += 1 } }
            i += 4
        }
        return 并 == 0 ? 0 : Float(交) / Float(并)
    }

    /// 把若干候选合成为一张掩膜（点两个就选两个）
    static func 合成(_ 选中: [抠图候选], 宽: Int, 高: Int) -> CGImage? {
        guard !选中.isEmpty else { return nil }
        let 数 = 宽 * 高
        var 合 = [UInt8](repeating: 0, count: 数)
        for c in 选中 {
            var 单 = [UInt8](repeating: 0, count: 数)
            guard let 布 = CGContext(data: &单, width: 宽, height: 高, bitsPerComponent: 8,
                                    bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            布.draw(c.掩膜, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
            for i in 0..<数 where 单[i] > 合[i] { 合[i] = 单[i] }
        }
        return 端侧主体.灰度图(合, 宽: 宽, 高: 高)
    }

    /// 归一化点（0~1）是否落在某个候选内部（界面点选用）
    static func 命中(_ 候选: 抠图候选, 归一化点: CGPoint) -> Bool {
        let 宽 = 候选.掩膜.width, 高 = 候选.掩膜.height
        guard 宽 > 0, 高 > 0 else { return false }
        let x = Int(归一化点.x * Double(宽)), y = Int(归一化点.y * Double(高))
        guard x >= 0, x < 宽, y >= 0, y < 高 else { return false }
        var 值 = [UInt8](repeating: 0, count: 宽 * 高)
        guard let 布 = CGContext(data: &值, width: 宽, height: 高, bitsPerComponent: 8,
                                bytesPerRow: 宽, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        布.draw(候选.掩膜, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
        // 允许点到边缘附近：在 5x5 窗口里找任一命中
        for dy in -2...2 {
            for dx in -2...2 {
                let xx = x + dx, yy = y + dy
                if xx >= 0, xx < 宽, yy >= 0, yy < 高, 值[yy * 宽 + xx] > 128 { return true }
            }
        }
        return false
    }
}
