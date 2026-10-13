// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Charts
import SwiftUI

/// Small screens for SwiftUI behaviours UI tests depend on, one per launch
/// argument (`-SimlessDemoLab <name>`). The UI tests in SimlessDemoUITests
/// check that each behaves the way it does on an iPhone.
struct BehaviorLab: View {
    let name: String

    var body: some View {
        switch name {
        case "gestures": GesturePrecedenceLab()
        case "gestures-scroll": ScrollView { GesturePrecedenceLab() }
        case "combined": CombinedElementLab()
        case "chart": ScrollingChartLab()
        case "stepper": StepperLab()
        case "list": LongListLab()
        case "menu": SubmenuLab()
        case "waits": WaitsLab()
        case "sheet": SheetLab()
        default: Text("Unknown lab \(name)")
        }
    }
}

/// A Button inside a view with its own tap gesture: the Button gets the tap.
struct GesturePrecedenceLab: View {
    @State private var inner = 0
    @State private var outer = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("Tap the button, or anywhere else in the card")
            Button("Inner") { inner += 1 }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("lab.inner")
            // A plain-style Button read as one element with its own label: it has
            // no accessibility action of its own, so only a touch reaches it.
            Button { inner += 1 } label: {
                HStack { Image(systemName: "bed.double"); Text("Sleep 7 h") }.padding()
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("lab.chip")
            Text("inner \(inner) · outer \(outer)")
                .accessibilityIdentifier("lab.counts")
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .background(.yellow.opacity(0.2))
        .contentShape(Rectangle())
        .onTapGesture { outer += 1 }
    }
}

/// A combined element still lets queries find its children's identifiers.
struct CombinedElementLab: View {
    var body: some View {
        VStack(spacing: 40) {
            VStack {
                Image(systemName: "checkmark.circle")
                Text("Done").accessibilityIdentifier("lab.combined.inner")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("lab.combined.outer")
            // A row button around a card that contains its own elements.
            Button {} label: {
                HStack {
                    Image(systemName: "circle").accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text("Quarterly Note")
                        Text("Seeded note.")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("lab.combined.card")
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lab.combined.row")
        }
    }
}

/// A year of days in a chart that scrolls sideways, a month at a time on screen.
struct ScrollingChartLab: View {
    static let days: [Date] = (0..<365).map { Calendar(identifier: .gregorian).date(byAdding: .day, value: $0, to: start)! }
    static let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC
    @State private var position = Calendar(identifier: .gregorian).date(byAdding: .day, value: 334, to: start)!
    @State private var selecting: Date?
    @State private var selected: Date?

    var body: some View {
        VStack(alignment: .leading) {
            Text(position, format: .dateTime.year().month().day())
                .accessibilityIdentifier("lab.chart.position")
            Text(selected.map { $0.formatted(.dateTime.year().month().day()) } ?? "none")
                .accessibilityIdentifier("lab.chart.selected")
            Chart(Self.days, id: \.self) { day in
                BarMark(x: .value("Day", day, unit: .day), y: .value("Value", Double((Calendar.current.ordinality(of: .day, in: .year, for: day) ?? 1) % 13)))
            }
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: 3600 * 24 * 30)
            .chartScrollPosition(x: $position)
            // The selection clears when the finger lifts; the last one is kept.
            .chartXSelection(value: $selecting)
            .onChange(of: selecting) { _, day in if let day { selected = day } }
            .frame(height: 220)
            .accessibilityIdentifier("lab.chart")
        }
        .padding()
    }
}

/// A Stepper in a Form, the control that overflows the stack on the Mac.
struct StepperLab: View {
    @State private var count = 3

    var body: some View {
        Form {
            Stepper("Count: \(count)", value: $count, in: 0...10)
                .accessibilityIdentifier("lab.stepper")
        }
    }
}

/// A long settings-style list: swiping up until a row is hittable finds every row.
struct LongListLab: View {
    var body: some View {
        NavigationStack {
            List {
                ForEach(0..<6) { section in
                    Section("Section \(section)") {
                        ForEach(0..<8) { row in
                            Button("Row \(section * 8 + row)") {}
                        }
                    }
                }
            }
            .navigationTitle("List")
        }
    }
}

/// A context menu with a submenu, and a Menu with one: the submenu is a row
/// that opens its own items.
struct SubmenuLab: View {
    @State private var chosen = "none"
    @State private var confirming = false
    @AppStorage("SimlessDemoTheme") private var theme = "system"

    var body: some View {
        VStack(spacing: 40) {
            Text("Task")
                .padding()
                .contextMenu {
                    Menu("Snooze") {
                        Button("Tomorrow") { chosen = "Tomorrow" }
                        Button("Next Week") { chosen = "Next Week" }
                    }
                    Button("Delete", role: .destructive) { chosen = "Delete" }
                }
            Menu("Options") {
                Menu("Style") {
                    Button("Short") { chosen = "Short" }
                    Button("Detailed") { chosen = "Detailed" }
                    Button("Bullet List") { confirming = true }
                }
                Button("Rename") { chosen = "Rename" }
                    .accessibilityIdentifier("lab.rename")
            }
            Picker("Theme", selection: $theme) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("lab.theme")
            Text(chosen).accessibilityIdentifier("lab.chosen")
        }
        .confirmationDialog("Replace the summary?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { chosen = "Bullet List" }
                .accessibilityIdentifier("lab.confirm")
            Button("Cancel", role: .cancel) { chosen = "Kept" }
                .accessibilityIdentifier("lab.cancel")
        }
    }
}


/// A switch row and removable chips, for tests that wait on a predicate.
struct WaitsLab: View {
    @AppStorage("SimlessDemoAuto") private var auto = true
    @State private var chips = ["One", "Two", "Three"]
    @State private var link = ""

    var body: some View {
        List {
            TextField("Link", text: $link).accessibilityIdentifier("lab.link")
            Toggle(isOn: $auto) {
                VStack(alignment: .leading) {
                    Text("Automatic")
                    Text("Runs after every change").font(.caption)
                }
            }
            .accessibilityIdentifier("lab.auto")
            ForEach(chips, id: \.self) { chip in
                Button(chip) { chips.removeAll { $0 == chip } }
                    .accessibilityIdentifier("lab.chip")
            }
        }
    }
}

/// A sheet closed by a toolbar button with only an image.
struct SheetLab: View {
    @State private var showing = true

    var body: some View {
        Button("Open") { showing = true }
            .sheet(isPresented: $showing) { SheetLabContent() }
    }
}

private struct SheetLabContent: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Button("Unlock") {}
                .accessibilityIdentifier("lab.sheet.cta")
                .toolbar {
                    ToolbarItem {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .accessibilityLabel(Text("Close"))
                    }
                }
        }
    }
}
