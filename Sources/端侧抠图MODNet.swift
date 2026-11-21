import Foundation
import CoreML
import CoreVideo
import CoreGraphics
import UIKit

/// 端侧抠图 · MODNet 蒸馏版（Core ML）
///
/// 为什么有它（2026-11-17）：
///   `Models/Seg.mlmodelc`（isnetis，1024²，约 84MB）是**图像分割**模型，天生偏硬边：
///   发丝、长裙下摆、过曝的白色边缘只能靠 `推脸.软遮罩()` 事后用引导滤波"补"出软边。
///   MODNet 是**抠图（matting）**模型，输出天生就是 0~1 的软 alpha；
///   蒸馏版约 25MB，体积和速度都更适合放进 App。
///
/// 规格（2026-11-17 按 ci01 的 `I:\拣货\抠图蒸馏\转换\报告.md` §2「四行规格」定案）：
///   · 输入：名字 `image`，**ImageType（RGB）**，形状 1×3×N×N；
///     **归一化已烘进 mlmodelc**（`x*(1/127.5) - 1.0`，值域 [-1,1]），**Swift 侧什么都不做**，
///     只负责把图摆成 N×N 的 RGB 像素缓冲（Core ML 会自己套 scale/bias）。
///   · 输出：名字 `mask`，MLMultiArray，1×1×N×N，**Float16**（`端侧分割` 踩过的 Float16 坑这里同样处理）。
///   · **口径：整图 BICUBIC 拉伸到 N×N（不补边、不保持长宽比）→ 推理 → alpha 按原尺寸双线性放大。**
///     这一条必须和训练一致：MODNet 是在拉伸数据上训练的，letterbox 会让输入分布偏移；
///     而 isnetis（`端侧分割`）是补边训练的 —— **两者口径不同，不能共用一套预处理**。
///   · N **不写死**：从 `modelDescription` 的 ImageType 声明里读（v2 是 512；v3 若 1024 训练会自动跟随）。
///     动态尺寸不可用（onnx2torch trace 把形状写死了，喂别的尺寸会抛错），所以只按声明跑。
///
/// 接口对齐（这是能替换 isnetis 的前提）：
///   · `跑遮罩(_:)`   → `[Float]`，长度 = 宽×高，值域 0~1 —— **与 `推脸.软遮罩()` 的输入/输出格式一致**；
///   · `跑(_:)`       → 与入图同尺寸的灰度 CGImage —— **与 `端侧分割.跑()` 的签名一致**（便于平替）；
///   · `优先遮罩(_:)` → 开关 + 优先级 + 回退都收在一个函数里，`推脸.准备()` 只需一行接线。
///
/// 回退路径（任何一步失败都往下走，绝不把异常抛给调用方）：
///   开关关 / 模型没打进包 / 认不出输入规格 / 输入组装失败 / 推理失败 / 覆盖率异常
///     → 回退 `端侧分割`（isnetis）
///     → 再往下由 `推脸.准备()` 自己的链子接（电脑 8770 → Vision → 显著性）
enum 端侧抠图MODNet {

    // MARK: - 开关（唯一需要人动的地方）

    private static let 开关键 = "端侧抠图MODNet.启用"

    /// ★ 主开关：**默认关闭**（键不存在时 `bool(forKey:)` 返回 false）。
    ///
    /// 为什么默认关：新模型在真机上还没看过对比图（用户要求先看效果）。
    /// 关着的时候行为与 v14 完全一致（走 isnetis），打开才切到 MODNet。
    /// 用 UserDefaults 存：改一次就记住，重启 App 不用重新设，方便真机验收。
    static var 启用: Bool {
        get { (UserDefaults.standard.object(forKey: 开关键) as? Bool) ?? true }   // 2026-11-18 测试构建：默认开（对比完改回 false）
        set { UserDefaults.standard.set(newValue, forKey: 开关键) }
    }

    /// 兜底输入边长（**仅当模型没声明尺寸时**才用；正常情况下以 `modelDescription` 的声明为准）。
    ///
    /// 现在这个值只是保险丝：v2 的 mlmodelc 声明 512 → 实际按 512 跑；
    /// 等 v3（1024 训练）的 mlmodelc 进来，声明是 1024 → 自动按 1024 跑，不用改这里。
    /// （2026-11-17 曾按 lead 要求把默认值从 512 上调到 1024，后又按 ci01 报告改成"跟随声明"。
    ///  依据：v2 在 512 上门禁 7/10，在 1024 上反而 4/10 + 2 条一票否决 —— 尺寸不能瞎猜。）
    static var 边 = 1024

