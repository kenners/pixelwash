# Pixelwash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A CLI and Mac app that convert untrusted documents to safe PDFs by rendering them to pixels inside a per-document Linux VM.

**Architecture:** One Swift package. `PixelwashCore` owns the sandbox runner (Containerization), a strict incremental pixel-stream parser, a Core Graphics PDF writer with a Vision OCR text layer, and first-run setup. `pixelwash` (CLI) and `PixelwashApp` (SwiftUI) are thin front ends. The sandbox image is built separately from `image/`.

**Tech Stack:** Swift 6.2 tools, Containerization 0.54.0, swift-argument-parser, Swift Testing, Core Graphics, Vision, SwiftUI; Debian, LibreOffice, PyMuPDF, python-magic inside the image.

**Spec:** `docs/superpowers/specs/2026-11-13-pixelwash-design.md`

## Global Constraints

- Platform floor `.macOS("26.0")`, arm64 only.
- `containerization` pinned `exact: "0.54.0"`; init image `ghcr.io/apple/containerization/vminit:0.54.0`.
- Every executable is ad-hoc signed with `com.apple.security.virtualization`.
- The Mac side never parses the input document: bytes in, validated pixels out.
- No network interface, read-only rootfs, no shared folders, fresh container per document.
- Support directory: `~/Library/Application Support/Pixelwash/`.
- Stream limits: pages 1…10,000; width and height 1…10,000; 150 DPI.
- Output `<name>-safe.pdf`, never overwrite, written to a temp file then moved.

## Review Focus

1. Empty or unsupported input file → clean "unsupported or empty document" failure, no output. (Task 5 integration test.)
2. Cancel mid-conversion (Ctrl-C, app quit) → container stopped and its directory removed. (Task 5: cancellation test.)
3. Very long documents → memory stays flat; pages handled one at a time. (Task 1: parser yields pages incrementally from arbitrary chunking.)
4. Output folder not writable or name clash → clear error / numbered name, original untouched. (Task 3 tests.)
5. Password-protected PDF → clean failure naming the cause. (Task 4 converter exit code; Task 5 maps it.)

---

## File map

| Path | Responsibility |
|---|---|
| `Package.swift`, `Makefile`, `.gitignore` | build |
| `Resources/pixelwash.entitlements`, `Resources/Info.plist` | signing, app bundle |
| `scripts/make-app.sh` | assemble and sign `Pixelwash.app` |
| `image/Containerfile`, `image/doc_to_pixels.py` | sandbox image |
| `Sources/PixelwashCore/PixelStream.swift` | stream parser (trust boundary) |
| `Sources/PixelwashCore/SafePDFWriter.swift` | pixels → PDF pages |
| `Sources/PixelwashCore/TextRecognizer.swift` | Vision OCR |
| `Sources/PixelwashCore/OutputNaming.swift` | safe output paths |
| `Sources/PixelwashCore/SupportPaths.swift` | support directory layout |
| `Sources/PixelwashCore/Setup.swift` | kernel, init image, sandbox image, rootfs |
| `Sources/PixelwashCore/Sandbox.swift` | run one container |
| `Sources/PixelwashCore/Converter.swift` | orchestrate one conversion |
| `Sources/pixelwash/*.swift` | CLI |
| `Sources/PixelwashApp/*.swift` | SwiftUI app |
| `Tests/PixelwashCoreTests/*.swift` | unit and integration tests |

## Shared interfaces

```swift
public struct PixelPage: Sendable { public let index: Int; public let width: Int; public let height: Int; public let rgb: Data }
public enum PixelStreamError: Error, Equatable {
    case invalidPageCount(Int), invalidDimensions(page: Int, width: Int, height: Int)
    case truncated, trailingData
}
public struct PixelStreamParser {            // incremental, chunk-agnostic
    public static let maxPages = 10_000, maxDimension = 10_000
    public private(set) var pageCount: Int?
    public mutating func consume(_ chunk: Data) throws -> [PixelPage]
    public func finish() throws              // throws .truncated unless complete
}
public struct RecognizedText: Sendable { public let string: String; public let box: CGRect } // box normalised, origin bottom-left
public enum TextRecognizer { public static func recognize(_ image: CGImage) throws -> [RecognizedText] }
public final class SafePDFWriter {
    public init(url: URL, jpegQuality: Double?) throws
    public func append(_ page: PixelPage, text: [RecognizedText]) throws   // page size = pixels × 72 / 150 pt
    public func close()
}
public enum OutputNaming { public static func safeURL(for input: URL, explicit: URL?) throws -> URL }
public struct ConversionOptions: Sendable { public var ocr = true; public var jpegQuality: Double? = nil; public var output: URL? = nil }
public enum ConversionEvent: Sendable { case starting, page(Int, of: Int), finished(URL) }
public enum ConversionError: Error, LocalizedError { case notSetUp(String), unsupportedDocument, encrypted, tooLarge, timedOut, sandboxFailed(Int32, String), badStream(PixelStreamError), output(String) }
public actor Converter {
    public init(paths: SupportPaths = .default)
    public func convert(_ input: URL, options: ConversionOptions, progress: @Sendable (ConversionEvent) -> Void) async throws -> URL
}
public enum Setup {
    public static func status(_ paths: SupportPaths) -> [(name: String, ok: Bool)]
    public static func run(_ paths: SupportPaths, imageArchive: URL?, log: @Sendable (String) -> Void) async throws
}
```

Converter exit codes (image → host): `0` ok, `2` unsupported or empty, `3` encrypted, `4` too many pages or page too large, anything else → `sandboxFailed`.

---

### Task 1: Scaffold and pixel-stream parser

