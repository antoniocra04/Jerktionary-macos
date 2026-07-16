import XCTest
@testable import Jerktionary

final class QuestionDetectorTests: XCTestCase {
    func testLatestQuestionFindsLastQuestionMark() {
        let text = "Привет. Что такое замыкание? Понятно. А как работает event loop?"
        XCTAssertEqual(QuestionDetector.latestQuestion(in: text), "А как работает event loop?")
    }

    func testLatestQuestionInterrogativeWithoutMark() {
        let text = "Хорошо. Расскажи про хуки в реакте."
        XCTAssertEqual(QuestionDetector.latestQuestion(in: text), "Расскажи про хуки в реакте")
    }

    func testLatestQuestionNilForPlainStatement() {
        XCTAssertNil(QuestionDetector.latestQuestion(in: "Сегодня хорошая погода."))
    }

    func testForcedQuestionTakesLastTwoSentences() {
        let text = "Первое. Второе. Третье."
        XCTAssertEqual(QuestionDetector.forcedQuestion(in: text), "Второе. Третье")
    }

    func testQuestionKeyStripsFillerAndPunctuation() {
        let a = QuestionDetector.questionKey("Что такое REST?")
        let b = QuestionDetector.questionKey("А что такое REST")
        let c = QuestionDetector.questionKey("Ну а что такое  REST?!")
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
    }

    func testLastSentence() {
        XCTAssertEqual(
            QuestionDetector.lastSentence(in: "Одно. Другое дело…"),
            "Другое дело"
        )
    }
}

final class TermMergerTests: XCTestCase {
    private func term(_ text: String, _ start: Int, _ end: Int) -> TranscriptTerm {
        TranscriptTerm(text: text, normalized: text.lowercased(), start: start, end: end, type: "concept", confidence: 0.9)
    }

    func testMergeDeduplicatesByKey() {
        let a = term("REST", 0, 4)
        let merged = TermMerger.merge([a], [a])
        XCTAssertEqual(merged.count, 1)
    }

    func testOverlapPrefersLongerSpan() {
        let text = "event loop работает"
        let short = term("event", 0, 5)
        let long = term("event loop", 0, 10)
        let segments = TermMerger.highlightSegments(text: text, terms: [short, long])
        let termSegments = segments.compactMap { segment -> TranscriptTerm? in
            if case .term(_, let value) = segment { return value }
            return nil
        }
        XCTAssertEqual(termSegments.map(\.text), ["event loop"])
    }

    func testSegmentsCoverWholeText() {
        let text = "изучаем docker и kubernetes"
        let terms = [term("docker", 8, 14), term("kubernetes", 17, 27)]
        let segments = TermMerger.highlightSegments(text: text, terms: terms)
        let joined = segments.map { segment in
            switch segment {
            case .text(let value, _): value
            case .term(let value, _): value
            }
        }.joined()
        XCTAssertEqual(joined, text)
    }

    func testInvalidSpansDropped() {
        let text = "abc"
        let segments = TermMerger.highlightSegments(text: text, terms: [term("zzz", 10, 20)])
        XCTAssertEqual(segments.count, 1)
    }
}

final class PCMTests: XCTestCase {
    func testInt16ConversionBounds() {
        let data = PCM.int16LEData(from: [1.0, -1.0, 0], sourceSampleRate: 16_000)
        XCTAssertEqual(data.count, 6)
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(values[0], Int16(littleEndian: 0x7FFF))
        XCTAssertEqual(values[1], Int16(bitPattern: 0x8000).littleEndian)
        XCTAssertEqual(values[2], 0)
    }

    func testResampleHalvesLength() {
        let input = [Float](repeating: 0.5, count: 4800)
        let output = PCM.resampleLinear(input, from: 48_000, to: 16_000)
        XCTAssertEqual(output.count, 1600)
    }

    func testChunkAccumulator() {
        var chunks: [[Float]] = []
        let accumulator = ChunkAccumulator(chunkSize: 4) { chunks.append($0) }
        accumulator.append([1, 2, 3])
        XCTAssertTrue(chunks.isEmpty)
        accumulator.append([4, 5])
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], [1, 2, 3, 4])
    }

    func testRmsLevel() {
        XCTAssertEqual(PCM.rmsLevel([]), 0)
        XCTAssertEqual(PCM.rmsLevel([0.25, 0.25, 0.25, 0.25]), 1.0, accuracy: 0.0001)
    }
}

final class BackendClientHelperTests: XCTestCase {
    func testParsePointsStripsBullets() {
        let points = BackendClient.parsePoints("- один\n• два\n* три\n\n")
        XCTAssertEqual(points, ["один", "два", "три"])
    }

    func testTermContextCentersOnTerm() {
        let text = String(repeating: "a", count: 100) + "TERM" + String(repeating: "b", count: 100)
        let context = BackendClient.termContext(text, term: "term", size: 20)
        XCTAssertTrue(context.contains("TERM"))
        XCTAssertLessThanOrEqual(context.count, 20)
    }

    func testTermContextFallsBackToTail() {
        let text = String(repeating: "x", count: 50)
        let context = BackendClient.termContext(text, term: "missing", size: 10)
        XCTAssertEqual(context.count, 10)
    }
}

final class WsEventParsingTests: XCTestCase {
    func testTranscriptUpdateParsing() throws {
        let json = """
        {"type":"transcript_update","text":"привет","is_final":true,
         "terms":[{"text":"привет","normalized":"привет","start":0,"end":6,"type":"noun","confidence":0.8}]}
        """
        let event = BackendWsEvent.parse(Data(json.utf8))
        guard case .transcriptUpdate(let text, let isFinal, let terms) = event else {
            return XCTFail("wrong event")
        }
        XCTAssertEqual(text, "привет")
        XCTAssertTrue(isFinal)
        XCTAssertEqual(terms.count, 1)
    }

    func testMalformedTermsAreDropped() {
        let json = """
        {"type":"terms_update","items":[{"bad":"shape"},{"text":"t","normalized":"t","start":0,"end":1,"type":"noun","confidence":1}]}
        """
        let event = BackendWsEvent.parse(Data(json.utf8))
        guard case .termsUpdate(let items) = event else {
            return XCTFail("wrong event")
        }
        XCTAssertEqual(items.count, 1)
    }

    func testUnknownEventIsNil() {
        XCTAssertNil(BackendWsEvent.parse(Data("{\"type\":\"nope\"}".utf8)))
    }
}
