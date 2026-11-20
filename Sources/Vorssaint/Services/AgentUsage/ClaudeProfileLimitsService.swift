// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

struct ClaudeProfileLimitsState: Equatable, Identifiable {
    var account: ClaudeMonitoredAccount
    var limits: AgentLimits?
    var plan: AgentPlan?
    var identity: ClaudeAccountProfile.Identity?
    var failure: AgentClaudeServer.Failure?
    var checking = false
    var attempted: Date?
    var failures = 0
    var id: String { account.id }

    static func readings(primary: ClaudeMonitoredAccount?, limits: AgentLimits?, additional: [Self],
                         home: URL) -> [String: AgentLimits] {
        var readings: [String: AgentLimits] = [:]
        if let primary {
            readings[AgentLogRoot.canonical(primary.profile.configurationURL(home: home)).path] = limits
        }
        for state in additional {
            readings[AgentLogRoot.canonical(state.account.profile.configurationURL(home: home)).path] = state.limits
        }
        return readings
    }

    func isDue(at now: Date) -> Bool {
        attempted.map { now.timeIntervalSince($0) >= AgentClaudeServer.interval(after: failure,
            repeated: failures, pageVisible: true) } ?? true
    }
}

/// Additional profiles are checked serially while the AI page shows limits.
/// The first profile retains the existing background limits and alert behavior.
final class ClaudeProfileLimitsService: ObservableObject {
    struct Check {
        var metadata: ClaudeAccountProfile.Reading
        var result: Result<AgentClaudeServer.Summary, AgentClaudeServer.Failure>
    }
    typealias Reader = (ClaudeAccountProfile, AgentClaudeServer.Request) -> Check
    static let shared = ClaudeProfileLimitsService()
    @Published private(set) var states: [ClaudeProfileLimitsState] = []
    private(set) var timer: Timer?
    private let defaults: UserDefaults
    private let home: URL
    private let reader: Reader
    private final class MetadataToken {
        private let lock = NSLock()
        private var value = 0
        var current: Int { lock.withLock { value } }
        func advance() { lock.withLock { value += 1 } }
    }
    private let queue = DispatchQueue(label: "com.vorssaint.claude-profile-limits", qos: .utility)
    private let profileQueue = DispatchQueue(label: "com.vorssaint.claude-profile-metadata", qos: .utility)
    private var profiled: Set<String> = []
    private let profileToken = MetadataToken()
    private var profileRequest: [String: Int] = [:]
    private var metadataVersion: [String: Int] = [:]
    private var running: (id: String, request: AgentClaudeServer.Request)?
    private var waiting: [(id: String, asked: Bool)] = []
    private var visible = false
    private var online = true

    init(defaults: UserDefaults = .standard,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         reader: @escaping Reader = ClaudeProfileLimitsService.read) {
        self.defaults = defaults
        self.home = home
        self.reader = reader
    }

    var readsMetadata: Bool {
        NotchAgentSupport.isEnabled(in: defaults) && NotchAgentSupport.providers(in: defaults).contains(.claude)
    }

    var isEnabled: Bool {
        readsMetadata && !NotchAgentSupport.hiddenCards(in: defaults).contains(.limits)
    }

    func synchronize() {
        if !isEnabled { cancelChecks() }
        let wanted = Array(ClaudeMonitoredAccount.configured(in: defaults).dropFirst())
        if states.map(\.account) != wanted {
            states = wanted.map { account in
                var state = states.first { $0.id == account.id } ?? ClaudeProfileLimitsState(account: account)
                state.account = account
                return state
            }
            let ids = Set(states.map(\.id))
            profiled.formIntersection(ids)
            profileRequest = profileRequest.filter { ids.contains($0.key) }
            metadataVersion = metadataVersion.filter { ids.contains($0.key) }
            waiting.removeAll { item in !states.contains { $0.id == item.id } }
            if let running, !states.contains(where: { $0.id == running.id }) {
                running.request.cancel()
                self.running = nil
                startNext()
            }
        }
        if readsMetadata {
            readProfiles(force: visible)
        } else {
            profileToken.advance()
            profiled.removeAll()
        }
        syncTimer()
        refresh()
    }

