// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Mach-O platform tags. An iOS device binary is the same arm64 code a Mac
/// Catalyst app runs; only the platform in its LC_BUILD_VERSION differs. A
/// binary tagged Mac Catalyst and signed ad hoc runs on any Apple Silicon Mac
/// (a VM included) with no certificate, profile or install, which is what the
/// native launch mode does with the app's iOS build.
enum MachO {
    private static let mhMagic64: UInt32 = 0xfeedfacf
    private static let fatMagic: UInt32 = 0xcafebabe      // big-endian on disk
    private static let fatMagic64: UInt32 = 0xcafebabf
    private static let lcBuildVersion: UInt32 = 0x32
    private static let lcVersionMinIPhoneOS: UInt32 = 0x25
    private static let platformIOS: UInt32 = 2
    private static let platformCatalyst: UInt32 = 6
    /// Mac Catalyst starts at 14.0 on Apple Silicon; from there its versions match iOS's.
    private static let catalystMinimum: UInt32 = 14 << 16

    /// Whether the file starts like a Mach-O or universal binary.
    static func isMachO(_ path: String) -> Bool {
        guard let magic = readUInt32(path, at: 0) else { return false }
        return magic == mhMagic64 || magic.bigEndian == fatMagic || magic.bigEndian == fatMagic64
    }

    /// Retags every iOS slice for Mac Catalyst, in place. Returns whether the
    /// file changed (its signature is then invalid and it needs signing again).
    /// Slices of other platforms (a watch app's, a Mac framework's) are left alone.
    @discardableResult
    static func retagForCatalyst(_ path: String) throws -> Bool {
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { throw SimlessError("cannot open \(path)") }
        defer { close(fd) }
        var changed = false
        var needsTool = false
        for offset in sliceOffsets(fd) {
            guard let magic = read32(fd, offset), magic == mhMagic64,
                  let ncmds = read32(fd, offset + 16) else { continue }
            var at = offset + 32
            for _ in 0..<ncmds {
                guard let cmd = read32(fd, at), let size = read32(fd, at + 4), size >= 8 else { break }
                if cmd == lcBuildVersion, let platform = read32(fd, at + 8), platform == platformIOS,
                   let minos = read32(fd, at + 12) {
                    write32(fd, at + 8, platformCatalyst)
                    if minos < catalystMinimum { write32(fd, at + 12, catalystMinimum) }
                    changed = true
                } else if cmd == lcVersionMinIPhoneOS {
                    // A binary built before LC_BUILD_VERSION existed: vtool rewrites the command.
                    needsTool = true
                }
                at += UInt64(size)
            }
        }
        if needsTool {
            let tmp = path + ".simless-retag"
            try? FileManager.default.removeItem(atPath: tmp)
            try Shell.check(["xcrun", "vtool", "-set-build-version", "maccatalyst", "14.0", "14.0", "-replace",
                             "-output", tmp, path], what: "retag \((path as NSString).lastPathComponent)")
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
            changed = true
        }
        return changed
    }

    /// The Mach-O files of a bundle (executables, dylibs, frameworks, test
    /// bundles), found by their magic among executable files and dylibs.
    static func binaries(in bundle: String) -> [String] {
        var found: [String] = []
        guard let e = FileManager.default.enumerator(atPath: bundle) else { return [] }
        while let rel = e.nextObject() as? String {
            let path = "\(bundle)/\(rel)"
            guard let attrs = e.fileAttributes, attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            let perms = (attrs[.posixPermissions] as? Int) ?? 0
            guard perms & 0o111 != 0 || rel.hasSuffix(".dylib") else { continue }
            if isMachO(path) { found.append(path) }
        }
        return found
    }

    // MARK: - Reading

    /// Offsets of the Mach-O images in a thin or universal file.
    private static func sliceOffsets(_ fd: Int32) -> [UInt64] {
        guard let raw = read32(fd, 0) else { return [] }
        let magic = raw.bigEndian
        guard magic == fatMagic || magic == fatMagic64 else { return [0] }
        guard let count = read32(fd, 4)?.bigEndian else { return [] }
        var offsets: [UInt64] = []
        for i in 0..<UInt64(count) {
            if magic == fatMagic {
                // fat_arch: cputype, cpusubtype, offset, size, align (5 x 4 bytes)
                if let o = read32(fd, 8 + i * 20 + 8)?.bigEndian { offsets.append(UInt64(o)) }
            } else {
                // fat_arch_64: cputype, cpusubtype, offset (8), size (8), align, reserved
                if let o = read64(fd, 8 + i * 32 + 8)?.bigEndian { offsets.append(o) }
            }
        }
        return offsets
    }

    private static func readUInt32(_ path: String, at offset: UInt64) -> UInt32? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return read32(fd, offset)
    }

    private static func read32(_ fd: Int32, _ offset: UInt64) -> UInt32? {
        var v: UInt32 = 0
        return pread(fd, &v, 4, off_t(offset)) == 4 ? v : nil
    }

    private static func read64(_ fd: Int32, _ offset: UInt64) -> UInt64? {
        var v: UInt64 = 0
        return pread(fd, &v, 8, off_t(offset)) == 8 ? v : nil
    }

    private static func write32(_ fd: Int32, _ offset: UInt64, _ value: UInt32) {
        var v = value
        _ = pwrite(fd, &v, 4, off_t(offset))
    }
}
