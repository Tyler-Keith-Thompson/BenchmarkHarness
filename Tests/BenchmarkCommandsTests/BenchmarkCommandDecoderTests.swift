// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import BenchmarkCommands
import BenchmarkHarnessTestSupport
import Foundation
import PropertyBased
import Testing

@Suite("BenchmarkCommandDecoder")
struct BenchmarkCommandDecoderTests {
    @Test("No bytes, a partial length, and a partial body each decode to nothing yet")
    func incomplete() throws {
        var decoder = BenchmarkCommandDecoder()
        #expect(try decoder.next() == nil)
        let frame = Data([10, 0, 0, 0, 0, 0, 0, 0]) + Data(#"{"end":{}}"#.utf8)
        decoder.append(frame.prefix(5))
        #expect(try decoder.next() == nil)
        decoder.append(frame.dropFirst(5).prefix(8))
        #expect(try decoder.next() == nil)
        decoder.append(frame.dropFirst(13))
        #expect(try decoder.next() == .end)
        #expect(try decoder.next() == nil)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("Several frames in one chunk decode in order")
    func severalFrames() throws {
        func frame(_ json: String) -> Data {
            withUnsafeBytes(of: Int64(json.utf8.count).littleEndian) { Data($0) } + Data(json.utf8)
        }
        var decoder = BenchmarkCommandDecoder()
        decoder.append(frame(#"{"ready":{}}"#) + frame(#"{"run":{}}"#) + frame(#"{"end":{}}"#))
        let expected: [BenchmarkCommandReply] = [.ready, .run, .end]
        var decoded: [BenchmarkCommandReply] = []
        while let reply = try decoder.next() {
            decoded.append(reply)
        }
        #expect(decoded == expected)
    }

    @Test("A negative or oversized length throws MalformedBenchmarkCommand")
    func badLengths() {
        let negative = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let oversized = withUnsafeBytes(of: Int64(BenchmarkCommandDecoder.maximumFrameLength + 1).littleEndian) { Data($0) }
        for prefix in [negative, oversized] {
            var decoder = BenchmarkCommandDecoder()
            decoder.append(prefix)
            #expect(throws: MalformedBenchmarkCommand()) {
                try decoder.next()
            }
        }
    }

    @Test("A frame of the maximum length is not rejected for its length")
    func maximumLength() throws {
        var decoder = BenchmarkCommandDecoder()
        decoder.append(withUnsafeBytes(of: Int64(BenchmarkCommandDecoder.maximumFrameLength).littleEndian) { Data($0) })
        #expect(try decoder.next() == nil)
    }

    @Test("A frame whose JSON is not a reply throws MalformedBenchmarkCommand")
    func badBody() {
        var decoder = BenchmarkCommandDecoder()
        decoder.append(Data([2, 0, 0, 0, 0, 0, 0, 0]) + Data("{}".utf8))
        #expect(throws: MalformedBenchmarkCommand()) {
            try decoder.next()
        }
    }

    @Test("Replies decode the same however the stream is split into chunks", .tags(.randomized))
    func chunkingIsInvisible() async {
        let kinds = Gen.int(in: 0 ... 3).array(of: 0 ... 20)
        let cuts = Gen.int(in: 1 ... 40).array(of: 1 ... 60)
        await propertyCheck(count: 300, input: kinds, cuts) { kinds, cuts in
            let messages = [#"{"ready":{}}"#, #"{"run":{}}"#, #"{"end":{}}"#, #"{"error":{"_0":"failed"}}"#]
            let replies: [BenchmarkCommandReply] = [.ready, .run, .end, .error("failed")]
            var stream = Data()
            for kind in kinds {
                let json = Data(messages[kind].utf8)
                stream += withUnsafeBytes(of: Int64(json.count).littleEndian) { Data($0) } + json
            }
            var decoder = BenchmarkCommandDecoder()
            var decoded: [BenchmarkCommandReply] = []
            var remaining = stream[...]
            var cutIndex = 0
            while !remaining.isEmpty {
                let size = cuts[cutIndex % cuts.count]
                cutIndex += 1
                decoder.append(remaining.prefix(size))
                remaining = remaining.dropFirst(size)
                while let reply = try? decoder.next() {
                    decoded.append(reply)
                }
            }
            #expect(decoded == kinds.map { replies[$0] })
        }
    }
}
