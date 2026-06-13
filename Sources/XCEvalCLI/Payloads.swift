import Foundation
import XCEvalCore

struct ArtifactPayload: Encodable {
    let path: String
    let evaluationID: String?
    let resultID: String?
    let startTime: String?
    let endTime: String?
    let durationInMilliseconds: Double?
    let sampleCount: Int
    let info: [String: JSONValue]
    let reportMetadata: [String: JSONValue]
    let otherFields: [String: JSONValue]
    let summary: [EvaluationSummaryMetric]
    let samples: [EvaluationSample]?

    init(artifact: EvaluationArtifact, includeSamples: Bool) {
        path = artifact.sourceURL.path
        evaluationID = artifact.evaluationID
        resultID = artifact.resultID
        startTime = artifact.startTime
        endTime = artifact.endTime
        durationInMilliseconds = artifact.durationInMilliseconds
        sampleCount = artifact.samples.count
        info = artifact.evaluationInfo
        reportMetadata = artifact.reportMetadata
        otherFields = artifact.otherTopLevelFields
        summary = artifact.summaries
        samples = includeSamples ? artifact.samples : nil
    }
}

struct InspectPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "inspect"
    let artifact: ArtifactPayload
}

struct SamplesPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "samples"
    let path: String
    let evaluationID: String?
    let resultID: String?
    let sampleCount: Int
    let samples: [EvaluationSample]
}

struct SampleLinePayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let evaluationID: String?
    let resultID: String?
    let sample: EvaluationSample
}

struct ArtifactIdentity: Encodable {
    let path: String
    let evaluationID: String?
    let resultID: String?

    init(_ artifact: EvaluationArtifact) {
        path = artifact.sourceURL.path
        evaluationID = artifact.evaluationID
        resultID = artifact.resultID
    }
}

struct ComparePayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "compare"
    let baseline: ArtifactIdentity
    let candidate: ArtifactIdentity
    let metrics: [EvaluationMetricComparison]
}

struct ExportPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "export"
    let xcresultPath: String
    let outputDirectory: String
    let xcode: XcodeInstallation
    let onlyFailures: Bool
    let testID: String?
    let exportedFiles: [String]
    let manifest: JSONValue?
}

struct DoctorPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "doctor"
    let artifactInspectionAvailable = true
    let evaluationExportAvailable: Bool
    let selectedXcode: XcodeInstallation?
    let discoveredXcodes: [XcodeInstallation]
    let operatingSystem: String
}
