import XCTest
@testable import Zihin

/// F0 (spec §5) — merkezlenmiş embedding temelinin SAF (model gerektirmeyen) testleri.
/// Model-bağımlı ayrışma/zero-shot kapıları golden set ile Mac'te ölçülür (§2.4/§2.5).
final class EmbeddingFoundationTests: XCTestCase {

    // MARK: Chunking (§2.6/§4.1c)

    func testShortTextIsSingleChunk() {
        let chunks = Chunker.chunks("kısa bir not", targetTokens: 200)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, "kısa bir not")
    }

    func testLongTextSplitsIntoBoundedWindows() {
        let words = (0..<1000).map { "w\($0)" }.joined(separator: " ")
        let chunks = Chunker.chunks(words, targetTokens: 200)
        XCTAssertEqual(chunks.count, 5)                       // 1000 / 200
        for c in chunks {
            XCTAssertLessThanOrEqual(c.split(separator: " ").count, 200)
        }
    }

    func testEmptyTextYieldsNoChunks() {
        XCTAssertTrue(Chunker.chunks("   \n ").isEmpty)
    }

    // MARK: Pooling (§4.1c)

    func testMaxPoolTakesElementwiseMaximum() {
        let pooled = Pooling.maxPool([[1, 5, 2], [3, 0, 9]])
        XCTAssertEqual(pooled, [3, 5, 9])
    }

    func testMeanPoolAveragesElementwise() {
        let pooled = Pooling.meanPool([[2, 4, 6], [4, 8, 12]])
        XCTAssertEqual(pooled, [3, 6, 9])
    }

    func testPoolingEmptyInputIsEmpty() {
        XCTAssertTrue(Pooling.maxPool([]).isEmpty)
        XCTAssertTrue(Pooling.meanPool([]).isEmpty)
    }

    // MARK: Merkezleme / μ (§2.4/§4.1b)

    func testBlendWithNoUserDataReturnsMu0() {
        let mu0: [Float] = [0.1, 0.2, 0.3]
        let blended = CenteringStore.blend(userSum: [0, 0, 0], count: 0, mu0: mu0, k: 50)
        XCTAssertEqual(blended, mu0)
    }

    func testBlendFormula() {
        // μ = (Σv + k·μ₀)/(n+k). Σv=[10], n=10, μ₀=[0], k=50 → 10/60
        let blended = CenteringStore.blend(userSum: [10], count: 10, mu0: [0], k: 50)
        XCTAssertEqual(blended[0], 10.0 / 60.0, accuracy: 1e-6)
    }

    func testBlendConvergesToUserMeanWhenNDominatesK() {
        // n≫k: harmanlanmış μ ≈ μ_user = Σv/n
        let n = 100_000
        let blended = CenteringStore.blend(userSum: [Float(n) * 0.7], count: n, mu0: [0.0], k: 50)
        XCTAssertEqual(blended[0], 0.7, accuracy: 1e-3)
    }

    func testCenteringSubtractsMuAndRestoresSelfSimilarity() {
        let mu: [Float] = [0.5, 0.5, 0.5]
        let v: [Float] = [0.9, 0.4, 0.6]
        let centered = CorpusMean(mu: mu).center(v)
        XCTAssertEqual(centered, [0.4, -0.1, 0.1].map { Float($0) })
        // Aynı vektörün merkezlenmiş cosine'i 1'e yakın (kendisiyle).
        XCTAssertEqual(Centered.cosine(v, v, mu: mu), 1.0, accuracy: 1e-4)
    }

    func testCenteringWithMismatchedMuIsNoOp() {
        // μ boşsa (henüz donmamış) merkezleme ham cosine'e düşer, çökmez.
        let v: [Float] = [1, 0, 0]
        XCTAssertEqual(Centered.cosine(v, v, mu: []), 1.0, accuracy: 1e-4)
    }
}
