// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// Fixtures from #Preview blocks and the App, generated from source.
final class PreviewsTests: XCTestCase {
    let app = """
        import SwiftUI

        @main
        struct NotesApp: App {
            @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
            @StateObject private var settings = AppSettings()

            init() {
                Analytics.start()
            }

            var body: some Scene {
                WindowGroup {
                    ContentView()
                        .environmentObject(settings)
                }
                .modelContainer(for: Note.self)
                .commands { CommandGroup(replacing: .newItem) {} }
            }
        }
        """

    let row = """
        import SwiftUI

        struct NoteRow: View {
            let note: Note
            var body: some View { Text(note.title) }
        }

        private let sample = Note(title: "Groceries")

        #Preview("Short") {
            NoteRow(note: sample)
        }

        #Preview {
            @Previewable @State var on = true
            Toggle("On", isOn: $on)
        }

        #Preview(as: .systemSmall) {
            NotesWidget()
        } timeline: {
            Entry()
        }

        struct NoteRow_Previews: PreviewProvider {
            static var previews: some View { NoteRow(note: sample) }
        }
        """

    func input() -> PatchScope.Input {
        var i = PatchScope.Input()
        i.sources = ["NotesApp.swift": app, "NoteRow.swift": row]
        return i
    }

    func testNamesAndWhatsLeftOut() {
        let g = Previews.generate(input(), skip: [:])
        XCTAssertEqual(g.entries.map(\.name), ["root", "NoteRow.Short", "NoteRow.2", "NoteRow.3", "NoteRow.NoteRow_Previews"])
        XCTAssertEqual(g.entries.first { $0.name == "NoteRow.3" }?.skipped, "a widget or Live Activity preview, not a view")
        XCTAssertEqual(g.calls.count, 4)
    }

    func testCopiesKeepTheirLinesAndPrivateHelpers() throws {
        let g = Previews.generate(input(), skip: [:])
        for (file, text) in [("NotesApp.swift", app), ("NoteRow.swift", row)] {
            let copy = try XCTUnwrap(g.texts[file])
            XCTAssertEqual(copy.components(separatedBy: "\n").count, text.components(separatedBy: "\n").count, file)
        }
        let copy = g.texts["NoteRow.swift"]!
        XCTAssertTrue(copy.contains("private let sample = Note(title: \"Groceries\")"))
        XCTAssertFalse(copy.contains("struct NoteRow: View"))   // the app's own
        XCTAssertTrue(copy.contains("r.add(\"NoteRow.Short\") { simlessPreviewContent {"))
        XCTAssertTrue(copy.contains("@State var on = true"))
        XCTAssertFalse(copy.contains("@Previewable"))
        XCTAssertTrue(copy.contains("{ NoteRow_Previews.previews }"))
        XCTAssertFalse(copy.contains("#Preview"))
    }

    func testRootIsTheAppAsAView() throws {
        let copy = try XCTUnwrap(Previews.generate(input(), skip: [:]).texts["NotesApp.swift"])
        XCTAssertTrue(copy.contains("struct SimlessRootView: View {"))
        XCTAssertFalse(copy.contains("@main"))
        XCTAssertTrue(copy.contains("var appDelegate: AppDelegate { simlessAppDelegate(AppDelegate.self) }"))
        XCTAssertTrue(copy.contains("@StateObject private var settings = AppSettings()"))
        XCTAssertFalse(copy.contains("Analytics.start()"))       // the App's init runs once, in the app
        XCTAssertTrue(copy.contains(".modelContainer(for: Note.self)"))
        XCTAssertFalse(copy.contains(".commands"))               // a scene-only modifier
        XCTAssertTrue(copy.contains("r.add(\"root\") { SimlessRootView() }"))
    }

    func testSkippedPreviewsAreLeftOutWithTheReason() {
        let g = Previews.generate(input(), skip: ["NoteRow.Short": "doesn't compile"])
        XCTAssertEqual(g.entries.first { $0.name == "NoteRow.Short" }?.skipped, "doesn't compile")
        XCTAssertFalse(g.texts["NoteRow.swift"]!.contains("NoteRow.Short"))
    }

    func testOnlyGeneratesWhatsAsked() {
        let g = Previews.generate(input(), skip: [:], only: ["NoteRow.2"])
        XCTAssertEqual(g.entries.map(\.name), ["NoteRow.2"])
        XCTAssertNil(g.texts["NotesApp.swift"])
    }
}
