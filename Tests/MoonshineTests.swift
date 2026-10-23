import XCTest
import AVFoundation
@testable import Kitty

// MARK: - Brand fixer

final class BrandFixerTests: XCTestCase {

    private func fixed(_ text: String, protectedNames: [String] = []) -> String {
        BrandFixer.fix(text, protectedNames: protectedNames).text
    }

    func testASplitBrandIsJoinedBack() {
        XCTAssertEqual(fixed("order it from blink it tonight"), "order it from Blinkit tonight")
        XCTAssertEqual(fixed("get biscuits, parle g and maggi"), "get biscuits, Parle-G and maggi")   // a case-only difference is left alone
        XCTAssertEqual(fixed("check Urban Company for a plumber"), "check Urban Company for a plumber")
    }

    func testANearMissOfOneClearBrandIsRepaired() {
        XCTAssertEqual(fixed("buy Maggie noodles"), "buy Maggi noodles")
        XCTAssertEqual(fixed("order from zip tow"), "order from Zepto")
        XCTAssertEqual(fixed("get Haldirams namkeen"), "get Haldiram's namkeen")
        XCTAssertEqual(fixed("order from big basket."), "order from BigBasket.")
    }

    func testPunctuationAroundARepairedBrandIsKept() {
        XCTAssertEqual(fixed("Order from blink it, then call Rani."), "Order from Blinkit, then call Rani.")
        XCTAssertEqual(fixed("(blink it)"), "(Blinkit)")
    }

    func testOrdinaryPhrasesAreNeverTouched() {
        for phrase in ["pay them tomorrow", "pay the bill on Friday", "buy a blank page", "book a taxi to the airport",
                       "call the plumber", "bake a cake for the party", "we need a new driver", "add a task for the project",
                       "sweep and mop the floor", "take the dog to the vet", "pick up the groceries"] {
            XCTAssertEqual(fixed(phrase), phrase, "changed: \(phrase)")
        }
    }

    func testAShortWordIsNeverRepaired() {
        XCTAssertEqual(fixed("buy some dal and ola"), "buy some dal and ola")
        XCTAssertEqual(fixed("a mule is not Amul"), "a mule is not Amul")
    }

    func testAHouseholdNameIsProtected() {
        XCTAssertEqual(fixed("ask Maggie to cook", protectedNames: ["Maggie"]), "ask Maggie to cook")
        XCTAssertEqual(fixed("ask Maggie to cook"), "ask Maggi to cook", "without the household name it is the brand")
    }

    func testAnAmbiguousNearMissIsLeftAlone() {
        // One edit from two different terms: not a clear match.
        XCTAssertEqual(BrandFixer.fix("get some sooji", terms: ["Soojia", "Soojib"]).text, "get some sooji")
    }

    func testAnExactBrandIsNotRewritten() {
        let r = BrandFixer.fix("order from Blinkit and Zepto")
        XCTAssertTrue(r.changes.isEmpty)
        XCTAssertEqual(r.text, "order from Blinkit and Zepto")
    }

    func testTheChangesAreReported() {
        let r = BrandFixer.fix("blink it and parle g")
        XCTAssertEqual(r.changes, [.init(from: "blink it", to: "Blinkit"), .init(from: "parle g", to: "Parle-G")])
    }

    func testAnEmptyTextIsFine() {
        XCTAssertEqual(fixed(""), "")
    }
}

// MARK: - Key terms

final class KeyTermsTests: XCTestCase {

    func testHouseholdNamesComeFirstThenBrands() {
        let terms = KeyTerms.build(household: ["Rani", "Suresh"])
        XCTAssertEqual(Array(terms.prefix(2)), ["Rani", "Suresh"])
        XCTAssertTrue(terms.contains("Blinkit"))
        XCTAssertTrue(terms.contains("Aashirvaad"))
    }

    func testTheListIsCappedAndHasNoDuplicatesOrCommas() {
        let household = (0..<100).map { "Name\($0)" } + ["rani", "Rani", "blinkit", "Has, comma"]
        let terms = KeyTerms.build(household: household)
        XCTAssertLessThanOrEqual(terms.count, KeyTerms.limit)
        XCTAssertEqual(terms.count, Set(terms.map { $0.lowercased() }).count)
        XCTAssertFalse(terms.contains { $0.contains(",") })
        XCTAssertEqual(terms.filter { $0.hasPrefix("Name") }.count, KeyTerms.householdLimit, "households cannot crowd the brands out")
    }

    func testTheBundledListHasTheBrandsTheUserNamed() {
        for brand in ["Blinkit", "Zepto", "Swiggy", "Zomato", "BigBasket", "Flipkart", "Paytm", "PhonePe", "Urban Company", "Amul",
                      "Maggi", "Aashirvaad", "Haldiram's", "atta", "paneer", "kirana", "bai"] {
            XCTAssertTrue(IndianVocabulary.terms.contains(brand), brand)
        }
        XCTAssertFalse(IndianVocabulary.terms.contains { $0.contains(",") })
    }
}
