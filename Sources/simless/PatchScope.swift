// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Decides which files a hot-reload patch must contain so that the fixtures
/// being rendered show the edited code, or that a patch can't be trusted at all.
///
/// A patch's copies of edited types only take effect where the patch itself
/// constructs them. An unedited view that embeds an edited view is still the
/// app's compiled code and would keep rendering the *old* subview. So the patch
/// also includes every view on the way from a fixture to an edited view.
///
/// The graph is built from top-level declarations (a type with its extensions
/// is one node) and the identifiers in their code (not comments or strings).
/// The rules:
/// - Only the declarations an edit changed count as edited, found by comparing
///   each declaration's text with the last full build's copy of the file.
/// - From an edited (or affected) view, only views that name it are affected:
///   they construct or embed it. A store, model or enum that names a view
///   doesn't make a render stale, because renders go from view to view.
/// - From an edited non-view type (a model, a view model), everything that
///   names it is affected, views and non-views alike, and on from there.
/// - A "view" is a type that conforms to `View`, `ViewModifier`, a style or a
///   representable protocol (or a protocol of the app's that refines one), a
///   UIKit view or view controller class, or any declaration whose code builds
///   views (`some View`, `AnyView`, `@ViewBuilder`). When unsure, it's a view.
/// - Each fixture only needs the affected views on its own way to the edit.
///   Fixtures the patch doesn't cover are reported as stale.
/// Edits that other code can observe without naming an edited type (extensions
/// of types outside the sources, non-private top-level functions or variables)
/// can't be traced and require a full build. The analysis over-approximates:
/// an extra file costs compile time, a missing one costs a wrong render.
enum PatchScope {
    static let maxFiles = 40

    struct Chunk {
        enum Kind: String { case type, ext, value, preview }
        let kind: Kind
        let name: String        // the type, the extended type, or the function or variable
        let isPrivate: Bool
        let isPublic: Bool
        let inherits: [String]  // conformances and superclass named in the declaration
        let tokens: Set<String> // identifiers in code
        let members: Set<String> // an extension's member names
        let text: String        // original text, for telling what an edit changed
        let start: Int          // UTF-16 offset in the file
        let buildsViews: Bool
        var key: String { "\(kind.rawValue) \(name)" }
    }

    struct Scope {
        let all: [String]       // fixtures file, edited files, then the extra ones
        let extra: [String]     // unedited files patched because they embed an edited view
        let covered: [String]   // fixtures the patch renders with the edited code
        let stale: [String]     // fixtures that reach the edit but aren't covered
        let texts: [String: String] // what the patch compiles of each file
    }

