import Foundation

/// One encoder configuration for everything written to the defaults: sorted
/// keys, so the same value always produces the same bytes. Without it the key
/// order inside each object varies run to run, every save rewrites the plist
/// with a "different" blob, and byte-equality checks are flaky.
enum StableJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
