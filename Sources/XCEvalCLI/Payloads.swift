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
        path = artifact.sourceDescription
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
        path = artifact.sourceDescription
        evaluationID = artifact.evaluationID
        resultID = artifact.resultID
    }
}

struct ArtifactListItem: Encodable {
    let path: String
    let evaluationID: String?
    let resultID: String?
    let sampleCount: Int
    let summaryMetricCount: Int
    let startTime: String?
    let durationInMilliseconds: Double?

    init(_ artifact: EvaluationArtifact) {
        path = artifact.sourceDescription
        evaluationID = artifact.evaluationID
        resultID = artifact.resultID
        sampleCount = artifact.samples.count
        summaryMetricCount = artifact.summaries.count
        startTime = artifact.startTime
        durationInMilliseconds = artifact.durationInMilliseconds
    }
}

struct ListPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "list"
    let count: Int
    let artifacts: [ArtifactListItem]

    init(artifacts: [EvaluationArtifact]) {
        count = artifacts.count
        self.artifacts = artifacts.map(ArtifactListItem.init)
    }
}

struct ArtifactValidationPayload: Encodable {
    let artifact: ArtifactIdentity
    let valid: Bool
    let errorCount: Int
    let warningCount: Int
    let issues: [EvaluationValidationIssue]

    init(_ artifact: EvaluationArtifact) {
        let report = artifact.validate()
        self.artifact = ArtifactIdentity(artifact)
        valid = report.isValid
        errorCount = report.errorCount
        warningCount = report.warningCount
        issues = report.issues
    }
}

struct ValidationPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "validate"
    let valid: Bool
    let errorCount: Int
    let warningCount: Int
    let artifacts: [ArtifactValidationPayload]
    let loadError: String?

    init(artifacts: [EvaluationArtifact]) {
        let payloads = artifacts.map(ArtifactValidationPayload.init)
        self.artifacts = payloads
        valid = payloads.allSatisfy(\.valid)
        errorCount = payloads.reduce(0) { $0 + $1.errorCount }
        warningCount = payloads.reduce(0) { $0 + $1.warningCount }
        loadError = nil
    }

    init(loadError: String) {
        artifacts = []
        valid = false
        errorCount = 1
        warningCount = 0
        self.loadError = loadError
    }
}

struct MetricsPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "metrics"
    let artifact: ArtifactIdentity
    let profiles: [EvaluationMetricProfile]
    let summary: [EvaluationSummaryMetric]

    init(artifact: EvaluationArtifact) {
        self.artifact = ArtifactIdentity(artifact)
        profiles = artifact.metricProfiles
        summary = artifact.summaries
    }
}

struct DatasetPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "dataset"
    let artifact: ArtifactIdentity
    let rowCount: Int
    let pairCount: Int
    let records: [EvaluationDatasetRecord]

    init(artifact: EvaluationArtifact) {
        self.artifact = ArtifactIdentity(artifact)
        rowCount = artifact.datasetRecords.count
        pairCount = artifact.datasetPairs.count
        records = artifact.datasetRecords
    }
}

struct DatasetLinePayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let evaluationID: String?
    let resultID: String?
    let record: EvaluationDatasetRecord
}

struct GatePayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "gate"
    let artifact: ArtifactIdentity
    let passed: Bool
    let rules: [EvaluationGateResult]

    init(
        artifact: EvaluationArtifact,
        results: [EvaluationGateResult]
    ) {
        self.artifact = ArtifactIdentity(artifact)
        passed = results.allSatisfy(\.passed)
        rules = results
    }
}

struct ConvertPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "convert"
    let inputPath: String
    let format: String
    let artifactCount: Int
    let outputPath: String
    let writtenFiles: [String]
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

struct ProcessPayload: Encodable {
    let status: Int32
    let standardOutput: String
    let standardError: String

    init(_ result: ProcessResult) {
        status = result.status
        standardOutput = result.standardOutputString
        standardError = result.standardErrorString
    }
}

struct RunPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "run"
    let producerCommand: [String]
    let workingDirectory: String?
    let resultsPath: String
    let process: ProcessPayload
    let artifacts: [ArtifactListItem]

    init(
        producerCommand: [String],
        workingDirectory: String?,
        resultsPath: String,
        process: ProcessResult,
        artifacts: [EvaluationArtifact]
    ) {
        self.producerCommand = producerCommand
        self.workingDirectory = workingDirectory
        self.resultsPath = resultsPath
        self.process = ProcessPayload(process)
        self.artifacts = artifacts.map(ArtifactListItem.init)
    }
}

struct TestPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "test"
    let xcodebuildArguments: [String]
    let workingDirectory: String?
    let resultBundlePath: String
    let outputDirectory: String
    let xcode: XcodeInstallation
    let process: ProcessPayload
    let exportedFiles: [String]
    let manifest: JSONValue?
    let exportError: String?

    init(
        xcodebuildArguments: [String],
        workingDirectory: String?,
        resultBundlePath: String,
        outputDirectory: String,
        xcode: XcodeInstallation,
        process: ProcessResult,
        exportedFiles: [String],
        manifest: JSONValue?,
        exportError: String?
    ) {
        self.xcodebuildArguments = xcodebuildArguments
        self.workingDirectory = workingDirectory
        self.resultBundlePath = resultBundlePath
        self.outputDirectory = outputDirectory
        self.xcode = xcode
        self.process = ProcessPayload(process)
        self.exportedFiles = exportedFiles
        self.manifest = manifest
        self.exportError = exportError
    }
}
