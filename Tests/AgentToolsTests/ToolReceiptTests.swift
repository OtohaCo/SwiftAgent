import AgentTools
import Foundation
import Testing

struct ToolReceiptTests {
    @Test func receiptRoundTripsAndMatchesOperationTargetsAndRevision() throws {
        let a = EvidenceReference(namespace: "cad.document", id: "a")
        let b = EvidenceReference(namespace: "cad.document", id: "b")
        let expected = try ToolReceiptExpectation(targets: [a, b], revision: .changed(from: "v1"))
        let receipt = ToolReceipt(operationID: "operation-1", status: .succeeded, confirmedTargets: [b, a], revision: "v2")
        #expect(try JSONDecoder().decode(ToolReceipt.self, from: JSONEncoder().encode(receipt)) == receipt)
        try ToolReceiptValidator.validate(receipt, operationID: "operation-1", expectation: expected)
    }

    @Test func missingFailedMismatchedAndAmbiguousReceiptsAreRejected() throws {
        let target = EvidenceReference(namespace: "property.listing", id: "1")
        let expected = try ToolReceiptExpectation(targets: [target], revision: .exact("v2"))
        let invalid: [ToolReceipt?] = [
            nil,
            .init(operationID: "other", status: .succeeded, confirmedTargets: [target], revision: "v2"),
            .init(operationID: " ", status: .succeeded, confirmedTargets: [target], revision: "v2"),
            .init(operationID: "op", status: .failed, confirmedTargets: [target], revision: "v2", failure: .conflict),
            .init(operationID: "op", status: .indeterminate, confirmedTargets: [target], revision: "v2"),
            .init(operationID: "op", status: .succeeded, confirmedTargets: [target], revision: "v2", failure: .rejected),
            .init(operationID: "op", status: .succeeded, confirmedTargets: [], revision: "v2"),
            .init(operationID: "op", status: .succeeded, confirmedTargets: [target, target], revision: "v2"),
            .init(operationID: "op", status: .succeeded, confirmedTargets: [.init(namespace: "property.listing", id: "2")], revision: "v2"),
            .init(operationID: "op", status: .succeeded, confirmedTargets: [target, .init(namespace: "resource", id: "extra")], revision: "v2"),
            .init(operationID: "op", status: .succeeded, confirmedTargets: [.init(namespace: "", id: "1")], revision: "v2"),
            .init(operationID: "op", status: .succeeded, confirmedTargets: [target]),
            .init(operationID: "op", status: .succeeded, confirmedTargets: [target], revision: " "),
            .init(operationID: "op", status: .succeeded, confirmedTargets: [target], revision: "v1"),
        ]
        let errors: [ToolReceiptError] = [
            .missing, .operationMismatch, .invalidOperationID, .unsuccessful(.failed, .conflict), .unsuccessful(.indeterminate, nil),
            .inconsistentStatus, .invalidTargets, .invalidTargets, .targetsMismatch, .targetsMismatch, .invalidTargets,
            .revisionMismatch, .invalidRevision, .revisionMismatch,
        ]
        for (receipt, error) in zip(invalid, errors) {
            #expect(throws: error) { try ToolReceiptValidator.validate(receipt, operationID: "op", expectation: expected) }
        }
    }

    @Test func expectationRejectsEmptyDuplicateAndInvalidTargets() {
        let target = EvidenceReference(namespace: "resource", id: "1")
        for targets in [[], [target, target], [.init(namespace: " ", id: "1")]] as [[EvidenceReference]] {
            #expect(throws: ToolReceiptError.invalidExpectation) { try ToolReceiptExpectation(targets: targets) }
        }
        for revision in [ToolReceiptExpectation.Revision.exact(""), .changed(from: " ")] {
            #expect(throws: ToolReceiptError.invalidExpectation) { try ToolReceiptExpectation(targets: [target], revision: revision) }
        }
    }

    @Test func revisionModesAndUnicodeUseOpaqueMatching() throws {
        let target = EvidenceReference(namespace: "resource", id: "\u{e9}")
        let receipt = ToolReceipt(operationID: "op-\u{e9}", status: .succeeded, confirmedTargets: [target], revision: "\u{e9}")
        let exact = try ToolReceiptExpectation(targets: [target], revision: .exact("e\u{301}"))
        #expect(throws: ToolReceiptError.revisionMismatch) { try ToolReceiptValidator.validate(receipt, operationID: "op-\u{e9}", expectation: exact) }
        let ordinary = try ToolReceiptExpectation(targets: [target])
        #expect(throws: ToolReceiptError.operationMismatch) { try ToolReceiptValidator.validate(receipt, operationID: "op-e\u{301}", expectation: ordinary) }
        let otherTarget = try ToolReceiptExpectation(targets: [.init(namespace: "resource", id: "e\u{301}")])
        #expect(throws: ToolReceiptError.targetsMismatch) { try ToolReceiptValidator.validate(receipt, operationID: "op-\u{e9}", expectation: otherTarget) }
        let noRevision = ToolReceipt(operationID: "op", status: .succeeded, confirmedTargets: [target])
        try ToolReceiptValidator.validate(noRevision, operationID: "op", expectation: ordinary)
        #expect(throws: ToolReceiptError.revisionMismatch) {
            try ToolReceiptValidator.validate(noRevision, operationID: "op", expectation: ToolReceiptExpectation(targets: [target], revision: .present))
        }
        #expect(throws: ToolReceiptError.revisionMismatch) {
            try ToolReceiptValidator.validate(receipt, operationID: "op-\u{e9}", expectation: ToolReceiptExpectation(targets: [target], revision: .changed(from: "\u{e9}")))
        }
    }

    @Test func exactAndPresentRevisionPassAndExpectedOperationMustBeNonblank() throws {
        let target = EvidenceReference(namespace: "resource", id: "1")
        let receipt = ToolReceipt(operationID: "op", status: .succeeded, confirmedTargets: [target], revision: "v2")
        for revision in [ToolReceiptExpectation.Revision.exact("v2"), .present] {
            let expectation = try ToolReceiptExpectation(targets: [target], revision: revision)
            try ToolReceiptValidator.validate(receipt, operationID: "op", expectation: expectation)
            #expect(throws: ToolReceiptError.invalidOperationID) { try ToolReceiptValidator.validate(receipt, operationID: " \n", expectation: expectation) }
        }
    }
}
