import Testing
@testable import SusuCore

@Test func bundleIDMatchesInfoPlist() throws {
    // build-app.sh signs with this identifier; TCC permissions depend on it staying put.
    #expect(Susu.bundleID == "app.susu.Susu")
}
