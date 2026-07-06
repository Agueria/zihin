import CoreGraphics
import Foundation

/// k-means renk paleti + TR isimli renk eşleme (spec §5). Saf algoritma, $0.
enum ColorService {
    struct RGB { var r: Float; var g: Float; var b: Float }

    static func dominantColorNames(cgImage: CGImage, k: Int = 5) -> [String] {
        let pixels = samplePixels(cgImage, maxDim: 64)
        guard !pixels.isEmpty else { return [] }
        let centers = kMeans(pixels, k: min(k, pixels.count), iterations: 8)
        var seen = Set<String>(); var out: [String] = []
        for c in centers {
            let n = NamedColors.nearest(r: c.r, g: c.g, b: c.b)
            if seen.insert(n).inserted { out.append(n) }
        }
        return out
    }

    private static func samplePixels(_ img: CGImage, maxDim: Int) -> [RGB] {
        let scale = Float(maxDim) / Float(max(img.width, img.height))
        let w = max(1, Int(Float(img.width) * scale))
        let h = max(1, Int(Float(img.height) * scale))
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [RGB] = []; out.reserveCapacity(w * h)
        var i = 0
        while i < data.count {
            out.append(RGB(r: Float(data[i]), g: Float(data[i+1]), b: Float(data[i+2])))
            i += 4
        }
        return out
    }

    static func kMeans(_ pts: [RGB], k: Int, iterations: Int) -> [RGB] {
        guard k > 0, !pts.isEmpty else { return [] }
        var centers = (0..<k).map { pts[$0 * pts.count / k] }
        for _ in 0..<iterations {
            var sums = Array(repeating: RGB(r: 0, g: 0, b: 0), count: k)
            var counts = Array(repeating: 0, count: k)
            for p in pts {
                var best = 0; var bestD = Float.greatestFiniteMagnitude
                for (j, c) in centers.enumerated() {
                    let d = (p.r-c.r)*(p.r-c.r) + (p.g-c.g)*(p.g-c.g) + (p.b-c.b)*(p.b-c.b)
                    if d < bestD { bestD = d; best = j }
                }
                sums[best].r += p.r; sums[best].g += p.g; sums[best].b += p.b
                counts[best] += 1
            }
            for j in 0..<k where counts[j] > 0 {
                centers[j] = RGB(r: sums[j].r / Float(counts[j]),
                                 g: sums[j].g / Float(counts[j]),
                                 b: sums[j].b / Float(counts[j]))
            }
        }
        return centers
    }
}

/// İsimli renkler (TR). Arama sorgusundaki renk kelimeleriyle aynı küme.
enum NamedColors {
    static let palette: [(name: String, r: Float, g: Float, b: Float)] = [
        ("siyah", 0, 0, 0), ("beyaz", 255, 255, 255), ("gri", 128, 128, 128),
        ("kırmızı", 220, 30, 30), ("turuncu", 240, 140, 20), ("sarı", 240, 220, 40),
        ("yeşil", 40, 170, 70), ("mavi", 40, 90, 210), ("lacivert", 20, 30, 110),
        ("mor", 130, 60, 180), ("pembe", 240, 120, 170), ("kahverengi", 120, 75, 40),
        ("bej", 225, 200, 160), ("turkuaz", 40, 190, 190)]

    static func nearest(r: Float, g: Float, b: Float) -> String {
        var best = palette[0].name
        var bestD = Float.greatestFiniteMagnitude
        for c in palette {
            let d = (r-c.r)*(r-c.r) + (g-c.g)*(g-c.g) + (b-c.b)*(b-c.b)
            if d < bestD { bestD = d; best = c.name }
        }
        return best
    }
}
