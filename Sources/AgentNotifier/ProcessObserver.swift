import Foundation
import Combine

/// 进程旁路观测：后台采样，主线程发布。只读，不启动、不暂停、不结束任何进程。
final class ProcessObserver: ObservableObject {
    static let shared = ProcessObserver()

    @Published private(set) var attachments: [String: ProcessAttachment] = [:]
    @Published private(set) var lastSample: Date?
    @Published private(set) var sampleDuration: TimeInterval = 0
    @Published private(set) var processCount = 0
    @Published private(set) var groupCount = 0
    @Published private(set) var enabled = false

    private let queue = DispatchQueue(label: "AgentNotifier.process", qos: .utility)
    private let sampler = ProcessSampler()
    private var timer: DispatchSourceTimer?
    private var provider: (() -> [TaskRecord])?
    private var inFlight = false
    private var lastDispatch = Date.distantPast
    private var generation = 0

    private init() {}

    func start(tasks: @escaping () -> [TaskRecord]) {
        provider = tasks
        setEnabled(MonitorPreferences.shared.value.observeProcesses)
    }

    func setEnabled(_ want: Bool) {
        guard want != enabled else { return }
        enabled = want
        generation += 1
        if want {
            startTimer()
            tick(force: true)
        } else {
            stopTimer()
            attachments = [:]
            processCount = 0
            groupCount = 0
            lastSample = nil
            sampleDuration = 0
        }
    }

    func stop() {
        enabled = false
        generation += 1
        stopTimer()
        provider = nil
        attachments = [:]
    }

    /// 主循环调用；内部按 4.5 秒节流，避免 3 秒轮询放大采样次数。
    func refreshIfNeeded() {
        guard enabled else { return }
        tick(force: false)
    }

    private func startTimer() {
        stopTimer()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.5, repeating: 5, leeway: .milliseconds(400))
        source.setEventHandler { [weak self] in self?.tick(force: false) }
        source.resume()
        timer = source
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick(force: Bool) {
        guard enabled, !inFlight, let provider else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastDispatch) >= 4.5 else { return }

        let tasks = provider()
        // 没有任务时没有归属对象，不做整表采样；新任务出现后立即恢复。
        guard !tasks.isEmpty else {
            if !attachments.isEmpty {
                attachments = [:]
                processCount = 0
                groupCount = 0
            }
            return
        }
        let active = tasks.contains { task in
            [.running, .approval, .input, .suspected, .stalled].contains(task.phase)
        }
        if !active, let lastSample, now.timeIntervalSince(lastSample) < 15 { return }

        inFlight = true
        lastDispatch = now
        let generation = generation
        queue.async { [weak self] in
            guard let self else { return }
            let sample = self.sampler.sample(now: now)
            let sessions = ClaudeSessionRegistry.load()
            let attachments = ProcessAttribution.resolve(tasks: tasks, groups: sample.groups, claudeSessions: sessions)
            DispatchQueue.main.async {
                self.inFlight = false
                guard self.enabled, self.generation == generation else { return }
                self.attachments = attachments
                self.lastSample = sample.sampledAt
                self.sampleDuration = sample.duration
                self.processCount = sample.processes.count
                self.groupCount = sample.groups.count
            }
        }
    }
}