    /// Comments and string literals, blanked (same length) before collecting
    /// identifiers, so a word in a doc comment or a label isn't a reference.
    private static let nonCode = try! NSRegularExpression(
        pattern: ##"//[^\n]*|/\*[\s\S]*?\*/|#?"""[\s\S]*?"""#?|"(?:\\.|[^"\\\n])*""##)
    private static let identifier = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)
    private static let declaration = try! NSRegularExpression(
        pattern: #"^((?:@[\w.]+(?:\([^\n]*?\))?\s+)*)((?:(?:public|internal|private|fileprivate|open|package|final|nonisolated|indirect)\s+)*)(extension|func|var|let|struct|class|enum|actor|protocol|typealias)\s+([A-Za-z_][\w.]*)"#)
    private static let member = try! NSRegularExpression(
        pattern: #"\b(?:func|var|let|case)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    private static let viewBuilding = try! NSRegularExpression(
        pattern: #"\bsome\s+(?:SwiftUI\.)?View\b|\bAnyView\b|@ViewBuilder\b|\bsome\s+ViewModifier\b"#)
    private static let keywords: Set<String> = ["func", "var", "let", "init", "subscript", "case", "where", "some", "any"]

    private static let swiftUIViews: Set<String> = ["View", "ViewModifier", "Shape", "InsettableShape", "UIView", "UIViewController", "App", "Scene"]

    private static func isViewName(_ n: String) -> Bool {
        swiftUIViews.contains(n) || n.hasSuffix("Style") || n.hasSuffix("Representable")
            || (n.hasPrefix("UI") && ["View", "Controller", "Cell", "Control", "Label", "Button", "Field", "Bar"].contains { n.hasSuffix($0) })
    }

    private static func strings(_ re: NSRegularExpression, _ s: String, group: Int = 0) -> [String] {
        re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).compactMap {
            Range($0.range(at: group), in: s).map { String(s[$0]) }
        }
    }

    /// `s` with comments and string literals replaced by spaces (newlines kept),
    /// so offsets stay the same as in `s`.
    static func code(_ s: String) -> String {
        var u = Array(s.utf16)
        for m in nonCode.matches(in: s, range: NSRange(location: 0, length: u.count)) {
            for i in m.range.location..<NSMaxRange(m.range) where u[i] != 10 { u[i] = 32 }
        }
        return String(decoding: u, as: UTF16.self)
    }

    /// The file's top-level declarations, each with the text up to the next one.
    static func chunks(_ text: String) -> [Chunk] {
        let clean = code(text)
        let u = Array(clean.utf16)
        let original = text as NSString, cleanNS = clean as NSString
        // Lines that start at brace depth 0, with the depth inside each line's
        // own text, for telling an extension's members from locals.
        var depth = 0, lineStart = 0
        var lines: [(range: NSRange, depth: Int)] = []
        for i in 0...u.count {
            if i == u.count || u[i] == 10 {
                lines.append((NSRange(location: lineStart, length: i - lineStart), depth))
                lineStart = i + 1
                continue
            }
            if u[i] == 123 { depth += 1 } else if u[i] == 125 { depth -= 1 }
        }
        // `lines[k].depth` is the depth at the line's end; the depth at its start
        // is the previous line's end.
        var heads: [(at: Int, match: NSTextCheckingResult?, line: String)] = []
        var pending: Int?
        for (k, line) in lines.enumerated() {
            let startDepth = k == 0 ? 0 : lines[k - 1].depth
            guard startDepth <= 0 else { continue }
            let raw = cleanNS.substring(with: line.range)
            let s = raw.trimmingCharacters(in: .whitespaces)
            let indent = (raw as NSString).length - (raw.drop { $0 == " " || $0 == "\t" } as Substring).utf16.count
            if s.hasPrefix("#Preview") {
                heads.append((pending ?? line.range.location, nil, "#Preview")); pending = nil; continue
            }
            if let m = declaration.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
                heads.append((pending ?? line.range.location + indent, m, s)); pending = nil; continue
            }
            if s.hasPrefix("@") { pending = pending ?? line.range.location + indent }
            else if !s.isEmpty { pending = nil }
        }
        var out: [Chunk] = []
        for (n, head) in heads.enumerated() {
            let end = n + 1 < heads.count ? heads[n + 1].at : u.count
            let range = NSRange(location: head.at, length: end - head.at)
            let body = cleanNS.substring(with: range)
            let tokens = Set(strings(identifier, body))
            let builds = viewBuilding.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) != nil
            guard let m = head.match else {
                out.append(Chunk(kind: .preview, name: "#Preview\(n)", isPrivate: true, isPublic: false, inherits: [],
                                 tokens: tokens, members: [], text: original.substring(with: range), start: range.location, buildsViews: builds))
                continue
            }
            let line = head.line as NSString
            let mods = line.substring(with: m.range(at: 2))
            let keyword = line.substring(with: m.range(at: 3))
            var name = line.substring(with: m.range(at: 4))
            if keywords.contains(name) { continue }
            let kind: Chunk.Kind
            switch keyword {
            case "extension":
                // `extension Outer.Inner` is code of Outer's; `SwiftUI.View` is View.
                kind = .ext
                let parts = name.split(separator: ".").map(String.init)
                name = parts.count > 1 && ["Swift", "SwiftUI", "UIKit", "Foundation"].contains(parts[0]) ? parts[1] : parts[0]
            case "func", "var", "let": kind = .value
            default: kind = .type
            }
            // Conformances: after the name (and generic parameters), up to `{` or `where`.
            var inherits: [String] = []
            if kind != .value {
                let after = line.substring(from: NSMaxRange(m.range))
                var rest = Substring(after)
                if rest.hasPrefix("<") {
                    var d = 0
                    while let c = rest.first { rest.removeFirst(); if c == "<" { d += 1 } else if c == ">" { d -= 1; if d == 0 { break } } }
                }
                rest = rest.drop { $0 == " " }
                if rest.hasPrefix(":") {
                    var clause = String(rest.dropFirst())
                    if let r = clause.range(of: "{") { clause = String(clause[..<r.lowerBound]) }
                    if let r = clause.range(of: " where ") { clause = String(clause[..<r.lowerBound]) }
                    inherits = clause.split(separator: ",").compactMap {
                        let t = $0.trimmingCharacters(in: .whitespaces).split(separator: "<").first.map(String.init) ?? ""
                        return t.split(separator: ".").last.map(String.init)
                    }.filter { !$0.isEmpty }
                }
            }
            // An extension's members: declarations one level in.
            var members = Set<String>()
            if kind == .ext {
                for (k, l) in lines.enumerated() where l.range.location >= range.location && NSMaxRange(l.range) <= NSMaxRange(range) {
                    guard (k == 0 ? 0 : lines[k - 1].depth) == 1 else { continue }
                    members.formUnion(strings(member, cleanNS.substring(with: l.range), group: 1))
                }
            }
            out.append(Chunk(kind: kind, name: name,
                             isPrivate: mods.contains("private"), isPublic: mods.contains("public") || mods.contains("open"),
                             inherits: inherits, tokens: tokens, members: members,
                             text: original.substring(with: range), start: range.location, buildsViews: builds))
        }
        return out
    }

    /// The chunks of `now` whose text differs from `before`'s (or that are new
    /// or gone), by kind and name.
    static func changed(before: [Chunk], now: [Chunk]) -> Set<String> {
        func index(_ cs: [Chunk]) -> [String: [String]] {
            cs.reduce(into: [:]) { $0[$1.key, default: []].append($1.text) }
        }
        let a = index(before), b = index(now)
        return Set(Set(a.keys).union(b.keys).filter { a[$0] != b[$0] })
    }

    // MARK: - Graph

    /// A type with its extensions (or a function, variable, preview): what the
    /// patch shadows as a whole.
    final class Node {
        let key: String
        let name: String
        let module: String
        var files = Set<String>()
        var chunks: [(file: String, chunk: Chunk)] = []
        var isView = false
        var isPublic = false
        var external = false    // an extension of a type that isn't in the sources
        init(key: String, name: String, module: String) { self.key = key; self.name = name; self.module = module }
    }

    struct Graph {
        var nodes: [String: Node] = [:]
        var deps: [String: Set<String>] = [:]
        var rdeps: [String: Set<String>] = [:]
        var nodeOf: [String: [String: String]] = [:]   // file -> chunk key -> node key
        var chunksByFile: [String: [Chunk]] = [:]
        var moduleOf: [String: String] = [:]
        var visible: [String: Set<String>] = [:]
        var byName: [String: [String]] = [:]           // name -> non-external node keys
        var byMember: [String: [String]] = [:]         // extension member -> external node keys

        /// Nodes `tokens` refer to, from code in `file`.
        func resolve(_ tokens: Set<String>, from file: String, module: String) -> Set<String> {
            var out = Set<String>()
            let canImport = visible[module] ?? []
            for t in tokens {
                if let own = nodes["\(file)#\(t)"] { out.insert(own.key); continue }
                for k in byName[t] ?? [] {
                    guard let n = nodes[k], !k.contains("#") else { continue }
                    if n.module == module || (canImport.contains(n.module) && n.isPublic) { out.insert(k) }
                }
                for k in byMember[t] ?? [] {
                    if let n = nodes[k], n.module == module || canImport.contains(n.module) { out.insert(k) }
                }
            }
            return out
        }
    }

    /// Everything scoping reads, so it can run on sources that aren't on disk.
    struct Input {
        var sources: [String: String] = [:]     // path -> text, the kit and fixtures files excluded
        var moduleOf: [String: String] = [:]    // path -> module; the app module when missing
        var visible: [String: Set<String>] = [:] // module -> modules it can import
        var appModule = "App"
        var fixturesPath = "SimlessFixtures.swift"
        var fixturesText = ""
        var before: [String: String] = [:]      // edited path -> its text as of the last full build
    }

    /// The scope input for a worktree: its sources and local package modules.
    static func input(ws: Workspace, edited: [String]) -> Input {
        let packageModules = Packages.modules(ws: ws)
        var input = Input()
        input.appModule = (try? ws.settings().moduleName) ?? ws.config.appTarget
        input.fixturesPath = "\(ws.root)/\(ws.config.fixturesFile)"
        input.fixturesText = (try? String(contentsOfFile: input.fixturesPath, encoding: .utf8)) ?? ""
        let directDeps = Dictionary(packageModules.map { ($0.name, Set($0.dependencies)) }, uniquingKeysWith: { $0.union($1) })
        input.visible[input.appModule] = Set(packageModules.map(\.name))
        for m in packageModules {
            var seen = Set<String>(), queue = Array(directDeps[m.name] ?? [])
            while let next = queue.popLast() {
                if seen.insert(next).inserted { queue += Array(directDeps[next] ?? []) }
            }
            input.visible[m.name] = seen
        }
        let skip: Set<String> = ["\(ws.root)/\(ws.config.kitFile)", input.fixturesPath]
        let files = Array(Set(ws.swiftSources() + edited)).filter { !skip.contains($0) }
        let texts = Locked<[String: String]>([:])
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            guard let text = try? String(contentsOfFile: files[i], encoding: .utf8) else { return }
            texts.mutate { $0[files[i]] = text }
        }
        input.sources = texts.value
        for f in files { input.moduleOf[f] = Packages.module(of: f, in: packageModules)?.name ?? input.appModule }
        for f in edited { input.before[f] = ws.snapshotText(of: f) }
        return input
    }

    static func graph(_ input: Input) -> Graph {
        var g = Graph()
        g.visible = input.visible
        let files = Array(input.sources.keys)
        let texts = Locked<[String: [Chunk]]>([:])
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let c = chunks(input.sources[files[i]]!)
            texts.mutate { $0[files[i]] = c }
        }
        g.chunksByFile = texts.value
        for f in files { g.moduleOf[f] = input.moduleOf[f] ?? input.appModule }
        let byFile = g.chunksByFile

        // Types declared (non-private) per module, so extensions join their type's node.
        var declared: [String: Set<String>] = [:]
        for (f, cs) in byFile { for c in cs where c.kind == .type && !c.isPrivate { declared[g.moduleOf[f]!, default: []].insert(c.name) } }
        func node(_ key: String, _ name: String, _ module: String) -> Node {
            if let n = g.nodes[key] { return n }
            let n = Node(key: key, name: name, module: module); g.nodes[key] = n; return n
        }
        for (f, cs) in byFile.sorted(by: { $0.key < $1.key }) {
            let module = g.moduleOf[f]!
            let privateTypes = Set(cs.filter { $0.kind == .type && $0.isPrivate }.map(\.name))
            for (i, c) in cs.enumerated() {
                let n: Node
                switch c.kind {
                case .preview:
                    n = node("\(f)##\(i)", c.name, module)
                case .type, .value:
                    n = c.isPrivate ? node("\(f)#\(c.name)", c.name, module) : node("\(module).\(c.name)", c.name, module)
                case .ext:
                    if privateTypes.contains(c.name) { n = node("\(f)#\(c.name)", c.name, module) }
                    else if declared[module]?.contains(c.name) == true { n = node("\(module).\(c.name)", c.name, module) }
                    else if let other = (g.visible[module] ?? []).first(where: { declared[$0]?.contains(c.name) == true }) {
                        n = node("\(other).\(c.name)", c.name, other)
                    } else {
                        n = node("\(f)#ext \(c.name) \(i)", c.name, module)
                        n.external = true
                    }
                }
                n.files.insert(f)
                n.chunks.append((f, c))
                if c.isPublic { n.isPublic = true }
                g.nodeOf[f, default: [:]][c.key] = n.key
            }
        }
        for (k, n) in g.nodes {
            if n.external { for (_, c) in n.chunks { for m in c.members { g.byMember[m, default: []].append(k) } } }
            else if !k.contains("#") { g.byName[n.name, default: []].append(k) }
        }
        // Views: by conformance (to a fixpoint, for the app's own view protocols
        // and view classes), or by building views in code.
        var viewNames = Set<String>()
        var changed = true
        while changed {
            changed = false
            for n in g.nodes.values where !n.isView {
                if n.chunks.contains(where: { $0.chunk.buildsViews || $0.chunk.inherits.contains { isViewName($0) || viewNames.contains($0) } }) {
                    n.isView = true; changed = true
                    if !n.external { viewNames.insert(n.name) }
                }
            }
        }
        for (k, n) in g.nodes {
            var d = Set<String>()
            for (f, c) in n.chunks { d.formUnion(g.resolve(c.tokens, from: f, module: n.module)) }
            d.remove(k)
            g.deps[k] = d
            for x in d { g.rdeps[x, default: []].insert(k) }
        }
        return g
    }

    // MARK: - Fixtures

    /// Each fixture's closure in the fixtures file, as identifiers, with the
    /// file's own helpers it calls folded in. nil when the file doesn't
    /// register fixtures in a form this can read.
    static func fixtureTokens(_ text: String) -> [String: Set<String>]? {
        let clean = code(text)
        let u = Array(clean.utf16), ns = text as NSString
        let add = try! NSRegularExpression(pattern: #"\.add\(\s*"([^"\\]+)""#)
        var out: [String: Set<String>] = [:]
        var claimed: [NSRange] = []
        for m in add.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            // The closure: the first `{` after the call's arguments.
            var i = NSMaxRange(m.range), parens = 1
            while i < u.count, parens > 0 { if u[i] == 40 { parens += 1 } else if u[i] == 41 { parens -= 1 }; i += 1 }
            while i < u.count, u[i] == 32 || u[i] == 10 { i += 1 }
            guard i < u.count, u[i] == 123 else { return nil }
            var depth = 0, j = i
            repeat { if u[j] == 123 { depth += 1 } else if u[j] == 125 { depth -= 1 }; j += 1 } while j < u.count && depth > 0
            let r = NSRange(location: i, length: j - i)
            claimed.append(r)
            out[name, default: []].formUnion(strings(identifier, (clean as NSString).substring(with: r)))
        }
        guard !out.isEmpty else { return nil }
        // The file's helpers (private functions, extensions) that fixtures call.
        let helpers = chunks(text).filter { $0.name != "simlessFixtures" }
        for name in out.keys {
            var tokens = out[name]!, grew = true
            while grew {
                grew = false
                for h in helpers where tokens.contains(h.name) && !h.tokens.isSubset(of: tokens) { tokens.formUnion(h.tokens); grew = true }
            }
            out[name] = tokens
        }
        return out
    }

    /// `text` as empty lines, keeping conditional-compilation lines so the
    /// file's `#if`s still balance.
    static func blank(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return ["#if", "#elseif", "#else", "#endif"].contains { t.hasPrefix($0) } ? line : ""
        }.joined(separator: "\n")
    }

    // MARK: - Scope

    /// The files to patch so `fixtures` (all when nil) render the edits.
    static func files(ws: Workspace, edited: [String], fixtures requested: [String]? = nil) throws -> Scope {
        try scope(input(ws: ws, edited: edited), edited: edited, fixtures: requested)
    }

    static func scope(_ input: Input, edited: [String], fixtures requested: [String]? = nil) throws -> Scope {
        let fixturesPath = input.fixturesPath
        let g = graph(input)
        let editedSet = Set(edited)

        // What each edit changed, declaration by declaration.
        var seeds = Set<String>()
        for file in edited where file != fixturesPath {
            let now = g.chunksByFile[file] ?? []
            let changedKeys: Set<String>
            if let old = input.before[file] { changedKeys = changed(before: chunks(old), now: now) }
            else { changedKeys = Set(now.map(\.key)) }
            for c in now where changedKeys.contains(c.key) {
                let name = (file as NSString).lastPathComponent
                guard let key = g.nodeOf[file]?[c.key], let n = g.nodes[key] else { continue }
                switch c.kind {
                case .ext where n.external:
                    throw SimlessError("patch can't cover this edit: \(name) extends \(c.name), which other code can use without naming an edited type")
                case .value where !c.isPrivate:
                    throw SimlessError("patch can't cover this edit: \(name) declares top-level \(c.name), which other files can use")
                default:
                    seeds.insert(key)
                }
            }
        }

        // Affected nodes: views from views, everything from non-views.
        enum Mode { case view, logic }
        var affected: [String: Mode] = [:]
        var queue: [String] = []
        for s in seeds { affected[s] = g.nodes[s]!.isView ? .view : .logic; queue.append(s) }
        while let x = queue.popLast() {
            let mode = affected[x]!
            for m in g.rdeps[x] ?? [] {
                guard let n = g.nodes[m] else { continue }
                let next: Mode? = n.isView ? .view : (mode == .logic ? .logic : nil)
                guard let next else { continue }
                if affected[m] == nil || (affected[m] == .view && next == .logic) { affected[m] = next; queue.append(m) }
            }
        }

        // Per fixture: the affected nodes on its way to the edit.
        let appModule = input.appModule
        let fixtureText = input.fixturesText
        let perFixture = fixtureTokens(fixtureText) ?? ["*": Set(strings(identifier, code(fixtureText)))]
        var needed: [String: Set<String>] = [:]
        for (name, tokens) in perFixture {
            var seen = g.resolve(tokens, from: fixturesPath, module: appModule).filter { affected[$0] != nil }
            var q = Array(seen)
            while let x = q.popLast() {
                for d in g.deps[x] ?? [] where affected[d] != nil && seen.insert(d).inserted { q.append(d) }
            }
            needed[name] = seen
        }
        let targets: Set<String>
        if let requested, perFixture["*"] == nil, requested.allSatisfy({ perFixture[$0] != nil }) { targets = Set(requested) }
        else { targets = Set(perFixture.keys) }

        // Nodes: what changed and what each target fixture needs. A type is
        // patched whole, extensions in other files included, since the patch's
        // copy needs all its members.
        var patched = seeds
        for t in targets { patched.formUnion(needed[t] ?? []) }
        var all = editedSet.union([fixturesPath])
        for k in patched { all.formUnion(g.nodes[k]!.files) }
        let fixtureNames = perFixture["*"] == nil ? Set(perFixture.keys) : []
        let reach = fixtureNames.filter { !(needed[$0] ?? []).isEmpty || editedSet.contains(fixturesPath) }
        let covered = reach.filter { (needed[$0] ?? []).isSubset(of: patched) }
        if all.count > maxFiles {
            let forWhat = requested.map { " for \($0.joined(separator: ", "))" } ?? ""
            throw SimlessError("patch can't cover this edit: it reaches \(all.count) files between the fixtures and the edit\(forWhat) (limit \(maxFiles))")
        }

        // What the patch compiles of each file: the patched declarations and the
        // file-private ones they use. The rest is blanked (lines and `#if`s kept)
        // and resolves to the app's own copy: a second copy of an extension
        // member would be ambiguous, and an unpatched type would only add work.
        var texts: [String: String] = [:]
        for f in all where f != fixturesPath {
            guard let cs = g.chunksByFile[f], let keys = g.nodeOf[f], let first = cs.first,
                  let text = input.sources[f] else { continue }
            var keep = Set(cs.indices.filter { keys[cs[$0].key].map(patched.contains) ?? false })
            var grew = true
            while grew {
                grew = false
                for i in cs.indices where !keep.contains(i) {
                    guard let k = keys[cs[i].key], let n = g.nodes[k], k.hasPrefix("\(f)#"),
                          n.external ? cs[i].isPrivate : true else { continue }
                    if keep.contains(where: { g.deps[keys[cs[$0].key] ?? ""]?.contains(k) == true }) { keep.insert(i); grew = true }
                }
            }
            let ns = text as NSString
            var out = ns.substring(to: first.start)
            for (i, c) in cs.enumerated() { out += keep.contains(i) ? c.text : blank(c.text) }
            texts[f] = out
        }
        let extra = all.subtracting(editedSet).subtracting([fixturesPath]).sorted()
        return Scope(all: [fixturesPath] + edited.filter { $0 != fixturesPath } + extra, extra: extra,
                     covered: covered.sorted(), stale: reach.subtracting(covered).sorted(), texts: texts)
    }
}
