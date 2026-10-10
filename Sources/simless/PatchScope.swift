// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Decides which files a hot-reload patch must contain so that every fixture
/// renders the edited code, or that a patch can't be trusted at all.
///
/// A patch's copies of edited types only take effect where the patch itself
/// constructs them. An unedited view that embeds an edited view is still the
/// app's compiled code and would keep rendering the *old* subview. So the patch
/// also includes every file on a path from the fixtures file to an edited file
/// (by type-name references). Edits that other code can observe without naming
/// an edited type (extensions of other types, non-private top-level functions or
/// variables) can't be traced this way and require a full build. The analysis
/// over-approximates on purpose: an extra file costs compile time, a missing one
/// costs a wrong render.
enum PatchScope {
    static let maxFiles = 40

    /// Top-level type declarations only. Nested helper types (`Kind`, `Style`,
    /// `State`, ...) share generic names across files and would connect almost
    /// everything; code outside their file names them through the outer type
    /// (`Outer.Kind`), which already creates an edge to the outer type's file.
    private static let typeDecl = try! NSRegularExpression(
        pattern: #"^(?:@[\w.]+(?:\([^\n]*?\))?\s+)*((?:(?:public|internal|private|fileprivate|open|final|nonisolated|indirect)\s+)*)(?:struct|class|enum|actor|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
        options: .anchorsMatchLines)
    /// Comments and string literals, removed before collecting identifiers so a
    /// word in a doc comment or a label doesn't look like a type reference.
    private static let nonCode = try! NSRegularExpression(
        pattern: ##"//[^\n]*|/\*[\s\S]*?\*/|#?"""[\s\S]*?"""#?|"(?:\\.|[^"\\\n])*""##)
    private static let identifier = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)
    /// Declarations at column 0 (file scope), with their modifiers.
    private static let topLevel = try! NSRegularExpression(
        pattern: #"^(?:@[\w.]+(?:\([^\n]*?\))?\s+)*((?:(?:public|internal|private|fileprivate|open|final|nonisolated|indirect)\s+)*)(extension|func|var|let|struct|class|enum|actor|protocol|typealias)\s+([A-Za-z_][\w.]*)"#,
        options: .anchorsMatchLines)
    private static let keywords: Set<String> = ["func", "var", "let", "init", "subscript", "case", "where", "some", "any"]

    struct Source {
        let path: String
        let declared: Set<String>         // top-level types
        let publicDeclared: Set<String>   // top-level public/open types, visible to other modules
        let tokens: Set<String>           // identifiers in code (not comments or strings)
        let text: String
        var module = ""                   // owning module: the app target or a package module
    }

