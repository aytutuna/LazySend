#if os(macOS)
import Foundation
import LazySendKit
import LazySendServer

/// Connecting this Mac to another computer: the computers nearby to pick from and the code its screen shows, or
/// its pasted link. With a code, the six digits worked out here are shown first and the code goes out only once
/// the user says the other screen shows the same; then the other computer's user is asked too.
@MainActor
public final class ConnectModel: ObservableObject {
    public enum Step: Equatable {
        case entering
        /// The digits are to be compared with the other computer's screen before the code is sent.
        case comparing(String)
        /// Waiting for the other computer's user; `digits` is what its screen should show.
        case waiting(digits: String)
        case connected(String)
    }

    @Published public private(set) var nearby: [NearbyHost] = []
    @Published public private(set) var looking = false
    @Published public private(set) var step = Step.entering
    @Published public private(set) var message = ""
    @Published public var selected: String?
    @Published public var input = ""

    public var onPaired: ((PairedPc) -> Void)?

    private let guest: GuestService
    private let ownId: String
    private let find: () async -> [NearbyHost]
    private var pairing: Task<Void, Never>?
    private var comparison: CheckedContinuation<Bool, Never>?

    init(guest: GuestService, ownId: String, find: @escaping () async -> [NearbyHost] = { Array(await ServiceBrowser.find(seconds: 3).values) }) {
        self.guest = guest
        self.ownId = ownId
        self.find = find
    }

    public var busy: Bool { step != .entering }

    /// The other computers running Lazy Send on the network, this one left out.
    public func look() async {
        looking = true
        let found = await find()
        nearby = found.filter { $0.id != ownId && isValidId($0.id) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if selected == nil || !nearby.contains(where: { $0.id == selected }) { selected = nearby.count == 1 ? nearby.first?.id : nil }
        looking = false
    }

    public func connect() {
        guard !busy else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        message = ""
        if text.lowercased().hasPrefix("lazysend:") {
            let code: PairingCode
            do {
                code = try PairingCode.parse(text)
            } catch {
                message = error.localizedDescription
                return
            }
            step = .waiting(digits: code.checkCode)
            run { [guest] in try await guest.pair(code) }
        } else if let host = nearby.first(where: { $0.id == selected }) {
            guard ShortCode.normalize(text) != nil else {
                message = "The code is 8 letters and digits, like 7KQ2-M9XD."
                return
            }
            run { [guest] in
                try await guest.pair(host: host, code: text) { digits in await self.compare(digits) }
            }
        } else {
            message = "Choose the computer above, or paste its link."
        }
    }

    private func run(_ pair: @escaping () async throws -> PairedPc) {
        pairing = Task { [weak self] in
            do {
                let pc = try await pair()
                self?.step = .connected(pc.name)
                self?.onPaired?(pc)
            } catch is CancellationError {
                self?.reset("")
            } catch {
                self?.reset(error.localizedDescription)
            }
        }
    }

    private func reset(_ text: String) {
        step = .entering
        message = text
    }

    /// Shows the digits and waits for the user's answer; the code is sent only on yes.
    private func compare(_ digits: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            comparison = continuation
            step = .comparing(digits)
        }
    }

    public func answer(matches: Bool) {
        guard case .comparing(let digits) = step, let waiting = comparison else { return }
        comparison = nil
        step = matches ? .waiting(digits: digits) : .entering
        waiting.resume(returning: matches)
    }

    /// Ends whatever is under way; the window is closing or the user gave up.
    public func cancel() {
        pairing?.cancel()
        pairing = nil
        if let waiting = comparison {
            comparison = nil
            waiting.resume(returning: false)
        }
    }
}
#endif