    /// 特征名覆盖。nil = 自动识别（单输入单输出模型按 modelDescription 找）。
    /// 报告已定案：输入 `image`、输出 `mask`。钉死可以避免换模型版本时"猜"错特征。
    static var 输入名: String?
    static var 输出名: String?

    /// 模型有没有打进包。没打进包时 `优先遮罩` 自动走 isnetis，不会崩。
    static var 可用: Bool {
        Bundle.main.url(forResource: "ModNet", withExtension: "mlmodelc") != nil
    }

    /// 一次抠像的结果：0~1 的 alpha + 来源 + 耗时（来源直接塞进 `会话.遮罩来源`）
    struct 结果 {
        let 遮罩: [Float]
        let 来源: String
        let 毫秒: Int
    }

    // MARK: - 对外入口

    /// 提前把模型加载好（首次加载 + Core ML 编译约 1~3 秒，别让用户等在图里）。
    static func 预热() {
        _ = 模型或空()
    }

    /// ★ 抠像优先级：**系统前景实例掩膜(iOS17+) → MODNet(开关) → isnetis → 显著性(u2netp)兜底**。
    ///
    /// 2026-11-21 全量实测（22 张，两个模型逐张比）：
    ///   · animeseg(isnetis) 在真实照片上全空（覆盖 0.00），动漫上更完整
    ///     （B06 0.39 vs u2netp 0.23；B07 0.81 vs 0.14；B09 0.09 vs 0.05）；
    ///   · u2netp 在真实照片上能出主体，动漫上常只给一块；
    ///   ⇒ 正确顺序是「分割优先、显著性兜底」。曾试过把显著性提到最前，会让上述动漫图掉分。
    ///   · 未解决的反例 B02（日落少女）：animeseg 选天空(0.44)、u2netp 选人(0.05)；
    ///     贴边规则、纹理规则两种判别式实测都不成立，留待后续。
    ///   · u2netp 没打进包时（可用=false）本步自动跳过，行为与改动前完全一致。
    ///
    /// 返回 nil = 端侧这条路彻底不通，调用方继续走自己的回退链（电脑 / Vision / 显著性）。
    /// 同步阻塞，调用方放后台线程（与 `端侧分割.跑` 的使用方式一致）。
    static func 优先遮罩(_ cg: CGImage) -> 结果? {
        // ⓪ 系统前景实例掩膜（iOS 17+）：回答「该抠谁」
        //    2026-11-21 真机实测（用户 iPhone）：B02（日落海边 + 整片天空）
        //      · animeseg → 抠成天空（覆盖 44%）
        //      · 本步      → 抠对了人，连被风吹起的发丝都保留（覆盖 49%）
        if 端侧主体.可用 {
            let t0 = Date()
            if let 掩 = 端侧主体.掩膜(cg), let 浮 = 从灰度(掩) {
                let 覆盖 = 覆盖率(浮)
                if 覆盖 > 0.005, 覆盖 < 0.95 {
                    let 毫秒 = Int(Date().timeIntervalSince(t0) * 1000)
                    诊断.记("推脸：遮罩来自系统前景实例掩膜，覆盖 \(Int(覆盖 * 100))%，\(毫秒)ms")
                    return 结果(遮罩: 浮, 来源: "端侧-系统主体", 毫秒: 毫秒)
                }
                诊断.记("推脸：系统掩膜覆盖 \(Int(覆盖 * 100))% 不合理，往下走")
            }
        }

        // ① 蒸馏模型（只在开关打开时）
        if 启用, 可用 {
            let t0 = Date()
            if let 浮 = 跑遮罩(cg) {
                let 覆盖 = 覆盖率(浮)
                // 覆盖太低 = 没分到人；覆盖≈100% = 模型退化成"全 1"（等于没抠）。
                // 两种都判为无效，回退 isnetis，而不是把坏遮罩交给推脸。
                if 覆盖 > 0.01, 覆盖 < 0.995 {
                    let 毫秒 = Int(Date().timeIntervalSince(t0) * 1000)
                    诊断.记("推脸：遮罩来自 MODNet 蒸馏（离线），覆盖 \(Int(覆盖 * 100))%，\(毫秒)ms")
                    return 结果(遮罩: 浮, 来源: "端侧-MODNet蒸馏", 毫秒: 毫秒)
                }
                诊断.记("推脸：MODNet 输出异常（覆盖 \(Int(覆盖 * 100))%），回退 isnetis")
            } else {
                诊断.记("推脸：MODNet 调用失败，回退 isnetis")
            }
        }

        // ② 回退：isnetis（v9~v14 已在真机验证过的那条路）
        if 端侧分割.可用 {
            let t0 = Date()
            if let 掩 = 端侧分割.跑(cg), let 浮 = 从灰度(掩) {
                let 覆盖 = 覆盖率(浮)
                if 覆盖 > 0.01 {
                    let 毫秒 = Int(Date().timeIntervalSince(t0) * 1000)
                    return 结果(遮罩: 浮, 来源: "端侧-isnetis", 毫秒: 毫秒)
                }
            }
        }
        // ③ 最后兜底：显著性（u2netp）
        //    为什么放最后而不是最前（2026-11-21 全量实测，22 张）：
        //      animeseg 在真实照片上全空（0.00）、在动漫上更完整（B06 0.39 vs 0.23、
        //      B07 0.81 vs 0.14）；把显著性提到最前会让这些动漫图掉分。
        //      显著性只在「Seg 也分不到人」时兜底 —— 这时它总比 nil 强。
        if 端侧显著性.可用 {
            let t0 = Date()
            if let 掩 = 端侧显著性.跑(cg), let 浮 = 从灰度(掩) {
                let 覆盖 = 覆盖率(浮)
                if 覆盖 > 0.005, 覆盖 < 0.75 {
                    let 毫秒 = Int(Date().timeIntervalSince(t0) * 1000)
                    诊断.记("推脸：遮罩来自端侧显著性(u2netp)兜底，覆盖 \(Int(覆盖 * 100))%，\(毫秒)ms")
                    return 结果(遮罩: 浮, 来源: "端侧-显著性", 毫秒: 毫秒)
                }
            }
        }
        return nil
    }

