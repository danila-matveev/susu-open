import Testing
@testable import SusuCore

struct EditSpanTests {
    @Test func editInsideKeepsSurroundings() {
        #expect(EditSpan.edited(inserted: "привет Насте", field: "A привет Насте B", later: "A привет Анастасии B") == "привет Анастасии")
    }
    @Test func unchangedReturnsSame() {
        #expect(EditSpan.edited(inserted: "hi", field: "hi", later: "hi") == "hi")
    }
    @Test func surroundingsChangedGivesNil() {
        #expect(EditSpan.edited(inserted: "x y", field: "pre x y", later: "PRE x z") == nil)
    }
    @Test func lastOccurrenceIsUsed() {
        #expect(EditSpan.edited(inserted: "ok", field: "ok ok", later: "ok OK!") == "OK!")
    }
    @Test func notFoundGivesNil() {
        #expect(EditSpan.edited(inserted: "zzz", field: "abc", later: "abc") == nil)
    }
}
