import ArgumentParser
import UniformTypeIdentifiers
import Vision
import VisionKit

struct CommandError: Error {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

struct Page: Codable {
    let size: Size
    let items: [Item]
}

struct Size: Codable {
    let width: Int
    let height: Int
}

struct Item: Codable {
    let text: String
    let rect: Rect?
}

struct Rect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

@main
struct Command: AsyncParsableCommand {
    @Flag(name: .shortAndLong, help: "Overwrite existing files.")
    var force: Bool = false

    @Flag(name: .shortAndLong, help: "Output PNG files (for debugging).")
    var png: Bool = false

    @Flag(name: .shortAndLong, help: "Output JSON files.")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Output text files. Default to true if there are no other textual outputs (i.e., JSON).")
    var text: Bool? = nil

    @Option(name: .shortAndLong, help: "Scale factor to render PDF pages as images. Larger values may improve text recognition accuracy.")
    var ratio: Double = 2.0

    @Option(name: .shortAndLong, help: "Locales to recognize.")
    var locales: [String] = []

    @Option(name: .shortAndLong, help: "Start page number (1-based, inclusive).")
    var start: Int? = nil

    @Option(name: .shortAndLong, help: "End page number (1-based, inclusive).")
    var end: Int? = nil

    @Option(name: .shortAndLong, help: "Output directory.", completion: .directory)
    var out: String = "out"

    @Argument(help: "Input PDF file.", completion: .file(extensions: [".pdf"]))
    var input: String

    mutating func run() async throws {
        let text = text ?? !json

        let out = URL(filePath: out)
        let input = URL(filePath: input)

        let data = try Data(contentsOf: input)

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw CommandError("Failed to initialize CGDataProvider.")
        }

        guard let document = CGPDFDocument(provider) else {
            throw CommandError("Failed to initialize CGPDFDocument.")
        }

        let analyzer = ImageAnalyzer()
        var configuration = ImageAnalyzer.Configuration(.text)

        if !locales.isEmpty {
            configuration.locales = locales
        }

        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        } catch CocoaError.fileWriteFileExists {
            // ignore
        } catch {
            throw error
        }

        let options = force ? [] : Data.WritingOptions.withoutOverwriting

        let n = document.numberOfPages

        let start = start.map { max(1, min(n + 1, $0)) } ?? 1
        let end = end.map { max(start, min(n + 1, $0 + 1)) } ?? n + 1

        for i in start..<end {
            guard let page = document.page(at: i) else {
                throw CommandError("Failed to get page: \(i)")
            }

            let box = page.getBoxRect(.mediaBox)

            let width = Int(ceil(box.width * ratio))
            let height = Int(ceil(box.height * ratio))
            
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw CommandError("Failed to initialize CGColorSpace.")
            }

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw CommandError("Failed to initialize CGContext.")
            }

            context.setFillColor(.white)
            context.fill([CGRect(x: 0, y: 0, width: width, height: height)])

            context.scaleBy(x: ratio, y: ratio)
            context.drawPDFPage(page)

            guard let image = context.makeImage() else {
                throw CommandError("Failed to make an image.")
            }

            if png {
                let file = out.appending(component: "\(i).png")

                guard let data = CFDataCreateMutable(nil, 0) else {
                    throw CommandError("Failed to initialize CFData.")
                }

                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                    throw CommandError("Failed to initialize CGImageDestination.")
                }

                CGImageDestinationAddImage(destination, image, nil)

                if !CGImageDestinationFinalize(destination) {
                    throw CommandError("Failed to finalize CGImageDestination.")
                }

                try (data as Data).write(to: file, options: options)
            }
            
            if json {
                let file = out.appending(component: "\(i).json")

                let handler = VNImageRequestHandler(cgImage: image)
                let request = VNRecognizeTextRequest()

                if locales.isEmpty {
                    request.automaticallyDetectsLanguage = true
                } else {
                    request.recognitionLanguages = locales
                }

                try handler.perform([request])

                guard let results = request.results else {
                    throw CommandError("VNRecognizedTextObservation.results is nil.")
                }

                let items = try results.compactMap({ $0.topCandidates(1).first }).compactMap({ result in
                    let text = result.string

                    let rect = try result.boundingBox(for: text.startIndex..<text.endIndex).map {
                        VNImageRectForNormalizedRect($0.boundingBox, image.width, image.height)
                    }.map {
                        Rect(x: $0.minX, y: Double(image.height) - $0.maxY, width: $0.width, height: $0.height)
                    }

                    return Item(text: text, rect: rect)
                })

                let page = Page(size: Size(width: image.width, height: image.height), items: items)

                let data = try JSONEncoder().encode(page)
                try data.write(to: file, options: options)
            }

            if text {
                let file = out.appending(component: "\(i).txt")

                let analysis = try await analyzer.analyze(image, orientation: .up, configuration: configuration)

                guard let data = analysis.transcript.data(using: .utf8) else {
                    throw CommandError("Failed to encode a string to UTF8.")
                }

                try data.write(to: file, options: options)
            }

            print("DONE: \(i)/\(n)")
        }
    }
}
