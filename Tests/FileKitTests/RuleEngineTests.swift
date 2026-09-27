import XCTest
@testable import FileKit

final class RuleEngineTests: TempDirTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    private func subject(_ name: String, type: String? = nil, size: Int64 = 100, ageDays: Double = 0,
                         from: [String] = [], dir: Bool = false, in folder: URL? = nil) -> RuleSubject {
        RuleSubject(url: (folder ?? root).appending(path: name), isDirectory: dir, contentType: type, size: size,
                    dateAdded: now.addingTimeInterval(-ageDays * day), whereFroms: from)
    }

    private func rule(_ match: RuleMatch, _ action: RuleAction = .trash, enabled: Bool = true) -> Rule {
        Rule(name: "r", enabled: enabled, match: match, action: action)
    }

    func testConditions() {
        let pdf = subject("Invoice March.PDF", type: "com.adobe.pdf", size: 2_000, ageDays: 10,
                          from: ["https://dl.bank.example.com/x.pdf", "https://bank.example.com/"])
        func m(_ match: RuleMatch) -> Bool { RuleEngine.matches(rule(match), pdf, now: now) }

        XCTAssertTrue(m(RuleMatch(extensions: ["pdf"])))
        XCTAssertTrue(m(RuleMatch(extensions: [".PDF", "doc"])))
        XCTAssertFalse(m(RuleMatch(extensions: ["png"])))
        XCTAssertTrue(m(RuleMatch(types: ["public.data"])))            // conformance, not equality
        XCTAssertFalse(m(RuleMatch(types: ["public.image"])))
        XCTAssertTrue(m(RuleMatch(nameRegex: "^invoice")))
        XCTAssertFalse(m(RuleMatch(nameRegex: "receipt")))
        XCTAssertTrue(m(RuleMatch(minAgeDays: 7)))
        XCTAssertFalse(m(RuleMatch(minAgeDays: 30)))
        XCTAssertTrue(m(RuleMatch(sourceDomains: ["example.com"])))    // subdomains match
        XCTAssertFalse(m(RuleMatch(sourceDomains: ["ample.com"])))     // but not suffixes of labels
        XCTAssertTrue(m(RuleMatch(minSize: 1_000, maxSize: 2_000)))
        XCTAssertFalse(m(RuleMatch(maxSize: 1_999)))
        XCTAssertTrue(m(RuleMatch(extensions: ["pdf"], folders: [root.path])))
        XCTAssertFalse(m(RuleMatch(extensions: ["pdf"], folders: [root.appending(path: "elsewhere").path])))
        // AND across conditions.
        XCTAssertFalse(m(RuleMatch(extensions: ["pdf"], minAgeDays: 30)))
        // Empty and disabled rules never match.
        XCTAssertFalse(m(RuleMatch()))
        XCTAssertFalse(m(RuleMatch(folders: [root.path])))
        XCTAssertFalse(RuleEngine.matches(rule(RuleMatch(extensions: ["pdf"]), enabled: false), pdf, now: now))
        // Folders only when asked.
        let folder = subject("Invoices", dir: true)
        XCTAssertFalse(RuleEngine.matches(rule(RuleMatch(nameRegex: "voice")), folder, now: now))
        XCTAssertTrue(RuleEngine.matches(rule(RuleMatch(nameRegex: "voice", includeFolders: true)), folder, now: now))
    }

    func testFirstMatchWinsAndPlans() throws {
        let pictures = try makeDir("Pictures")
        let rules = [
            Rule(name: "Screenshots", match: RuleMatch(nameRegex: "^Screenshot"), action: .move(to: pictures.path)),
            Rule(name: "Images", match: RuleMatch(types: ["public.image"]), action: .tag(["Red"])),
            Rule(name: "Old DMGs", match: RuleMatch(extensions: ["dmg"], minAgeDays: 7), action: .trash),
            Rule(name: "Number PDFs", match: RuleMatch(extensions: ["pdf"]), action: .rename(template: "Doc {n:2}")),
        ]
        let engine = RuleEngine(rules: rules)
        let subjects = [
            subject("Screenshot 1.png", type: "public.png"),
            subject("cat.jpg", type: "public.jpeg"),
            subject("installer.dmg", ageDays: 8),
            subject("new.dmg", ageDays: 1),
            subject("a.pdf"), subject("b.pdf"),
        ]
        let plans = engine.evaluate(subjects, now: now)
        XCTAssertEqual(plans.map(\.ruleName), ["Screenshots", "Images", "Old DMGs", "Number PDFs", "Number PDFs"])
        XCTAssertEqual(plans.map(\.operation), [
            .move(from: subjects[0].url, to: pictures.appending(path: "Screenshot 1.png")),
            .setTags(subjects[1].url, ["Red"]),
            .trash(subjects[2].url),
            .rename(from: subjects[4].url, to: root.appending(path: "Doc 01.pdf")),
            .rename(from: subjects[5].url, to: root.appending(path: "Doc 02.pdf")),
        ])
        XCTAssertTrue(plans.allSatisfy { $0.problem == nil })
    }

    func testPlanSkipsNoOpsAndFlagsProblems() throws {
        let engine = RuleEngine(rules: [
            Rule(name: "Here", match: RuleMatch(extensions: ["txt"]), action: .move(to: root.path)),
            Rule(name: "Missing", match: RuleMatch(extensions: ["zip"]), action: .move(to: root.appending(path: "nope").path)),
            Rule(name: "Target", match: RuleMatch(extensions: ["md"]), action: .move(to: "target:Nowhere")),
            Rule(name: "Tagged", match: RuleMatch(extensions: ["png"]), action: .tag(["Red"])),
        ])
        var png = subject("x.png")
        png.tags = ["Red"]
        let plans = engine.evaluate([subject("a.txt"), subject("a.zip"), subject("a.md"), png], now: now)
        XCTAssertEqual(plans.map(\.ruleName), ["Missing", "Target"])
        XCTAssertNotNil(plans[0].problem)
        XCTAssertNotNil(plans[1].problem)
    }

    func testTargetsResolveByName() throws {
        let docs = try makeDir("Docs")
        let engine = RuleEngine(rules: [Rule(name: "t", match: RuleMatch(extensions: ["pdf"]), action: .move(to: "target:docs"))],
                                targets: [Target(name: "Docs", url: docs)])
        XCTAssertEqual(engine.evaluate([subject("a.pdf")], now: now).first?.operation,
                       .move(from: root.appending(path: "a.pdf"), to: docs.appending(path: "a.pdf")))
    }

    func testSubjectFromDiskReadsWhereFroms() throws {
        let file = try makeFile("setup.zip")
        try WhereFroms.write(["https://objects.githubusercontent.com/abc", "https://github.com/x/y"], to: file)
        let s = RuleSubject(url: file)
        XCTAssertEqual(WhereFroms.domains(s.whereFroms), ["objects.githubusercontent.com", "github.com"])
        XCTAssertTrue(RuleEngine.matches(rule(RuleMatch(sourceDomains: ["github.com"])), s))
        XCTAssertFalse(s.isDirectory)
        XCTAssertNotNil(s.dateAdded)
    }

    func testApplyIsOneUndoableGroup() throws {
        let service = FileActionService()
        let journal = UndoJournal(service: service)
        let dest = try makeDir("dest")
        try makeFile("dest/a.txt", contents: "old")
        let a = try makeFile("a.txt", contents: "new"), b = try makeFile("b.log"), c = try makeFile("c.md")
        let engine = RuleEngine(rules: [
            Rule(name: "txt", match: RuleMatch(extensions: ["txt"]), action: .move(to: dest.path)),
            Rule(name: "log", match: RuleMatch(extensions: ["log"]), action: .trash),
            Rule(name: "md", match: RuleMatch(extensions: ["md"]), action: .tag(["Blue"])),
        ])
        let plans = engine.evaluate([a, b, c].map { RuleSubject(url: $0) })
        let ops = try RuleEngine.apply(plans, service: service, onCollision: .keepBoth)
        track(ops)
        journal.record(ops, name: "Apply Rules")
        XCTAssertEqual(read(dest.appending(path: "a 2.txt")), "new")
        XCTAssertFalse(exists(b))
        XCTAssertEqual(try FileTags.read(c), ["Blue"])

        let undone = try journal.undo()
        XCTAssertEqual(undone?.name, "Apply Rules")
        XCTAssertTrue(exists(a) && exists(b))
        XCTAssertEqual(try FileTags.read(c), [])
    }

    func testRuleSetJSON() throws {
        let json = """
        {"version": 1, "autoApply": true, "watch": ["~/Downloads"],
         "rules": [
          {"name": "Installers", "match": {"extensions": ["dmg", "pkg"], "minAgeDays": 14}, "action": {"type": "trash"}},
          {"name": "Papers", "match": {"sourceDomains": ["arxiv.org"]}, "action": {"type": "move", "target": "Reading"}},
          {"name": "Shots", "enabled": false, "match": {"nameRegex": "^Screenshot"}, "action": {"type": "rename", "template": "{date} {name}"}},
          {"name": "Work", "match": {"types": ["public.image"], "minSize": 10}, "action": {"type": "tag", "tags": ["Work"]}}
         ]}
        """
        let set = try JSONDecoder().decode(RuleSet.self, from: Data(json.utf8))
        XCTAssertTrue(set.autoApply)
        XCTAssertEqual(set.watchURLs, [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads").normalizedFileURL])
        XCTAssertEqual(set.rules.map(\.action), [.trash, .move(to: "target:Reading"), .rename(template: "{date} {name}"), .tag(["Work"])])
        XCTAssertFalse(set.rules[2].enabled)

        let store = RuleStore(fileURL: root.appending(path: "rules.json"))
        try store.save(set)
        XCTAssertEqual(try store.load(), set)
        XCTAssertTrue(try String(contentsOf: store.fileURL, encoding: .utf8).contains(#""target" : "Reading""#))

        try Data("{nope".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try RuleStore(fileURL: root.appending(path: "missing.json")).load(), RuleSet())
        XCTAssertThrowsError(try RuleEngine(rules: [Rule(name: "bad", match: RuleMatch(nameRegex: "("))]).validate())
    }
}
