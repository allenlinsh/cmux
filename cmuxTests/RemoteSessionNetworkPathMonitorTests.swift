import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Coverage for the macOS network-path re-arm that recovers suspended SSH
// remote workspaces after a network switch or sleep/wake, complementing the
// suspend policy from https://github.com/manaflow-ai/cmux/issues/5734.
@Suite("Remote session network path monitor")
struct RemoteSessionNetworkPathMonitorTests {
    private typealias Monitor = RemoteSessionNetworkPathMonitor

    // MARK: - Path signature

    @Test("Signature is order-insensitive over interfaces, gateways, and addresses")
    func signatureIsOrderInsensitive() {
        let a = Monitor.signature(
            status: "satisfied",
            interfaceNames: ["en0", "utun4"],
            gateways: ["192.168.1.1", "fe80::1"],
            localAddresses: ["192.168.1.42", "100.64.0.7"]
        )
        let b = Monitor.signature(
            status: "satisfied",
            interfaceNames: ["utun4", "en0"],
            gateways: ["fe80::1", "192.168.1.1"],
            localAddresses: ["100.64.0.7", "192.168.1.42"]
        )
        #expect(a == b)
    }

    @Test("Signature changes when the network changes")
    func signatureChangesAcrossNetworks() {
        let home = Monitor.signature(
            status: "satisfied",
            interfaceNames: ["en0"],
            gateways: ["192.168.1.1"],
            localAddresses: ["192.168.1.42"]
        )
        let office = Monitor.signature(
            status: "satisfied",
            interfaceNames: ["en0"],
            gateways: ["10.0.0.1"],
            localAddresses: ["10.0.0.9"]
        )
        #expect(home != office)
    }

    @Test("Satisfied and unsatisfied paths never share a signature")
    func signatureDistinguishesStatus() {
        let up = Monitor.signature(
            status: "satisfied", interfaceNames: ["en0"], gateways: ["192.168.1.1"], localAddresses: ["192.168.1.42"]
        )
        let down = Monitor.signature(
            status: "unsatisfied", interfaceNames: ["en0"], gateways: ["192.168.1.1"], localAddresses: ["192.168.1.42"]
        )
        #expect(up != down)
    }

    // MARK: - Re-arm decision

    private func decision(
        previous: Monitor.Observation?,
        isSatisfied: Bool,
        signature: String,
        secondsSinceLastReArm: TimeInterval? = nil,
        coalesceWindow: TimeInterval = 1.5
    ) -> Monitor.ReArmDecision {
        Monitor.reArmDecision(
            previous: previous,
            isSatisfied: isSatisfied,
            signature: signature,
            secondsSinceLastReArm: secondsSinceLastReArm,
            coalesceWindow: coalesceWindow
        )
    }

    @Test("An unusable path never re-arms")
    func unsatisfiedPathIgnored() {
        #expect(decision(previous: nil, isSatisfied: false, signature: "unsatisfied|||") == .ignore)
        #expect(decision(
            previous: Monitor.Observation(isSatisfied: true, signature: "satisfied|en0|g|a"),
            isSatisfied: false,
            signature: "unsatisfied|||"
        ) == .ignore)
    }

    @Test("The first usable observation is a silent baseline, not a re-arm")
    func firstUsableObservationIsBaseline() {
        #expect(decision(previous: nil, isSatisfied: true, signature: "satisfied|en0|g|a") == .baseline)
    }

    @Test("A duplicate of the same usable path does not re-arm")
    func duplicateUsablePathIgnored() {
        let sig = "satisfied|en0|192.168.1.1|192.168.1.42"
        #expect(decision(
            previous: Monitor.Observation(isSatisfied: true, signature: sig),
            isSatisfied: true,
            signature: sig
        ) == .ignore)
    }

    @Test("A changed usable network re-arms")
    func changedUsableNetworkReArms() {
        #expect(decision(
            previous: Monitor.Observation(isSatisfied: true, signature: "satisfied|en0|192.168.1.1|192.168.1.42"),
            isSatisfied: true,
            signature: "satisfied|en0|10.0.0.1|10.0.0.9"
        ) == .reArm)
    }

    @Test("Coming back online re-arms even on the same network signature")
    func returningOnlineReArmsOnSameSignature() {
        let sig = "satisfied|en0|192.168.1.1|192.168.1.42"
        #expect(decision(
            previous: Monitor.Observation(isSatisfied: false, signature: sig),
            isSatisfied: true,
            signature: sig
        ) == .reArm)
    }

    @Test("A qualifying transition inside the coalesce window is throttled")
    func transitionWithinWindowThrottled() {
        #expect(decision(
            previous: Monitor.Observation(isSatisfied: true, signature: "satisfied|en0|192.168.1.1|192.168.1.42"),
            isSatisfied: true,
            signature: "satisfied|en0|10.0.0.1|10.0.0.9",
            secondsSinceLastReArm: 0.4,
            coalesceWindow: 1.5
        ) == .throttled)
    }

    @Test("A transition after the coalesce window re-arms again")
    func transitionAfterWindowReArms() {
        #expect(decision(
            previous: Monitor.Observation(isSatisfied: true, signature: "satisfied|en0|192.168.1.1|192.168.1.42"),
            isSatisfied: true,
            signature: "satisfied|en0|10.0.0.1|10.0.0.9",
            secondsSinceLastReArm: 2.0,
            coalesceWindow: 1.5
        ) == .reArm)
    }
}