    private static func matches(_ re: NSRegularExpression, _ s: String, group: Int) -> [String] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: group), in: s).map { String(s[$0]) }
        }
    }

    static func load(_ path: String) -> Source? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var declared = Set<String>(), publicDeclared = Set<String>()
        for m in typeDecl.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let modsR = Range(m.range(at: 1), in: text), let nameR = Range(m.range(at: 2), in: text) else { continue }
            let name = String(text[nameR]), mods = String(text[modsR])
            guard !keywords.contains(name) else { continue }
            declared.insert(name)
            if mods.contains("public") || mods.contains("open") { publicDeclared.insert(name) }
        }
        let code = nonCode.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        return Source(path: path, declared: declared, publicDeclared: publicDeclared,
                      tokens: Set(matches(identifier, code, group: 0)), text: text)
    }

    /// Throws when an edited file declares something the type graph can't track.
    private static func checkTraceable(_ edited: [Source]) throws {
        let editedTypes = edited.reduce(into: Set<String>()) { $0.formUnion($1.declared) }
        for src in edited {
            let s = src.text
            for m in topLevel.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let modsR = Range(m.range(at: 1), in: s), let kindR = Range(m.range(at: 2), in: s),
                      let nameR = Range(m.range(at: 3), in: s) else { continue }
                let mods = String(s[modsR]), kind = String(s[kindR])
                let name = String(s[nameR]).split(separator: "<").first.map(String.init) ?? ""
                let file = (src.path as NSString).lastPathComponent
                switch kind {
                case "extension":
                    let base = name.split(separator: ".").first.map(String.init) ?? name
                    if !editedTypes.contains(base) {
                        throw SimlessError("patch can't cover this edit: \(file) extends \(name), which other code can use without naming an edited type")
                    }
                case "func", "var", "let":
                    if !(mods.contains("private") || mods.contains("fileprivate")) {
                        throw SimlessError("patch can't cover this edit: \(file) declares top-level \(kind) \(name), which other files can use")
                    }
                default:
                    break   // type declarations are traced through the graph
                }
            }
        }
    }

    /// The edited files, the fixtures file, and every file between them.
    /// Returns the full list and the extra files pulled in.
    static func files(ws: Workspace, edited: [String]) throws -> (all: [String], extra: [String]) {
        let fixturesPath = "\(ws.root)/\(ws.config.fixturesFile)"
        let kitPath = "\(ws.root)/\(ws.config.kitFile)"
        let packageModules = Packages.modules(ws: ws)
        let appModule = (try? ws.settings().moduleName) ?? ws.config.appTarget
        var sources = ws.swiftSources().filter { $0 != kitPath }.compactMap(load)
        for i in sources.indices { sources[i].module = Packages.module(of: sources[i].path, in: packageModules)?.name ?? appModule }
        // Which modules each module can import: a package module its declared
        // dependencies (transitively); the app target any package module.
        let directDeps = Dictionary(packageModules.map { ($0.name, Set($0.dependencies)) }, uniquingKeysWith: { $0.union($1) })
        var visible: [String: Set<String>] = [appModule: Set(packageModules.map(\.name))]
        for m in packageModules {
            var seen = Set<String>(), queue = Array(directDeps[m.name] ?? [])
            while let next = queue.popLast() {
                if seen.insert(next).inserted { queue += Array(directDeps[next] ?? []) }
            }
            visible[m.name] = seen
        }
        let byPath = Dictionary(uniqueKeysWithValues: sources.map { ($0.path, $0) })
        let editedSet = Set(edited)
        try checkTraceable(edited.compactMap { byPath[$0] })

        // deps[f]: files whose types f can see and mentions. Within a module any
        // top-level type; across modules only public ones, along import edges.
        var deps: [String: Set<String>] = [:]
        var rdeps: [String: Set<String>] = [:]
        for f in sources {
            let canImport = visible[f.module] ?? []
            for g in sources where g.path != f.path {
                let names = g.module == f.module ? g.declared : (canImport.contains(g.module) ? g.publicDeclared : [])
                if !names.isDisjoint(with: f.tokens) {
                    deps[f.path, default: []].insert(g.path)
                    rdeps[g.path, default: []].insert(f.path)
                }
            }
        }
        func closure(from start: Set<String>, _ edges: [String: Set<String>]) -> Set<String> {
            var seen = start, queue = Array(start)
            while let next = queue.popLast() {
                for n in edges[next] ?? [] where seen.insert(n).inserted { queue.append(n) }
            }
            return seen
        }
        let reachedByFixtures = closure(from: [fixturesPath], deps)
        let reachingEdits = closure(from: editedSet, rdeps)
        let between = reachedByFixtures.intersection(reachingEdits)
        let all = editedSet.union([fixturesPath]).union(between)
        if all.count > maxFiles {
            throw SimlessError("patch can't cover this edit: it reaches \(all.count) files between the fixtures and the edit (limit \(maxFiles))")
        }
        let extra = all.subtracting(editedSet).subtracting([fixturesPath]).sorted()
        return ([fixturesPath] + edited.filter { $0 != fixturesPath } + extra, extra)
    }
}
