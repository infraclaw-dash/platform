import Foundation
import Security
import SwiftData
import XCTest
@testable import SwiftDashSDK

open class IntegrationTestCase: XCTestCase {
    private(set) var env: IntegrationTestEnv!

    // XCTest serialises class-level setUps; only one path touches
    // this latch.
    nonisolated(unsafe) private static var bootstrapResult: Result<IntegrationTestEnv, Error>?

    open override func setUp() async throws {
        try await super.setUp()
        try skipIfDisabled()
        env = try await Self.sharedEnv()
    }

    open override func tearDown() async throws {
        if let env {
            try? await env.walletManager.stopSpv()
        }

        try await super.tearDown()
    }

    private func skipIfDisabled() throws {
        let enabled = ProcessInfo.processInfo.environment["RUN_INTEGRATION_TESTS"] == "1"
        try XCTSkipUnless(
            enabled,
            "Integration tests skipped — set RUN_INTEGRATION_TESTS=1 to enable"
        )
    }

    static func sweepKeychain() {
        guard ProcessInfo.processInfo.environment["DASH_KEYCHAIN_SERVICE"] != nil else { return }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: WalletStorage.keychainService,
        ] as CFDictionary)
    }

    private static func sharedEnv() async throws -> IntegrationTestEnv {
        if let cached = bootstrapResult {
            return try cached.get()
        }

        sweepKeychain()

        do {
            let env = try await IntegrationTestEnv.bootstrap()
            bootstrapResult = .success(env)

            await MainActor.run {
                XCTestObservationCenter.shared.addTestObserver(SpvSuiteCleanupObserver.shared)
            }

            return env
        } catch {
            bootstrapResult = .failure(error)
            throw error
        }
    }

    fileprivate static func cleanupSharedEnv() {
        if case .success(let env)? = bootstrapResult {
            env.cleanupSpvCache()
        }
    }

    /// All txids currently in `PersistentTransaction`
    func readTxids() async throws -> Set<Data> {
        let container = env.modelContainer
        return try await MainActor.run {
            let ctx = ModelContext(container)
            return Set(try ctx.fetch(FetchDescriptor<PersistentTransaction>()).map { $0.txid })
        }
    }

    /// Polls `readTxids()` until a txid not in `before` shows up,
    /// then returns it. Returns nil on timeout (60s).
    func waitForNewTxid(notIn before: Set<Data>) async throws -> Data? {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let after = try await readTxids()
            if let found = after.subtracting(before).first {
                return found
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }
}

private final class SpvSuiteCleanupObserver: NSObject, XCTestObservation {
    nonisolated(unsafe) static let shared = SpvSuiteCleanupObserver()

    func testBundleDidFinish(_ testBundle: Bundle) {
        IntegrationTestCase.cleanupSharedEnv()
        IntegrationTestCase.sweepKeychain()
    }
}