    /// 跑一次，返回**和入图同尺寸**的 0~1 浮点 alpha（长度 = 宽×高）。
    ///
    /// 这是与 `推脸.软遮罩()` 对接的主接口：
    ///   `软遮罩(端侧抠图MODNet.跑遮罩(缩) ?? [], 引导: 源, 宽: 宽, 高: 高)`
    /// 同步阻塞，调用方放后台线程。
    static func 跑遮罩(_ cg: CGImage) -> [Float]? {
        guard let m = 模型或空() else { return nil }
        记一次规格()

        let 原宽 = cg.width, 原高 = cg.height
        guard 原宽 > 0, 原高 > 0 else { return nil }

        guard let 入项 = 选输入(m) else {
            诊断.记("端侧抠图MODNet：认不出输入规格（定案 A 要求 ImageType），回退 isnetis")
            return nil
        }
        let 边 = 入项.边

        // ① **整图 BICUBIC 拉伸**到 N×N：不补边、不保持长宽比。
        //    这是**训练口径**（`训练\微调.py` / `评测.py` / `导出onnx.py` 全是
        //    `Image.BICUBIC` 直接 resize 到 N×N），也是 ci01 对拍用的口径。
        //    ⚠️ 和 isnetis 不同：isnetis 是**补边**训练的（`端侧分割.画补边`），
        //    两者口径不同，不能共用一套预处理（letterbox 会让 MODNet 输入分布偏移）。
        guard let 方 = 拉伸到(cg, 宽: 边, 高: 边) else {
            诊断.记("端侧抠图MODNet：拉伸失败，回退 isnetis")
            return nil
        }

        // ② 组装输入：只做 ImageType（归一化已烘在模型里，Swift 侧什么都不做）
        guard let 入 = 造输入(入项, 图: 方) else {
            诊断.记("端侧抠图MODNet：输入组装失败（模型 \(边)²）")
            return nil
        }
        guard let 供 = try? MLDictionaryFeatureProvider(dictionary: [入项.名: 入]),
              let 果 = try? m.prediction(from: 供),
              let 映 = 挑输出(果, m) else {
            诊断.记("端侧抠图MODNet：推理失败，回退 isnetis")
            return nil
        }

        // ③ 输出 alpha 已是 N×N（拉伸后的坐标），直接**双线性拉伸回原图尺寸**。
        //    报告 §2 口径：输出按原图尺寸双线性放大；这里不做裁切（拉伸没有补边可裁）。
        //    不用 LANCZOS：放大时它会在硬边两侧过冲（ringing），在 alpha 上就是
        //    "边缘一圈偏亮/偏暗的细线" —— 正是推脸时最刺眼的鬼影；双线性更软，且
        //    alpha 的软边本来就是渐变，不会因此丢发丝。
        let 出 = 缩放浮点(映.值, 从宽: 映.宽, 从高: 映.高, 到宽: 原宽, 到高: 原高)
        return 出.isEmpty ? nil : 出
    }

