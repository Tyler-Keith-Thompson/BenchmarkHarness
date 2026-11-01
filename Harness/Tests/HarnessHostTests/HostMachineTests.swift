// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import Foundation
import HarnessHost
import Testing

@Suite("HostMachine")
struct HostMachineTests {
    @Test("output returns what the command writes to standard output")
    func output() async throws {
        let data = try await HostMachine().output(["printf", "%s", "counted"])
        let expected = "counted"
        #expect(String(decoding: data, as: UTF8.self) == expected)
    }

    @Test("A command sees the environment it is given, on top of the harness's own")
    func environment() async throws {
        let data = try await HostMachine().output(["/bin/sh", "-c", "printf %s \"$HARNESS_TEST_VALUE\""], environment: ["HARNESS_TEST_VALUE=a=b"])
        let expected = "a=b"
        #expect(String(decoding: data, as: UTF8.self) == expected)
    }

    @Test("check throws MachineCommandFailed with the command's exit code")
    func checkFails() async throws {
        let expectedCode: Int32 = 3
        let error = await #expect(throws: MachineCommandFailed.self) {
            try await HostMachine().check(["/bin/sh", "-c", "exit 3"])
        }
        #expect(error?.exitCode == expectedCode)
    }

    @Test("run returns the exit code, and 128 plus the signal for a command a signal ended")
    func exitCodes() async throws {
        let machine = HostMachine()
        let zero: Int32 = 0
        let seven: Int32 = 7
        let killed: Int32 = 128 + 9
        #expect(try await machine.run(["true"]) == zero)
        #expect(try await machine.run(["/bin/sh", "-c", "exit 7"]) == seven)
        #expect(try await machine.run(["/bin/sh", "-c", "kill -9 $$"]) == killed)
    }

    @Test("A command that exits while its input is still open ends its output and returns its code")
    func exitsWithInputOpen() async throws {
        let (input, inputContinuation) = AsyncStream.makeStream(of: Data.self)
        let (output, outputContinuation) = AsyncStream.makeStream(of: Data.self)
        async let code = HostMachine().run(["/bin/sh", "-c", "exit 4"], environment: [], input: input, output: outputContinuation)
        var chunks = 0
        for await _ in output { chunks += 1 }
        let expectedCode: Int32 = 4
        #expect(try await code == expectedCode)
        #expect(chunks == 0)
        inputContinuation.finish()
    }

    @Test("Input streams to the command and its output streams back, chunk by chunk, until the input ends")
    func streams() async throws {
        let (input, inputContinuation) = AsyncStream.makeStream(of: Data.self)
        let (output, outputContinuation) = AsyncStream.makeStream(of: Data.self)
        async let code = HostMachine().run(["cat"], environment: [], input: input, output: outputContinuation)
        var received = Data()
        var replies = output.makeAsyncIterator()
        for line in ["first\n", "second\n"] {
            inputContinuation.yield(Data(line.utf8))
            // Each reply arrives before the next request is sent, as the runner protocol needs.
            while !String(decoding: received, as: UTF8.self).hasSuffix(line), let chunk = await replies.next() {
                received += chunk
            }
        }
        inputContinuation.finish()
        while let chunk = await replies.next() { received += chunk }
        let expected = "first\nsecond\n"
        let zero: Int32 = 0
        #expect(String(decoding: received, as: UTF8.self) == expected)
        #expect(try await code == zero)
    }

    @Test("A command that exits without reading its input still ends, and its input is dropped")
    func unreadInput() async throws {
        let (input, inputContinuation) = AsyncStream.makeStream(of: Data.self)
        inputContinuation.yield(Data(repeating: 0x61, count: 1 << 20))
        let zero: Int32 = 0
        #expect(try await HostMachine().run(["true"], environment: [], input: input, output: nil) == zero)
        inputContinuation.finish()
    }
}
