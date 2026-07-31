import Foundation
import XCEvalCore

/// Validates every replacement target before a caller removes any of them.
///
/// This is a topology preflight, not a filesystem transaction. Callers still
/// have a same-host time-of-check/time-of-use window before their mutation.
func validateForcedReplacement(
    targets: [URL],
    protecting protectedPaths: [URL] = [],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    allowsHomeDirectoryAsRoot: Bool = false
) throws {
    for (index, target) in targets.enumerated() {
        let otherTargets = targets.enumerated().compactMap {
            $0.offset == index ? nil : $0.element
        }
        try DestructivePathPolicy(
            allowedRoot: target.deletingLastPathComponent(),
            protectedPaths: protectedPaths + otherTargets,
            homeDirectory: homeDirectory,
            allowsHomeDirectoryAsRoot: allowsHomeDirectoryAsRoot
        ).validate(targets: [target])
    }
}
