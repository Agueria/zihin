import XCTest
@testable import Zihin

/// Saf algoritma testleri (spec §11). Xcode'da Unit Test target'ı ekleyip
/// bu dosyayı içine al (SETUP_MAC.md §7).
final class AlgorithmTests: XCTestCase {

    func testVectorStoreRoundtripAndCosine() {
        let v: [Float] = [0.1, -0.5, 2.0]
        XCTAssertEqual(VectorStore.decode(VectorStore.encode(v)), v)
        XCTAssertEqual(VectorStore.cosine(v, v), 1.0, accuracy: 0.0001)
        XCTAssertEqual(VectorStore.cosine([1, 0], [0, 1]), 0.0, accuracy: 0.0001)
        XCTAssertEqual(VectorStore.cosine([], []), 0)
        XCTAssertEqual(VectorStore.cosine([1, 2], [1, 2, 3]), 0)  // boyut uyuşmazlığı
    }

    func testKeywordServiceFiltersStopwords() {
        let kws = KeywordService.keywords(
            "SwiftUI ile cihaz üstü makine öğrenmesi ve vektör arama altyapısı")
        XCTAssertFalse(kws.isEmpty)
        XCTAssertFalse(kws.joined(separator: " ").split(separator: " ").contains("ve"))
    }

    func testSummaryShorterThanInputAndNonEmpty() {
        let text = """
        Birinci cümle giriş yapıyor. İkinci cümle vektör arama sistemini anlatıyor. \
        Üçüncü cümle vektör arama ve embedding ilişkisini kuruyor. \
        Dördüncü cümle embedding boyutlarından bahsediyor. Beşinci cümle alakasız bir detay veriyor.
        """
        let s = SummaryService.summarize(text, n: 2)
        XCTAssertFalse(s.isEmpty)
        XCTAssertLessThan(s.count, text.count)
    }

    func testQueryParserExtractsColorAndDate() {
        let q = SearchQueryParser.parse("mavi sneaker dün")
        XCTAssertEqual(q.colors, ["mavi"])
        XCTAssertNotNil(q.dateRange)
        XCTAssertEqual(q.cleaned, "sneaker")

        let plain = SearchQueryParser.parse("react state")
        XCTAssertTrue(plain.colors.isEmpty)
        XCTAssertNil(plain.dateRange)
        XCTAssertEqual(plain.cleaned, "react state")
    }

    func testNamedColorsNearest() {
        XCTAssertEqual(NamedColors.nearest(r: 250, g: 250, b: 250), "beyaz")
        XCTAssertEqual(NamedColors.nearest(r: 210, g: 40, b: 40), "kırmızı")
        XCTAssertEqual(NamedColors.nearest(r: 45, g: 95, b: 205), "mavi")
    }

    func testKMeansReturnsRequestedCenters() {
        let pts = (0..<100).map {
            ColorService.RGB(r: Float($0 % 2) * 255, g: 0, b: 0)
        }
        let centers = ColorService.kMeans(pts, k: 2, iterations: 5)
        XCTAssertEqual(centers.count, 2)
        XCTAssertEqual(ColorService.kMeans([], k: 3, iterations: 3).count, 0)
    }

    func testObsidianMarkdownFrontmatter() {
        var item = Item(type: .note, textContent: "İçerik")
        item.title = "Deneme Notu"
        let md = ObsidianExporter.markdown(item, tags: ["swift", "ml"],
                                           dateFormatter: ISO8601DateFormatter())
        XCTAssertTrue(md.hasPrefix("---\n"))
        XCTAssertTrue(md.contains("tags: [swift, ml]"))
        XCTAssertTrue(md.contains("# Deneme Notu"))
        XCTAssertTrue(ObsidianExporter.fileName(item).hasSuffix(".md"))
    }
}
