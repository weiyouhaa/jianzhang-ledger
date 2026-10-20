import Foundation

/// 硬超时：operation 与计时器赛跑，先到者的结果被采用，续体只恢复一次。
/// 超时后立即返回（并取消 operation），不等待它结束 —— 与 withThrowingTaskGroup 不同，
/// 后者在退出时会隐式等待所有子任务，模型不响应取消时会把整个快捷指令拖到被系统终止。
enum HardTimeout {
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        private(set) var resumeCount = 0

        init(_ c: CheckedContinuation<T, Never>) { continuation = c }

        func resume(_ value: T) {
            lock.lock()
            let c = continuation
            continuation = nil
            if c != nil { resumeCount += 1 }
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    static func run<T: Sendable>(seconds: Double, onTimeout: @escaping @Sendable () -> T,
                                 operation: @escaping @Sendable () async -> T) async -> T {
        let work = Task.detached(priority: .userInitiated) { await operation() }
        let nanos = UInt64(max(0.01, seconds) * 1_000_000_000)
        return await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            let once = Once(c)
            Task.detached { once.resume(await work.value) }
            Task.detached {
                try? await Task.sleep(nanoseconds: nanos)
                once.resume(onTimeout())
                work.cancel()
            }
        }
    }
}
