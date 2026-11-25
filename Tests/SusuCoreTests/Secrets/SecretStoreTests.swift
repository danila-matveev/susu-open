import Foundation
import Testing
@testable import SusuCore

@Suite struct SecretStoreTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func keychainRoundTrip() throws {
        let store = SecretStore()
        let account = ProviderID("test-\(UUID().uuidString)")
        defer { try? store.delete(account) }
        #expect(try store.get(account) == nil)
        try store.set("secret-1", for: account)
        #expect(try store.get(account) == "secret-1")
        try store.set("secret-2", for: account)
        #expect(try store.get(account) == "secret-2")
        try store.delete(account)
        #expect(try store.get(account) == nil)
        try store.delete(account)
    }
}
