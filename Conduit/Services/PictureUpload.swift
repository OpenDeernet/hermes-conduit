import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture a message sends Hermes as an image (#1265). A full-size
/// photo is 3 to 4 MB, about 5 MB as base64 in one socket frame, and on a
/// slow link Hermes' own socket ping times out behind it and drops the
/// connection. Models take about 2,000 px per picture at most, so a larger
/// one goes as a JPEG of that size, a fraction of the bytes. A picture
/// already that small, or an animated one, goes as it is.
enum PictureUpload {
    static let maxPixelSize = 2048
    static let jpegQuality = 0.85

    struct Prepared: Equatable {
        let data: Data
        let filename: String
        let mimeType: String
    }

    /// The bytes and name to send, or nil when the picture goes unchanged.
    static func resized(_ data: Data, filename: String) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maxPixelSize else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Upright, so the EXIF orientation the JPEG drops is applied.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length < data.count else { return nil }
        let stem = (filename as NSString).deletingPathExtension
        return Prepared(
            data: output as Data,
            filename: (stem.isEmpty ? "image" : stem) + ".jpg",
            mimeType: "image/jpeg"
        )
    }
}
