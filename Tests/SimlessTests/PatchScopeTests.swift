// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// Hot-reload scoping on a small made-up app: a parent view embedding a leaf,
/// a store that names views without building them, and a model with a row view.
final class PatchScopeTests: XCTestCase {
    let leafBefore = """
        import SwiftUI

        struct LeafView: View {
            var body: some View { Text("before").card() }
        }

        #if DEBUG
        extension View {
            func card() -> some View { padding() }
        }
        #endif

        struct Unrelated: View {
            var body: some View { Text("u") }
        }
        """

    func input(leaf: String? = nil, model: String = "struct Item { var title: String }") -> PatchScope.Input {
        var i = PatchScope.Input()
        i.sources = [
            "Store.swift": """
                final class Store: ObservableObject {
                    // Screens it can present, by name only.
                    let screens: [Any.Type] = [ParentView.self, LeafView.self, OtherView.self, ItemRow.self]
                }
                """,
            "ParentView.swift": "import SwiftUI\nstruct ParentView: View {\n    var body: some View { VStack { LeafView() } }\n}\n",
            "LeafView.swift": leaf ?? leafBefore,
            "OtherView.swift": "struct OtherView: View {\n    @ObservedObject var store: Store\n    var body: some View { Text(\"o\") }\n}\n",
            "Model.swift": model,
            "ItemRow.swift": "struct ItemRow: View {\n    let item: Item\n    var body: some View { Text(item.title) }\n}\n",
        ]
        i.fixturesText = """
            @MainActor
            func simlessFixtures(_ r: SimlessRegistry) {
                r.add("Parent") { ParentView() }
                r.add("Leaf") { LeafView() }
                r.add("Other") { OtherView(store: Store()) }
                r.add("Row") { ItemRow(item: Item(title: "x")) }
            }
            """
        i.before = ["LeafView.swift": leafBefore, "Model.swift": "struct Item { var title: String }"]
        return i
    }

    var leafEdited: String { leafBefore.replacingOccurrences(of: "\"before\"", with: "\"after\"") }

    func testLeafEditForItsParentPatchesTheParent() throws {
        let s = try PatchScope.scope(input(leaf: leafEdited), edited: ["LeafView.swift"], fixtures: ["Parent"])
        XCTAssertEqual(Set(s.all), ["SimlessFixtures.swift", "LeafView.swift", "ParentView.swift"])
        XCTAssertEqual(s.extra, ["ParentView.swift"])
        XCTAssertEqual(s.covered, ["Leaf", "Parent"])
        XCTAssertEqual(s.stale, [])
    }

    func testOtherFixturesAreStaleNotPatched() throws {
        let s = try PatchScope.scope(input(leaf: leafEdited), edited: ["LeafView.swift"], fixtures: ["Leaf"])
        XCTAssertEqual(Set(s.all), ["SimlessFixtures.swift", "LeafView.swift"])
        XCTAssertEqual(s.covered, ["Leaf"])
        XCTAssertEqual(s.stale, ["Parent"])
    }

    func testAStoreThatNamesAViewDoesntReachIt() throws {
        // Store names LeafView, and Other's view holds a Store: Other doesn't render LeafView.
        let s = try PatchScope.scope(input(leaf: leafEdited), edited: ["LeafView.swift"])
        XCTAssertFalse(s.all.contains("Store.swift"))
        XCTAssertFalse(s.all.contains("OtherView.swift"))
        XCTAssertFalse(s.covered.contains("Other") || s.stale.contains("Other"))
    }

    func testPatchKeepsOnlyTheChangedDeclarations() throws {
        let s = try PatchScope.scope(input(leaf: leafEdited), edited: ["LeafView.swift"], fixtures: ["Leaf"])
        let text = try XCTUnwrap(s.texts["LeafView.swift"])
        XCTAssertTrue(text.contains("Text(\"after\")"))
        // An unchanged extension of SwiftUI's View would be ambiguous next to the app's copy.
        XCTAssertFalse(text.contains("func card"))
        XCTAssertFalse(text.contains("struct Unrelated"))
        // Same lines (for error locations) and balanced #ifs.
        XCTAssertEqual(text.components(separatedBy: "\n").count, leafEdited.components(separatedBy: "\n").count)
        XCTAssertTrue(text.contains("#if DEBUG") && text.contains("#endif"))
    }

    func testModelEditReachesViewsThatUseIt() throws {
        let edited = "struct Item { var title: String; var subtitle = \"\" }"
        let s = try PatchScope.scope(input(model: edited), edited: ["Model.swift"])
        XCTAssertTrue(s.all.contains("ItemRow.swift"))
        XCTAssertTrue(s.covered.contains("Row"))
    }

    func testEditToAnExtensionOfAnOutsideTypeNeedsAFullBuild() {
        let edited = leafBefore.replacingOccurrences(of: "padding()", with: "padding(4)")
        XCTAssertThrowsError(try PatchScope.scope(input(leaf: edited), edited: ["LeafView.swift"])) {
            XCTAssertTrue("\($0)".contains("extends View"))
        }
    }

    func testEditToAnInternalTopLevelFunctionNeedsAFullBuild() {
        var i = input()
        i.sources["Helpers.swift"] = "func greeting() -> String { \"hi\" }\n"
        i.before["Helpers.swift"] = "func greeting() -> String { \"hello\" }\n"
        XCTAssertThrowsError(try PatchScope.scope(i, edited: ["Helpers.swift"])) {
            XCTAssertTrue("\($0)".contains("top-level greeting"))
        }
        i.sources["Helpers.swift"] = "private func greeting() -> String { \"hi\" }\n"
        i.before["Helpers.swift"] = "private func greeting() -> String { \"hello\" }\n"
        XCTAssertNoThrow(try PatchScope.scope(i, edited: ["Helpers.swift"]))
    }

    func testWithoutABuildCopyEveryDeclarationCounts() throws {
        var i = input(leaf: leafEdited)
        i.before = [:]
        // The unchanged extension of View now counts as edited.
        XCTAssertThrowsError(try PatchScope.scope(i, edited: ["LeafView.swift"]))
    }

    func testChunksSplitTopLevelDeclarations() {
        let c = PatchScope.chunks(leafBefore)
        XCTAssertEqual(c.map(\.key), ["type LeafView", "ext View", "type Unrelated"])
        XCTAssertEqual(c[0].inherits, ["View"])
        XCTAssertTrue(c[1].members.contains("card"))
    }
}
