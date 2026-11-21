import Foundation

/// 崩溃定位器。
///
/// 为什么需要：
///   推脸 / AI 超清 两个页面在选完图后偶发闪退，而我们**拿不到崩溃日志**
///   （自签名安装，没有 Xcode 组织者，也没有第三方崩溃收集）。
///   EXC_BAD_ACCESS 这类崩溃无法用 do/catch 捕获，进程直接死。
///
/// 做法：
///   在关键步骤**之前**把"即将做什么"写进 UserDefaults。崩溃后 App 被系统杀掉，
///   但 UserDefaults 已经落盘；下次启动在首页显示"上次停在：xxx"，
///   就能把范围缩到某一步，而不是靠猜。
///
/// 代价：每次写一个字符串，微秒级，可以忽略。
enum 诊断 {
    private static let 键 = "诊断.最后步骤"
    private static let 时键 = "诊断.最后时间"

    static func 记(_ 步骤: String) {
        UserDefaults.standard.set(步骤, forKey: 键)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: 时键)
    }

    /// 上次停在的步骤；成功走完一遍后应调用 `清()`
    static func 上次() -> String? {
        guard let s = UserDefaults.standard.string(forKey: 键), !s.isEmpty else { return nil }
        return s
    }

    static func 清() {
        UserDefaults.standard.removeObject(forKey: 键)
        UserDefaults.standard.removeObject(forKey: 时键)
    }
}
