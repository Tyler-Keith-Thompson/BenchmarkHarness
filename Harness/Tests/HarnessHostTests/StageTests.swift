// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import Foundation
import HarnessHost
import Testing

@Suite("stage.sh")
struct StageTests {
    @Test("Staging the same file names keeps SwiftPM's cached plan; adding, removing or renaming a file deletes it")
    func cachedPlan() async throws {
        let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/HarnessHost/Guest/stage.sh").standardized.path
        let root = FileManager.default.temporaryDirectory.appending(path: "stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let sources = source.appending(path: "Sources/Module")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("let a = 1\n".utf8).write(to: sources.appending(path: "A.swift"))
        let destination = root.appending(path: "work/source").path
        let scratch = root.appending(path: "scratch")
        let plan = scratch.appending(path: "aarch64-unknown-linux-gnu/release/description.json")
        let manifest = scratch.appending(path: "release.yaml")
        let machine = HostMachine()
        func stage() async throws {
            try await machine.check(["/bin/bash", script, source.path, destination, scratch.path])
        }
        func plant() throws {
            try FileManager.default.createDirectory(at: plan.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: plan)
            try Data("".utf8).write(to: manifest)
        }
        func planned() -> Bool {
            FileManager.default.fileExists(atPath: plan.path) && FileManager.default.fileExists(atPath: manifest.path)
        }

        try await stage()
        #expect(FileManager.default.fileExists(atPath: "\(destination)/Sources/Module/A.swift"))
        try plant()
        try Data("let a = 2\n".utf8).write(to: sources.appending(path: "A.swift"))
        try await stage()
        #expect(planned(), "an edited file keeps the plan")

        try Data("let b = 1\n".utf8).write(to: sources.appending(path: "B.swift"))
        try await stage()
        #expect(!planned(), "an added file deletes the plan")

        try plant()
        try await stage()
        #expect(planned(), "the same names again keep the plan")

        try FileManager.default.moveItem(at: sources.appending(path: "B.swift"), to: sources.appending(path: "C.swift"))
        try await stage()
        #expect(!planned(), "a renamed file deletes the plan")

        try plant()
        try FileManager.default.removeItem(at: sources.appending(path: "C.swift"))
        try await stage()
        #expect(!planned(), "a removed file deletes the plan")
    }
}