    /// 与 `端侧分割.跑()` **同签名**的灰度版本（白 255 = 前景，灰阶存 0~1 的 alpha）。
    ///
    /// 给"先用最小改动平替 isnetis"的场景用：调用方代码一行都不用改，
    /// 只要把 `端侧分割.跑` 换成 `端侧抠图MODNet.跑`。
    /// ⚠️ 缺点：8 位量化会丢掉 1/255 以下的软边信息，正式接入建议直接用 `跑遮罩` 的浮点。
    static func 跑(_ cg: CGImage) -> CGImage? {
        guard let 浮 = 跑遮罩(cg) else { return nil }
        let n = 浮.count
        var 字节 = [UInt8](repeating: 0, count: n)
        for i in 0..<n { 字节[i] = 量化(浮[i]) }
        return 灰度图(字节, 宽: cg.width, 高: cg.height)
    }

    // MARK: - 模型

    private static var 模型: MLModel?
    private static let 锁 = NSLock()
    private static var 已记规格 = false

    private static func 模型或空() -> MLModel? {
        锁.lock()
        defer { 锁.unlock() }
        if let 模型 { return 模型 }
        guard let 址 = Bundle.main.url(forResource: "ModNet", withExtension: "mlmodelc") else { return nil }
        let 配置 = MLModelConfiguration()
        配置.computeUnits = .all          // 能上神经引擎就上（边长 1024 的小模型 ANE 最合适）
        guard let m = try? MLModel(contentsOf: 址, configuration: 配置) else { return nil }
        模型 = m
        return m
    }

