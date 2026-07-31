import Foundation
import XCEvalCore
import XCEvalFormat

struct ArtifactIdentity: Codable, Equatable, Sendable {
    let path: String
    let artifactID: String
    let byteDigest: String
    let evaluationID: String?
    let resultID: String?

    init(_ artifact: EvaluationArtifact) {
        path = artifact.sourceDescription
        artifactID = artifact.artifactID
        byteDigest = artifact.byteDigest
        evaluationID = artifact.evaluationID
        resultID = artifact.resultID
    }
}

struct ArtifactListItem: Encodable {
    let path: String
    let artifactID: String
    let byteDigest: String
    let evaluationID: String?
    let resultID: String?
    let sampleCount: Int
    let summaryMetricCount: Int
    let startTime: String?
    let durationInMilliseconds: Double?

    init(_ artifact: EvaluationArtifact) {
        path = artifact.sourceDescription
        artifactID = artifact.artifactID
        byteDigest = artifact.byteDigest
        evaluationID = artifact.evaluationID
        resultID = artifact.resultID
        sampleCount = artifact.samples.count
        summaryMetricCount = artifact.summaries.count
        startTime = artifact.startTime
        durationInMilliseconds = artifact.durationInMilliseconds
    }

    init?(replaying output: OperationOutputArtifact) {
        guard
            let artifactID = output.artifactID,
            let byteDigest = output.byteDigest ?? output.contentDigest,
            let sampleCount = output.sampleCount,
            let summaryMetricCount = output.summaryMetricCount
        else {
            return nil
        }
        path = output.path
        self.artifactID = artifactID
        self.byteDigest = byteDigest
        evaluationID = output.evaluationID
        resultID = output.resultID
        self.sampleCount = sampleCount
        self.summaryMetricCount = summaryMetricCount
        startTime = output.startTime
        durationInMilliseconds = output.durationInMilliseconds
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

struct EvaluationSampleReportPayload: Encodable {
    let sample: EvaluationSample
    let failedMetrics: [String]
    let issues: [EvaluationValueDifference]

    init(sample: EvaluationSample) {
        self.sample = sample
        failedMetrics = sample.metrics.filter(\.failed).map(\.name)
        issues = sample.subjectExpectedDifferences
    }
}

struct ReportPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "report"
    let artifact: XCEvalArtifactDocument
    let profiles: [EvaluationMetricProfile]
    let samples: [EvaluationSampleReportPayload]
    let baseline: ArtifactIdentity?
    let aggregateComparison: [EvaluationMetricComparison]?

    init(
        artifact: EvaluationArtifact,
        baseline: EvaluationArtifact? = nil
    ) {
        self.artifact = XCEvalArtifactDocument(
            artifact: artifact,
            includeSamples: false
        )
        profiles = artifact.metricProfiles
        samples = artifact.samples.map(EvaluationSampleReportPayload.init)
        self.baseline = baseline.map(ArtifactIdentity.init)
        aggregateComparison = baseline?.comparisons(with: artifact)
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
    let baseline: ArtifactIdentity?
    let passed: Bool
    let rules: [EvaluationGateResult]
    let deltaRules: [EvaluationDeltaGateResult]

    init(
        artifact: EvaluationArtifact,
        results: [EvaluationGateResult],
        baseline: EvaluationArtifact? = nil,
        deltaResults: [EvaluationDeltaGateResult] = []
    ) {
        self.artifact = ArtifactIdentity(artifact)
        self.baseline = baseline.map(ArtifactIdentity.init)
        passed =
            results.allSatisfy(\.passed)
            && deltaResults.allSatisfy(\.passed)
        rules = results
        deltaRules = deltaResults
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
    let sampleKeyStrategy: EvaluationSampleKeyStrategy?
    let samples: [EvaluationSampleComparison]?

    init(
        baseline: ArtifactIdentity,
        candidate: ArtifactIdentity,
        metrics: [EvaluationMetricComparison],
        sampleKeyStrategy: EvaluationSampleKeyStrategy? = nil,
        samples: [EvaluationSampleComparison]? = nil
    ) {
        self.baseline = baseline
        self.candidate = candidate
        self.metrics = metrics
        self.sampleKeyStrategy = sampleKeyStrategy
        self.samples = samples
    }
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
    let terminationReason: ProcessTerminationReason
    let terminationSignal: Int32?
    let duration: TimeInterval
    let processIdentifier: Int32
    let processGroupIdentifier: Int32?
    let standardOutput: String
    let standardError: String
    let standardOutputLog: String?
    let standardErrorLog: String?
    let standardOutputTruncated: Bool
    let standardErrorTruncated: Bool

    init(_ result: ProcessResult) {
        status = result.status
        terminationReason = result.terminationReason
        terminationSignal = result.terminationSignal
        duration = result.duration
        processIdentifier = result.processIdentifier
        processGroupIdentifier = result.processGroupIdentifier
        standardOutput = result.standardOutputString
        standardError = result.standardErrorString
        standardOutputLog = result.standardOutputLog.url?.path
        standardErrorLog = result.standardErrorLog.url?.path
        standardOutputTruncated =
            result.standardOutputLog.captureTruncated
            || result.standardOutputLog.fileTruncated
        standardErrorTruncated =
            result.standardErrorLog.captureTruncated
            || result.standardErrorLog.fileTruncated
    }

    init(replaying outcome: OperationProcessOutcome) {
        status = outcome.status
        terminationReason = outcome.terminationReason
        terminationSignal = outcome.terminationSignal
        duration = outcome.duration
        processIdentifier = outcome.processIdentifier
        processGroupIdentifier = outcome.processGroupIdentifier
        standardOutput = replayedProcessLog(at: outcome.standardOutputLog)
        standardError = replayedProcessLog(at: outcome.standardErrorLog)
        standardOutputLog = outcome.standardOutputLog
        standardErrorLog = outcome.standardErrorLog
        standardOutputTruncated = outcome.standardOutputTruncated
        standardErrorTruncated = outcome.standardErrorTruncated
    }
}

struct RunPayload: Encodable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "run"
    let producerCommand: [String]
    let workingDirectory: String?
    let resultsPath: String
    let resultsPaths: [String]
    let process: ProcessPayload?
    let artifacts: [ArtifactListItem]
    let operationReceipt: OperationReceipt?
    let errorMessage: String?
    let replayed: Bool

    init(
        producerCommand: [String],
        workingDirectory: String?,
        resultsPaths: [String],
        process: ProcessResult,
        artifacts: [EvaluationArtifact],
        operationReceipt: OperationReceipt? = nil,
        errorMessage: String? = nil
    ) {
        self.producerCommand = producerCommand
        self.workingDirectory = workingDirectory
        resultsPath = resultsPaths[0]
        self.resultsPaths = resultsPaths
        self.process = ProcessPayload(process)
        self.artifacts = artifacts.map(ArtifactListItem.init)
        self.operationReceipt = operationReceipt
        self.errorMessage = errorMessage
        replayed = false
    }

    init(
        producerCommand: [String],
        workingDirectory: String?,
        resultsPaths: [String],
        process: OperationProcessOutcome?,
        artifacts: [ArtifactListItem],
        operationReceipt: OperationReceipt,
        errorMessage: String?
    ) {
        self.producerCommand = producerCommand
        self.workingDirectory = workingDirectory
        resultsPath = resultsPaths[0]
        self.resultsPaths = resultsPaths
        self.process = process.map(ProcessPayload.init(replaying:))
        self.artifacts = artifacts
        self.operationReceipt = operationReceipt
        self.errorMessage = errorMessage
        replayed = true
    }
}

private func replayedProcessLog(at path: String?) -> String {
    guard let path else { return "" }
    let url = URL(fileURLWithPath: path)
    guard let handle = try? FileHandle(forReadingFrom: url) else {
        return ""
    }
    defer { try? handle.close() }
    let maximumBytes: UInt64 = 1_048_576
    guard
        let end = try? handle.seekToEnd(),
        (try? handle.seek(toOffset: end > maximumBytes ? end - maximumBytes : 0))
            != nil,
        let data = try? handle.readToEnd()
    else {
        return ""
    }
    return String(data: data, encoding: .utf8) ?? ""
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

struct PipelineStepPayload: Encodable {
    let name: String
    let command: [String]
    let status: Int32
    let standardOutputPath: String
    let standardErrorPath: String
}

struct PipelinePayload: Encodable {
    let schemaVersion = "xceval.pipeline-report/v1"
    let command = "pipeline"
    let name: String
    let manifestPath: String
    let workingDirectory: String
    let resultsPath: String
    let artifactsDirectory: String
    let xcode: XcodeInstallation?
    let steps: [PipelineStepPayload]
    let artifact: ArtifactIdentity?
    let validation: ArtifactValidationPayload?
    let gates: [EvaluationGateResult]
    let aggregateComparison: [EvaluationMetricComparison]
    let outputs: [String: String]
    let passed: Bool
    let errors: [String]
}

struct InitPayload: Encodable {
    let schemaVersion = "xceval.init/v1"
    let command = "init"
    let name: String
    let packageName: String
    let executableName: String
    let destination: String
    let files: [String]
    let template: String?
    let authoringTemplateFile: String?
}
