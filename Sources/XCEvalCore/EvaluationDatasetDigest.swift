import Foundation
import XCEvalFormat

public enum EvaluationDatasetDigest {
    public static func sha256(_ data: Data) -> ContentDigest {
        ContentDigest(data: data)
    }

    public static func canonicalJSON<T: Encodable>(
        _ value: T
    ) throws -> ContentDigest {
        try ContentDigest.canonicalJSON(value)
    }

    public static func canonicalJSONValue(
        _ value: JSONValue
    ) throws -> ContentDigest {
        ContentDigest(data: try value.encodedData())
    }

    public static func canonicalRecords(
        _ records: [JSONValue]
    ) throws -> ContentDigest {
        try canonicalJSONValue(.array(records))
    }
}
