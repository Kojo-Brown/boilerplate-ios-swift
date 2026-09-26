import Foundation
import os

// MARK: - Events

/// Something the integrity pass concluded or did.
package enum IntegrityEvent: Hashable, Sendable {

    /// A pass completed. Carries the whole report, because the fired signals
    /// without the unassessable ones are half a sentence.
    case evaluated(IntegrityReport)

    /// A mitigation was applied. Named separately from `.evaluated` so that the
    /// log says what changed rather than leaving a reader to re-derive it from
    /// the policy, which is not in the log.
    case withheldBiometricUnlockRecord(posture: IntegrityPosture)
}

/// Where integrity events go.
package protocol IntegrityReporting: Sendable {
    func report(_ event: IntegrityEvent)
}

// MARK: - The unified log

/// The default: the unified log, under the app's own subsystem.
///
/// Levels are chosen so that the interesting case is the one that survives. A
/// pass with no signals is `.debug` and is gone by default; a pass with signals
/// is `.notice` or `.error` and is in the log the moment somebody asks for it,
/// which is the only time anybody ever looks.
///
/// The artefact paths are logged as public values, and that is deliberate. They
/// are observations about the device, not the person: `/var/jb` names a jailbreak
/// family and nothing else. Redacting them would leave a report that says a
/// heuristic fired and cannot say which of twenty paths did it — which is a
/// report nobody can act on, and the reason the evidence is carried at all.
package struct OSLogIntegrityReporter: IntegrityReporting {
    private let logger: Logger

    package init(subsystem: String) {
        logger = Logger(subsystem: subsystem, category: "device-integrity")
    }

    package func report(_ event: IntegrityEvent) {
        switch event {
        case .evaluated(let report):
            log(report)
        case .withheldBiometricUnlockRecord(let posture):
            // One literal, one line. `OSLogMessage` is not an ordinary string —
            // the format has to be statically analysable — so the message is not
            // assembled and not wrapped.
            let reason = posture.description
            logger.notice("Withholding the biometric unlock record (\(reason, privacy: .public))")
        }
    }

    private func log(_ report: IntegrityReport) {
        guard report.posture > .noSignals else {
            logger.debug("Device integrity: \(report.digest, privacy: .public)")
            return
        }
        logger.error("Device integrity: \(report.digest, privacy: .public)")
        for signal in report.firedInOrder {
            guard let paths = report.evidence[signal], !paths.isEmpty else { continue }
            let joined = paths.joined(separator: " ")
            logger.error("  \(signal.rawValue, privacy: .public): \(joined, privacy: .public)")
        }
    }
}

// MARK: - The double

/// A reporter that keeps what it was told, for tests and previews.
package final class RecordingIntegrityReporter: IntegrityReporting {
    private let state = OSAllocatedUnfairLock(initialState: [IntegrityEvent]())

    package init() {}

    /// Everything reported so far, in order.
    package var events: [IntegrityEvent] { state.withLock { $0 } }

    /// The reports from every `.evaluated` event, in order.
    package var reports: [IntegrityReport] {
        events.compactMap { event -> IntegrityReport? in
            guard case .evaluated(let report) = event else { return nil }
            return report
        }
    }

    package func report(_ event: IntegrityEvent) {
        state.withLock { $0.append(event) }
    }
}
