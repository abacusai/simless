// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// What `simless init` and slot preparation need to get right without a hand fix.
final class SlotPrepTests: XCTestCase {
    var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "simless-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        _ = try? Shell.run(["/bin/chmod", "-R", "u+w", dir])
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// A classic group holding synchronized subfolders, as in a project that
    /// moved to Xcode 16's folders a few at a time (ids of any length).
    let pbx = """
        // !$*UTF8*$!
        {
        \tobjects = {
        \t\tAC7E570000000000000020 /* Debug */ = {isa = PBXFileSystemSynchronizedRootGroup; explicitFileTypes = {}; explicitFolders = (); path = Debug; sourceTree = "<group>"; };
        \t\t17C374B92E262E1200B2A001 /* ScheduledTasks */ = {isa = PBXFileSystemSynchronizedRootGroup; explicitFileTypes = {}; explicitFolders = (); path = ScheduledTasks; sourceTree = "<group>"; };
        \t\tB08908D72BE3AE4B00053010 = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tB08908E22BE3AE4B00053010 /* Abacus.AI */,
        \t\t\t);
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\tB08908E22BE3AE4B00053010 /* Abacus.AI */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tAC7E570000000000000020 /* Debug */,
        \t\t\t\t17C374B92E262E1200B2A001 /* ScheduledTasks */,
        \t\t\t);
        \t\t\tpath = Abacus.AI;
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\tB08908DF2BE3AE4B00053010 /* Abacus.AI */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tfileSystemSynchronizedGroups = (
        \t\t\t\tAC7E570000000000000020 /* Debug */,
        \t\t\t\t17C374B92E262E1200B2A001 /* ScheduledTasks */,
        \t\t\t);
        \t\t\tname = Abacus.AI;
        \t\t\tproductName = Abacus.AI;
        \t\t};
        \t};
        \trootObject = B08908D82BE3AE4B00053010 /* Project object */;
        }
        """

    func testSynchronizedFoldersResolveThroughClassicGroups() {
        XCTAssertEqual(PBX.synchronizedFolders(target: "Abacus.AI", pbx: pbx).sorted(), ["Abacus.AI/Debug", "Abacus.AI/ScheduledTasks"])
        XCTAssertEqual(PBX.synchronizedFolders(target: "Other", pbx: pbx), [])
    }

    func testTheDemoAppIsOneSynchronizedFolder() throws {
        let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/SimlessDemo/SimlessDemo.xcodeproj/project.pbxproj").path
        let text = try String(contentsOfFile: demo, encoding: .utf8)
        XCTAssertEqual(PBX.synchronizedFolders(target: "SimlessDemo", pbx: text), ["SimlessDemo"])
    }

    /// A binary xcframework in a SwiftPM checkout is read-only, and its build
    /// product keeps that mode. The slot's clone must be writable, the original untouched.
    func testReadOnlyBinaryIsClonedWritable() throws {
        let fw = "\(dir!)/Products/Vendor.framework"
        try FileManager.default.createDirectory(atPath: fw, withIntermediateDirectories: true)
        let bin = try iOSDylib(named: "Vendor", at: "\(fw)/Vendor", source: "public func vendor() -> Int { 1 }")
        try Shell.check(["/bin/chmod", "a-w", bin])
        XCTAssertThrowsError(try MachO.retagForCatalyst(bin))
        try cloneWritable(fw, to: "\(dir!)/Slot.framework", what: "clone")
        XCTAssertTrue(try MachO.retagForCatalyst("\(dir!)/Slot.framework/Vendor"))
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: bin))
    }

    /// Binaries built for old iOS versions load Swift overlays through @rpath.
    /// libswiftCoreNFC only exists for Mac Catalyst, under iOSSupport.
    func testCatalystOnlySwiftLibraryGetsAnRpath() throws {
        try XCTSkipUnless(MachO.inSystem("\(MachO.iOSSupportSwift)/libswiftCoreNFC.dylib"), "no Catalyst CoreNFC on this Mac")
        let bin = try legacyNFC()
        XCTAssertEqual(MachO.rpathLoads(bin).loads, ["libswiftCoreNFC.dylib"])
        XCTAssertTrue(try MachO.addCatalystSwiftRpath(bin, bundled: []))
        XCTAssertEqual(MachO.rpathLoads(bin).rpaths.last, MachO.iOSSupportSwift)
        // Once is enough, and a library the app bundles itself is left alone.
        XCTAssertFalse(try MachO.addCatalystSwiftRpath(bin, bundled: []))
    }

    func testBundledSwiftLibraryIsLeftAlone() throws {
        try XCTSkipUnless(MachO.inSystem("\(MachO.iOSSupportSwift)/libswiftCoreNFC.dylib"), "no Catalyst CoreNFC on this Mac")
        let bin = try legacyNFC()
        XCTAssertEqual(MachO.rpathLoads(bin).loads, ["libswiftCoreNFC.dylib"])
        XCTAssertFalse(try MachO.addCatalystSwiftRpath(bin, bundled: ["libswiftCoreNFC.dylib"]))
    }

    /// A framework binary like one built for iOS 12: CoreNFC's Swift overlay through @rpath.
    private func legacyNFC() throws -> String {
        let bin = try iOSDylib(named: "LegacyNFC", at: "\(dir!)/LegacyNFC", source: "import CoreNFC\npublic func nfc() {}",
                               extra: ["-Xlinker", "-needed-lswiftCoreNFC"])
        try Shell.check(["xcrun", "install_name_tool", "-change", "/usr/lib/swift/libswiftCoreNFC.dylib", "@rpath/libswiftCoreNFC.dylib", bin])
        XCTAssertTrue(MachO.rpathLoads(bin).rpaths.contains("/usr/lib/swift"))
        return bin
    }

    private func iOSDylib(named name: String, at path: String, source: String, extra: [String] = []) throws -> String {
        let src = "\(dir!)/\(name).swift"
        try source.write(toFile: src, atomically: true, encoding: .utf8)
        let sdk = try Shell.check(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try Shell.check(["xcrun", "swiftc", "-emit-library", "-module-name", name, "-target", "arm64-apple-ios15.0", "-sdk", sdk,
                         "-Xlinker", "-headerpad_max_install_names", src, "-o", path] + extra)
        return path
    }
}
