import Foundation

/// Five band equaliser: low shelf, three peaks, high shelf.
///
/// Placed after the shifter so its curve applies to the voice the listener
/// actually hears. Shaping before the shifter would move the formants around
/// again and undo the correction.
public final class ParametricEQ: AudioProcessor {
    public struct Band: Codable, Equatable, Sendable {
        public var frequency: Float
        public var q: Float
        public var gainDB: Float

        public init(frequency: Float, q: Float = 0.707, gainDB: Float = 0) {
            self.frequency = frequency
            self.q = q
            self.gainDB = gainDB
        }
    }

    public static let defaultBands: [Band] = [
        Band(frequency: 120,  q: 0.707),
        Band(frequency: 400,  q: 1.0),
        Band(frequency: 1200, q: 1.0),
        Band(frequency: 3500, q: 1.0),
        Band(frequency: 8000, q: 0.707),
    ]

    private let filters: [Biquad]
    private let kinds: [Biquad.Kind] = [.lowShelf, .peaking, .peaking, .peaking, .highShelf]
    private var bands: [Band]

    public init(sampleRate: Float) {
        bands = ParametricEQ.defaultBands
        filters = (0..<5).map { _ in Biquad(sampleRate: sampleRate) }
        applyBands()
    }

    /// Not real-time safe: recomputes coefficients. Call from the parameter
    /// update path, not from `process`.
    public func setBands(_ newBands: [Band]) {
        guard newBands.count == bands.count else { return }
        bands = newBands
        applyBands()
    }

    public var currentBands: [Band] { bands }

    private func applyBands() {
        for (index, band) in bands.enumerated() {
            filters[index].configure(
                kind: kinds[index],
                frequency: band.frequency,
                q: band.q,
                gainDB: band.gainDB
            )
        }
    }

    public func reset() {
        filters.forEach { $0.reset() }
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for (index, filter) in filters.enumerated() where bands[index].gainDB != 0 {
            filter.process(buffer, frameCount: frameCount)
        }
    }
}
