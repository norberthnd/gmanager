import Foundation

/// Caps concurrent requests to one site and applies a shared cool-down after
/// the server signals overload, so every in-flight task backs off together.
public actor RequestLimiter {
    public private(set) var maxConcurrent: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var coolDownUntil: ContinuousClock.Instant?

    public init(maxConcurrent: Int = 3) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public func setMaxConcurrent(_ value: Int) {
        maxConcurrent = max(1, value)
        resumeWaiters()
    }

    /// Waits for a free slot and for any active cool-down to pass.
    func acquire() async {
        if inFlight >= maxConcurrent {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            inFlight += 1
        }
        while let until = coolDownUntil, until > .now {
            try? await Task.sleep(until: until, clock: .continuous)
        }
    }

    func release() {
        inFlight -= 1
        resumeWaiters()
    }

    /// Delays every request that starts within `duration` from now.
    func coolDown(for duration: Duration) {
        let until = ContinuousClock.now.advanced(by: duration)
        if coolDownUntil.map({ until > $0 }) ?? true {
            coolDownUntil = until
        }
    }

    private func resumeWaiters() {
        while inFlight < maxConcurrent, !waiters.isEmpty {
            inFlight += 1
            waiters.removeFirst().resume()
        }
    }
}

public struct RetryPolicy: Sendable {
    /// Total attempts including the first one.
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration

    public init(maxAttempts: Int = 4, baseDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(30)) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let none = RetryPolicy(maxAttempts: 1)

    /// Exponential backoff with jitter for the given 1-based retry number.
    func delay(forRetry retry: Int) -> Duration {
        let exponential = baseDelay * (1 << min(retry - 1, 10))
        let capped = min(exponential, maxDelay)
        return capped * Double.random(in: 0.5...1.0)
    }
}