**Files:** `Package.swift`, `.gitignore`, `Sources/PixelwashCore/PixelStream.swift`, `Tests/PixelwashCoreTests/PixelStreamTests.swift`

- [ ] Write failing tests: a valid 2-page stream fed one byte at a time yields 2 pages with correct sizes; page count `0` and `10_001` throw `.invalidPageCount`; width `0` and `10_001` throw `.invalidDimensions`; one extra byte after the last page throws `.trailingData`; `finish()` before completion throws `.truncated`.
- [ ] `swift test` fails to compile.
- [ ] Implement the parser as a small state machine over a byte buffer.
- [ ] `swift test` passes. Commit.

### Task 2: PDF writer and OCR

**Files:** `SafePDFWriter.swift`, `TextRecognizer.swift`, `Tests/.../SafePDFWriterTests.swift`

- [ ] Failing tests: writing two pages of 300×150 px gives a PDF with 2 pages of 144×72 pt; a page rendered with the text "PIXELWASH 2026" in large black type, run through `TextRecognizer` and `SafePDFWriter`, gives a PDF whose `PDFDocument.string` contains `PIXELWASH`; with `jpegQuality: 0.5` a noisy page produces a smaller file than lossless.
- [ ] Implement. Text layer: for each `RecognizedText`, draw the string with `CGTextDrawingMode.invisible`, font size scaled so its width matches the box.
- [ ] Tests pass. Commit.

### Task 3: Output naming

**Files:** `OutputNaming.swift`, `Tests/.../OutputNamingTests.swift`

- [ ] Failing tests: `a/report.docx` → `a/report-safe.pdf`; if that exists → `a/report-safe 2.pdf`; a file with no extension → `name-safe.pdf`; an explicit URL that exists throws; an explicit URL in a missing folder throws.
- [ ] Implement, tests pass. Commit.

### Task 4: Sandbox image

**Files:** `image/Containerfile`, `image/doc_to_pixels.py`, `Makefile` (`image` target)

- [ ] `doc_to_pixels.py`: read stdin to `/tmp/in`; detect MIME with libmagic; office types → `soffice --headless --convert-to pdf` with `HOME=/tmp`; open with PyMuPDF; reject encrypted (exit 3), zero pages or unknown type (exit 2), more than 10,000 pages or a page over 10,000 px at 150 DPI (exit 4); write the stream to stdout page by page.
- [ ] `Containerfile`: `debian:trixie-slim`; packages `libreoffice-writer libreoffice-calc libreoffice-impress python3-pymupdf python3-magic fonts-liberation fonts-dejavu fonts-noto-core fonts-noto-cjk`; user `sanitiser` (uid 1000); `ENTRYPOINT ["/usr/bin/python3","/usr/local/bin/doc_to_pixels.py"]`.
- [ ] `make image` runs `container build -t pixelwash-sandbox:latest image/` then `container image save` to `build/pixelwash-sandbox.tar`.
- [ ] Verify: `container run --rm -i pixelwash-sandbox < fixture.pdf | head -c 2 | xxd` shows the page count. Commit.

### Task 5: Setup, sandbox runner, converter

**Files:** `SupportPaths.swift`, `Setup.swift`, `Sandbox.swift`, `Converter.swift`, `Tests/.../IntegrationTests.swift`, `Tests/.../Fixtures/`

- [ ] `Setup.run`: download kernel (pinned Kata 3.17.0 arm64 archive, SHA-256 constant, extract `vmlinux.container`); pull init image; extract and `ImageStore.load` the sandbox archive; unpack it once to `rootfs.ext4`.
- [ ] `Sandbox.run(input: Data, onStdout:, timeout:)`: container per spec (no interfaces, rootfs mounted `ro`, tmpfs `/tmp` 1 GiB, uid 1000, no capabilities, `noNewPrivileges`, 2 CPUs, 4 GiB); always stop and delete, including on cancellation and timeout. Timeout = max(120 s, 120 s + 1 s per 100 KiB of input).
- [ ] `Converter.convert`: parser → optional OCR → writer → move into place; map exit codes; delete temp file on any failure.
- [ ] Integration tests (skipped unless set up, enabled by `PIXELWASH_INTEGRATION=1`): PDF, DOCX and PNG fixtures convert with the expected page counts; an empty file throws `.unsupportedDocument` and leaves no output; a task cancelled mid-conversion leaves no container directory; a container running `ip route; touch /x` shows no default route and a read-only error.
- [ ] Hostile-stream test (no VM needed): feed the converter's stream handler garbage and assert `.badStream` and no output file.
- [ ] Tests pass. Commit.

### Task 6: CLI

**Files:** `Sources/pixelwash/Pixelwash.swift`, `Makefile` (`build`, `install`)

- [ ] Subcommands `convert`, `setup`, `doctor` as in the spec. `--output` with more than one input is a validation error. Exit 1 if any file failed.
- [ ] `make build` builds release and signs with the entitlement.
- [ ] Verify by converting the three fixtures from the command line. Commit.

### Task 7: App

**Files:** `Sources/PixelwashApp/*.swift`, `Resources/Info.plist`, `scripts/make-app.sh`, `Makefile` (`app`)

- [ ] Window per the spec sketch: drop zone, file picker, queue list with per-item status, OCR and open-when-done toggles (persisted with `@AppStorage`), first-run setup sheet. Sequential queue. Accept files from Dock drops and "Open With" (`CFBundleDocumentTypes` for `public.data`).
- [ ] `make app` builds, assembles `build/Pixelwash.app`, signs it.
- [ ] Verify by launching, converting a fixture, and screenshotting. Commit.

### Task 8: README

- [ ] `README.md`: what it is, security model and limits, build and install steps, updating the image, uninstall. Commit.