    /// Reads profile metadata for listed accounts on a separate queue so
    /// Settings, cards and the account menu show their email and plan before
    /// a CLI limits check runs, and refresh when a profile's login changes.
    func readProfiles(force: Bool = false) {
        guard force ? NotchAgentSupport.providers(in: defaults).contains(.claude) : readsMetadata else { return }
        let pending = states.filter { state in
            !state.checking && (force || !profiled.contains(state.id))
        }.map(\.account)
        guard !pending.isEmpty else { return }
        let token = profileToken
        let generation = token.current
        var requests: [String: Int] = [:]
        var versions: [String: Int] = [:]
        for account in pending {
            profileRequest[account.id, default: 0] += 1
            requests[account.id] = profileRequest[account.id]
            versions[account.id] = metadataVersion[account.id, default: 0]
        }
        let home = self.home
        profileQueue.async { [weak self] in
            var readings: [(String, ClaudeAccountProfile.Reading)] = []
            for account in pending {
                guard token.current == generation else { return }
                readings.append((account.id, account.profile.read(home: home)))
            }
            DispatchQueue.main.async {
                guard let self, self.profileToken.current == generation else { return }
                for (id, reading) in readings {
                    guard let index = self.states.firstIndex(where: { $0.id == id }),
                          !self.states[index].checking,
                          self.profileRequest[id] == requests[id],
                          self.metadataVersion[id, default: 0] == versions[id] else { continue }
                    self.profiled.insert(id)
                    let identityChanged = self.states[index].identity != reading.identity
                    self.states[index].identity = reading.identity
                    self.states[index].plan = reading.plan
                    if identityChanged {
                        self.states[index].limits = nil
                        self.states[index].failure = nil
                        self.states[index].failures = 0
                        self.states[index].attempted = nil
                        self.refresh(id: id)
                    }
                }
            }
        }
    }

    func pageDidAppear(preview: Bool = false) {
        if !preview { visible = true }
        synchronize()
        if preview && readsMetadata { readProfiles(force: true) }
    }

    func pageDidDisappear() {
        visible = false
        let dropped = Set(waiting.filter { !$0.asked }.map(\.id))
        waiting.removeAll { !$0.asked }
        for index in states.indices where dropped.contains(states[index].id) { states[index].checking = false }
        syncTimer()
    }

    func pause() {
        visible = false
        profileToken.advance()
        profiled.removeAll()
        cancelChecks()
        syncTimer()
    }

    func setOnline(_ value: Bool) {
        online = value
        if !value {
            cancelChecks()
            if visible && readsMetadata { readProfiles(force: true) }
        } else {
            for index in states.indices { states[index].failures = 0 }
        }
    }

    func refresh(id: String? = nil, force: Bool = false, now: Date = Date()) {
        guard isEnabled, online, visible || force else { return }
        for index in states.indices where id == nil || states[index].id == id {
            let state = states[index]
            if state.checking {
                if force, let place = waiting.firstIndex(where: { $0.id == state.id }) { waiting[place].asked = true }
                continue
            }
            guard force || state.isDue(at: now) else { continue }
            states[index].checking = true
            waiting.append((state.id, force))
        }
        startNext()
    }

    private func startNext() {
        guard running == nil, !waiting.isEmpty, isEnabled, online else { return }
        let next = waiting.removeFirst()
        guard let index = states.firstIndex(where: { $0.id == next.id }) else { return startNext() }
        let profile = states[index].account.profile
        states[index].attempted = Date()
        metadataVersion[next.id, default: 0] += 1
        let request = AgentClaudeServer.Request()
        running = (next.id, request)
        let read = reader
        queue.async { [weak self] in
            let check = read(profile, request)
            DispatchQueue.main.async {
                guard let self, self.running?.request === request else { return }
                self.running = nil
                self.metadataVersion[next.id, default: 0] += 1
                if let index = self.states.firstIndex(where: { $0.id == next.id }) {
                    self.profiled.insert(next.id)
                    var state = self.states[index]
                    state.checking = false
                    if state.identity != check.metadata.identity { state.limits = nil }
                    state.identity = check.metadata.identity
                    state.plan = check.metadata.plan
                    switch check.result {
                    case .success(let reading) where reading.identity == state.identity:
                        state.limits = reading.limits
                        state.failure = nil
                        state.failures = 0
                    case .success:
                        state.limits = nil
                        state.failure = .unreachable
                        state.failures += 1
                    case .failure(let failure):
                        if failure == .needsSignIn { state.limits = nil }
                        state.failure = failure
                        state.failures = failure == .unreachable ? state.failures + 1 : 0
                    }
                    self.states[index] = state
                }
                self.startNext()
            }
        }
    }

    private func cancelChecks() {
        running?.request.cancel()
        if let running, let index = states.firstIndex(where: { $0.id == running.id }) { states[index].attempted = nil }
        running = nil
        waiting.removeAll()
        for index in states.indices { states[index].checking = false }
    }

    private func syncTimer() {
        guard visible, isEnabled, !states.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func read(_ profile: ClaudeAccountProfile, _ request: AgentClaudeServer.Request) -> Check {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let result: Result<AgentClaudeServer.Summary, AgentClaudeServer.Failure>
        if let executable = AgentClaudeServer.executable(home: home, searchPath: ProcessInfo.processInfo.environment["PATH"]) {
            var environment = AgentCodexServer.environment(for: executable, searchPath: nil)
            environment["PATH"] = AgentClaudeServer.searchPath(after: environment["PATH"] ?? "", home: home)
            result = request.run(executable, home: home, environment: environment, profile: profile)
        } else { result = .failure(.missing) }
        return Check(metadata: profile.read(home: home), result: result)
    }
}
