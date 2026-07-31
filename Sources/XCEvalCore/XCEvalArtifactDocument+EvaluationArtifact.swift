import XCEvalFormat

extension XCEvalArtifactDocument {
    public init(
        artifact: EvaluationArtifact,
        includeSamples: Bool
    ) {
        self.init(
            path: artifact.sourceDescription,
            evaluationID: artifact.evaluationID,
            resultID: artifact.resultID,
            startTime: artifact.startTime,
            endTime: artifact.endTime,
            durationInMilliseconds: artifact.durationInMilliseconds,
            sampleCount: artifact.samples.count,
            info: artifact.evaluationInfo,
            reportMetadata: artifact.reportMetadata,
            otherFields: artifact.otherTopLevelFields,
            summary: artifact.summaries,
            samples: includeSamples ? artifact.samples : nil
        )
    }
}