    /// 真机排查用：把模型实际规格拼成一行。
    ///
    /// 为什么必须记：`.mlmodelc` 是二进制，Swift 侧**看不到**转换时的归一化常数。
    /// 万一 ci01 的导出和约定不一致（比如 ImageType 烘成了 /255-0.5 而不是 (x/255-0.5)/0.5），
    /// 这一行就是唯一能当场判断"到底是形状不对、dtype 不对、还是归一化不对"的证据。
    static func 规格摘要() -> String {
        guard let m = 模型或空() else {
            return "ModNet.mlmodelc 没进包（检查 project.yml 是否加了 Models/ModNet.mlmodelc 的 folder 引用）"
        }
        var 行 = [String]()
        for (名, d) in m.modelDescription.inputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
            if d.type == .image, let c = d.imageConstraint {
                行.append("入 \(名) ImageType \(c.pixelsWide)×\(c.pixelsHigh)")
            } else if let c = d.multiArrayConstraint {
                行.append("入 \(名) MultiArray \(c.shape.map { $0.intValue }) dtype=\(c.dataType.rawValue)")
            } else {
                行.append("入 \(名) 类型\(d.type.rawValue)")
            }
        }
        for (名, d) in m.modelDescription.outputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
            if let c = d.multiArrayConstraint {
                行.append("出 \(名) MultiArray \(c.shape.map { $0.intValue }) dtype=\(c.dataType.rawValue)")
            } else {
                行.append("出 \(名) 类型\(d.type.rawValue)")
            }
        }
        return 行.joined(separator: "；")
    }

    private static func 记一次规格() {
        锁.lock()
        let 要 = !已记规格
        if 要 { 已记规格 = true }
        锁.unlock()
        guard 要 else { return }
        诊断.记("端侧抠图MODNet 规格：" + 规格摘要())
    }

    // MARK: - 输入

    /// 输入项：只支持 ImageType。
    ///
    /// 为什么砍掉 MultiArray 分支（2026-11-17 按 ci01 报告 §3 定案 A）：
    ///   归一化只有**一处**定义（烘在 mlmodelc 里）。如果 App 侧再自己组 MultiArray 并做
    ///   `(x/255-0.5)/0.5`，一旦和转换口径差 2 倍就是**静默错误**（输出糊/全白，且不报错）。
    ///   所以这里只认 ImageType：不是 ImageType 就返回 nil → 回退 isnetis，宁可不用也不猜。
    private struct 入项 {
        let 名: String
        let 边: Int
    }

    private static func 选输入(_ m: MLModel) -> 入项? {
        let 表 = m.modelDescription.inputDescriptionsByName
        // 特征名：指定优先；否则取第一个 ImageType 输入（多输入时图像才是我们该喂的）
        var 名: String?
        if let 指定 = 输入名, 表[指定]?.type == .image { 名 = 指定 }
        if 名 == nil { 名 = 表.sorted(by: { $0.key < $1.key }).first(where: { $0.value.type == .image })?.key }
        guard let 名, let c = 表[名]?.imageConstraint else { return nil }
        // 边长：ImageType 声明就是唯一可用的尺寸（onnx2torch trace 把形状写死了，
        // 喂别的尺寸会抛错）；没声明才回落到兜底 `边`。
        var 边 = 端侧抠图MODNet.边
        if c.pixelsWide > 0, c.pixelsWide == c.pixelsHigh { 边 = c.pixelsWide }
        guard 边 > 0 else { return nil }
        return 入项(名: 名, 边: 边)
    }

    /// ImageType 输入：只管把图摆成模型要求的 RGB 像素缓冲。
    /// **不在这里做归一化** —— scale/bias 已烘进 mlmodelc（报告 §3 定案 A）。
    private static func 造输入(_ 项: 入项, 图: CGImage) -> MLFeatureValue? {
        guard 图.width == 项.边, 图.height == 项.边 else { return nil }
        guard let 缓 = 像素缓冲(图) else { return nil }
        return MLFeatureValue(pixelBuffer: 缓)
    }

    // MARK: - 输出

    private static func 挑输出(_ 果: MLFeatureProvider, _ m: MLModel) -> (宽: Int, 高: Int, 值: [Float])? {
        if let 名 = 输出名, let a = 果.featureValue(for: 名)?.multiArrayValue { return 读数(a) }
        // 单输出是常态；多输出时取面积最大的那个（alpha 一定是 H×W 级别的图，不是标量）
        var 最大: (宽: Int, 高: Int, 值: [Float])?
        for 名 in m.modelDescription.outputDescriptionsByName.keys.sorted() {
            guard let a = 果.featureValue(for: 名)?.multiArrayValue, let 读 = 读数(a) else { continue }
            if 最大 == nil || 读.宽 * 读.高 > 最大!.宽 * 最大!.高 { 最大 = 读 }
        }
        return 最大
    }

    private static func 读数(_ 阵: MLMultiArray) -> (宽: Int, 高: Int, 值: [Float])? {
        let 形 = 阵.shape.map { $0.intValue }
        guard 形.count >= 2 else { return nil }
        var 宽 = 形[形.count - 1]
        var 高 = 形[形.count - 2]
        var 尾通道 = false
        if 宽 == 1, 形.count >= 3 {          // [1,H,W,1]：最后两维是 (W,1)
            尾通道 = true
            宽 = 形[形.count - 2]
            高 = 形[形.count - 3]
        }
        let n = 宽 * 高
        // 元素总数必须**正好**等于 H×W：多出来说明出口带了 3 通道（RGB）或 batch>1，
        // 那种情况下按单通道读会读到错的东西，宁可直接判失败让上层回退。
        guard 宽 > 1, 高 > 1, 阵.count == n else { return nil }

        var 出 = [Float](repeating: 0, count: n)
        if 行主连续(形, 阵.strides.map { $0.intValue }) {
            // ⚠️ Float16 陷阱（`端侧分割` 踩过）：mlprogram 的输出常常是 fp16 存储，
            //    只按 Float32 读会读出垃圾值（-0 或 1e-40 那种），遮罩整片错。
            //    所以按实际 dataType 分支，四种宽度都接。
            switch 阵.dataType {
            case .float32:
                阵.dataPointer.withMemoryRebound(to: Float32.self, capacity: n) { p in
                    for i in 0..<n { 出[i] = p[i] }
                }
            case .float16:
                阵.dataPointer.withMemoryRebound(to: Float16.self, capacity: n) { p in
                    for i in 0..<n { 出[i] = Float(p[i]) }
                }
            case .double:
                阵.dataPointer.withMemoryRebound(to: Double.self, capacity: n) { p in
                    for i in 0..<n { 出[i] = Float(p[i]) }
                }
            case .int32:
                阵.dataPointer.withMemoryRebound(to: Int32.self, capacity: n) { p in
                    for i in 0..<n { 出[i] = Float(p[i]) }
                }
            @unknown default:
                return nil
            }
        } else {
            // 非连续（极少见）：按索引慢取。一次抠像只跑一次，慢一点换正确。
            var 模板 = [NSNumber](repeating: NSNumber(value: 0), count: 形.count)
            for y in 0..<高 {
                for x in 0..<宽 {
                    if 尾通道 {
                        模板[形.count - 3] = NSNumber(value: y)
                        模板[形.count - 2] = NSNumber(value: x)
                        模板[形.count - 1] = NSNumber(value: 0)
                    } else {
                        模板[形.count - 2] = NSNumber(value: y)
                        模板[形.count - 1] = NSNumber(value: x)
                    }
                    出[y * 宽 + x] = 阵[模板].floatValue
                }
            }
        }
        // 拉回 0~1。超出范围说明导出时漏了 sigmoid（输出是 logits）——
        // 这不能在 App 侧猜着补，必须回去改转换脚本，见 接入说明 的风险 1。
        for i in 0..<n { 出[i] = min(1, max(0, 出[i])) }
        return (宽, 高, 出)
    }

    /// 多维数组的 strides 是不是行主连续（内存布局和 [i0][i1]... 顺序一致）
    private static func 行主连续(_ 形: [Int], _ 跨: [Int]) -> Bool {
        guard 形.count == 跨.count, !形.isEmpty else { return false }
        var 期 = 1
        for i in stride(from: 形.count - 1, through: 0, by: -1) {
            guard 跨[i] == 期 else { return false }
            期 *= max(1, 形[i])
        }
        return true
    }

    // MARK: - 像素搬运

    /// 覆盖率（alpha > 0.5 的像素占比）—— 判"到底有没有分到人"
    private static func 覆盖率(_ 遮: [Float]) -> Float {
        guard !遮.isEmpty else { return 0 }
        var 数 = 0
        for v in 遮 where v > 0.5 { 数 += 1 }
        return Float(数) / Float(遮.count)
    }

    /// 0~1 → 0~255（和电脑侧 np.clip(0,1)*255 一致）
    private static func 量化(_ v: Float) -> UInt8 {
        if v <= 0 { return 0 }
        if v >= 1 { return 255 }
        return UInt8(v * 255 + 0.5)
    }

    /// CGImage → **整图 BICUBIC 拉伸**到指定尺寸（不补边、不保持长宽比）。
    ///
    /// 为什么是拉伸（2026-11-17 定案，取代之前的 letterbox + 镜像补边）：
    ///   MODNet 的训练/评测/导出（`训练\微调.py`、`评测.py`、`导出onnx.py`）全部是
    ///   `Image.BICUBIC` 直接 resize 到 N×N；ci01 的 Core ML 对拍也按拉伸口径做
    ///   （v2 onnx：torch vs onnx maxdiff 8.97e-06、IoU 1.000000）。
    ///   letterbox 会把输入变成**分布外**（多出黑边/镜像带、主体占比变小），
    ///   即使模型本身没坏，输出也会偏 —— 这是口径问题，不是模型问题。
    ///   注意：isnetis（`端侧分割`）是**补边**训练的，两者口径不同，不能共用一套预处理。
    private static func 拉伸到(_ 图: CGImage, 宽: Int, 高: Int) -> CGImage? {
        guard 宽 > 0, 高 > 0, let (sw, sh, 像素) = 读像素(图) else { return nil }
        guard sw != 宽 || sh != 高 else { return 图 }
        guard let 出 = 拉伸双三次(像素, 从宽: sw, 从高: sh, 到宽: 宽, 到高: 高) else { return nil }
        return 彩色图(出, 宽: 宽, 高: 高)
    }

    /// RGBA 字节 → 横向/纵向两次一维三次卷积（可分离）。核参数 a = -0.5，与 Pillow `Image.BICUBIC` 同款。
    ///
    /// 为什么自己在 Swift 里做而不用 `CGContext`：Core Graphics **不暴露** kernel 选择
    /// （`.high` 在不同 iOS 版本上可能是 Lanczos），无法保证和训练口径一致；
    /// 这里显式做 4 tap 三次插值，跨版本行为固定。边缘用 clamp（再归一化权重）避免黑边。
    private static func 拉伸双三次(_ 入: [UInt8], 从宽 sw: Int, 从高 sh: Int,
                             到宽 dw: Int, 到高 dh: Int) -> [UInt8]? {
        guard sw > 0, sh > 0, dw > 0, dh > 0, 入.count >= sw * sh * 4 else { return nil }

        // ① 横向：sw → dw，结果保留 Float（避免中间结果被量化两次）
        var 横 = [Float](repeating: 0, count: dw * sh * 3)
        let 比x = Float(sw) / Float(dw)
        var 权x = [Float](repeating: 0, count: dw * 4)
        var 索x = [Int](repeating: 0, count: dw * 4)
        for x in 0..<dw {
            let f = min(max((Float(x) + 0.5) * 比x - 0.5, 0), Float(sw - 1))
            let i0 = Int(f)
            var 和: Float = 0
            for k in 0..<4 {
                let 权 = 核(Float(k - 1) - (f - Float(i0)))
                权x[x * 4 + k] = 权
                索x[x * 4 + k] = min(max(i0 + k - 1, 0), sw - 1)
                和 += 权
            }
            // clamp 会让 4 个 tap 重复取到边缘像素，权重和不再是 1 —— 归一化回来
            if abs(和) > 1e-6 { for k in 0..<4 { 权x[x * 4 + k] /= 和 } }
        }
        for y in 0..<sh {
            let 行 = y * sw * 4
            for x in 0..<dw {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for k in 0..<4 {
                    let s = 行 + 索x[x * 4 + k] * 4
                    let 权 = 权x[x * 4 + k]
                    r += Float(入[s]) * 权
                    g += Float(入[s + 1]) * 权
                    b += Float(入[s + 2]) * 权
                }
                let 目 = (y * dw + x) * 3
                横[目] = r
                横[目 + 1] = g
                横[目 + 2] = b
            }
        }

        // ② 纵向：sh → dh，直接写回 8 位 RGB（alpha 恒 255）
        var 出 = [UInt8](repeating: 255, count: dw * dh * 4)
        let 比y = Float(sh) / Float(dh)
        for y in 0..<dh {
            let f = min(max((Float(y) + 0.5) * 比y - 0.5, 0), Float(sh - 1))
            let i0 = Int(f)
            var 权 = [Float](repeating: 0, count: 4)
            var 索 = [Int](repeating: 0, count: 4)
            var 和: Float = 0
            for k in 0..<4 {
                权[k] = 核(Float(k - 1) - (f - Float(i0)))
                索[k] = min(max(i0 + k - 1, 0), sh - 1)
                和 += 权[k]
            }
            if abs(和) > 1e-6 { for k in 0..<4 { 权[k] /= 和 } }
            for x in 0..<dw {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for k in 0..<4 {
                    let s = (索[k] * dw + x) * 3
                    let w = 权[k]
                    r += 横[s] * w
                    g += 横[s + 1] * w
                    b += 横[s + 2] * w
                }
                let 目 = (y * dw + x) * 4
                出[目] = 通道(r)
                出[目 + 1] = 通道(g)
                出[目 + 2] = 通道(b)
            }
        }
        return 出
    }

    /// 三次卷积核（Keys, a = -0.5；Pillow `Image.BICUBIC` 用的就是这一支）
    private static func 核(_ t: Float) -> Float {
        let x = abs(t)
        if x <= 1 { return 1 - 2.5 * x * x + 1.5 * x * x * x }
        if x < 2 { return 2 - 4 * x + 2.5 * x * x - 0.5 * x * x * x }
        return 0
    }

    /// Float 通道 → 0~255（四舍五入 + clamp）
    private static func 通道(_ v: Float) -> UInt8 {
        if v <= 0 { return 0 }
        if v >= 255 { return 255 }
        return UInt8(v + 0.5)
    }

    /// RGBA 字节 → CGImage。
    ///
    /// ⚠️ 和 `推脸.由像素` 一样：让 CGContext **自己分配**内存再 memcpy 进去。
    ///    把局部数组指针交给 CGContext 再 makeImage() 会得到悬垂内存（v13 闪退根因）。
    private static func 彩色图(_ buf: [UInt8], 宽: Int, 高: Int) -> CGImage? {
        guard 宽 > 0, 高 > 0, buf.count >= 宽 * 高 * 4 else { return nil }
        guard let 布 = CGContext(data: nil, width: 宽, height: 高, bitsPerComponent: 8,
                                bytesPerRow: 宽 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let 目标 = 布.data else { return nil }
        buf.withUnsafeBytes { raw in
            if let 源 = raw.baseAddress, raw.count >= 宽 * 高 * 4 { memcpy(目标, 源, 宽 * 高 * 4) }
        }
        return 布.makeImage()
    }

    /// CGImage → 32BGRA 的 CVPixelBuffer（Core ML ImageType 的标准入口）
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
        布.interpolationQuality = .high
        布.draw(图, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
        return 缓
    }

    /// CGImage → (宽, 高, RGBA 字节)。自己分配 buf，不碰局部数组指针的悬垂问题。
    private static func 读像素(_ cg: CGImage) -> (宽: Int, 高: Int, 像素: [UInt8])? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let 成功: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let 布 = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            布.interpolationQuality = .high
            布.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return 成功 ? (w, h, buf) : nil
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

    /// 灰度 CGImage → 0~1 浮点（R 通道 = 白度，与 `推脸.准备()` 读遮罩的方式一致）
    private static func 从灰度(_ cg: CGImage) -> [Float]? {
        guard let (w, h, 像素) = 读像素(cg) else { return nil }
        let n = w * h
        var 出 = [Float](repeating: 0, count: n)
        for i in 0..<n { 出[i] = Float(像素[i * 4]) / 255.0 }
        return 出
    }

    /// 单通道浮点等比缩放（像素中心对齐的双线性；不引入 ringing，见 跑遮罩 ③）
    private static func 缩放浮点(_ 入: [Float], 从宽 sw: Int, 从高 sh: Int,
                              到宽 dw: Int, 到高 dh: Int) -> [Float] {
        guard sw > 0, sh > 0, dw > 0, dh > 0, 入.count >= sw * sh else { return [] }
        if sw == dw && sh == dh { return 入 }
        var 出 = [Float](repeating: 0, count: dw * dh)
        let 比x = Float(sw) / Float(dw)
        let 比y = Float(sh) / Float(dh)
        let 宽末 = Float(sw - 1), 高末 = Float(sh - 1)
        for y in 0..<dh {
            let fy = min(max((Float(y) + 0.5) * 比y - 0.5, 0), 高末)
            let y0 = Int(fy)
            let y1 = min(y0 + 1, sh - 1)
            let ty = fy - Float(y0)
            let 行0 = y0 * sw, 行1 = y1 * sw
            for x in 0..<dw {
                let fx = min(max((Float(x) + 0.5) * 比x - 0.5, 0), 宽末)
                let x0 = Int(fx)
                let x1 = min(x0 + 1, sw - 1)
                let tx = fx - Float(x0)
                let a = 入[行0 + x0] * (1 - tx) + 入[行0 + x1] * tx
                let b = 入[行1 + x0] * (1 - tx) + 入[行1 + x1] * tx
                出[y * dw + x] = a * (1 - ty) + b * ty
            }
        }
        return 出
    }
}
