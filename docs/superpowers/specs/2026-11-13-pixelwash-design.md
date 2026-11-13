# Pixelwash design

Date: 2026-11-13. Status: awaiting approval.

## Intent

Pixelwash is a personal-use equivalent of [Dangerzone](https://dangerzone.rocks) for
Apple silicon Macs. It takes an untrusted PDF, office document or image and
produces a clean PDF that is safe to open.

It works the way Dangerzone does: the document is opened only inside an isolated
Linux sandbox, every page is flattened to raw pixels, and a new PDF is rebuilt
from those pixels on the Mac. Anything the original was hiding (scripts, macros,
embedded files, malformed fonts, metadata) does not survive.

The difference from Dangerzone is the sandbox. Pixelwash uses Apple's
Containerization framework, which runs each container in its own lightweight
virtual machine. It does not use podman, Docker or gVisor.

## Goals

- Convert PDF, Office, OpenDocument, RTF and common image formats to a safe PDF.
- A command-line tool (`pixelwash`) and a drag-and-drop Mac app (`Pixelwash.app`)
  that share one core library.
- A fresh virtual machine for every document, destroyed afterwards.
- Optional searchable text in the output, using Apple's Vision OCR on the Mac.
- Runs without any background service and without Homebrew at run time.

## Non-goals

- Other platforms, Intel Macs, or macOS older than 26.
- Distribution to other people: no notarisation, installer or auto-update.
- Finder extensions, folder watching, or a menu-bar item.
- Formats Dangerzone itself treats as extras (HWP, e-books).

## Anti-goals

These would make the tool a failure even if it appears to work:

- The Mac side parsing the untrusted document in any way. It reads the file as
  bytes and passes them to the sandbox. No Quick Look, no thumbnail, no content
  sniffing.
- Any network access from the sandbox.
- Reusing a virtual machine or any writable state between documents.
- Trusting anything the sandbox says beyond a strictly validated pixel stream.

## Constraints

- macOS 27, Xcode 27.2, Swift 6.4 on Apple silicon (the machine it is built for).
- Containerization Swift package pinned to exactly `0.54.0`. The API is young
  and has changed a lot between releases, so upgrades are deliberate.
- Binaries need the `com.apple.security.virtualization` entitlement. Ad-hoc
  signing is enough for personal use.

## Approaches considered

**A. Embed the Containerization Swift package (chosen).** The app and CLI boot
the virtual machine themselves through the Swift API. No background service;
tight control over networking, mounts and how data crosses the boundary. Costs:
entitlement signing, a one-time kernel and init-image download, and a young API.

**B. Drive the installed `container` command.** Much less code and a more
stable interface, but depends on the Homebrew install and its background
service, with less control over the boundary.

**C. Apple's lower-level Virtualization framework with a hand-built guest.**
Rejected: it reinvents what Containerization already provides.

Kenrick chose A. A throwaway test on 2026-11-13 confirmed it works on this Mac:
with no network device and a read-only root filesystem, a container took 5 MB on
standard input and streamed 20 MB back on standard output, in about 2 seconds
once images were cached.

## How it works

```
 Mac (trusted)                              Linux VM (untrusted, no network)
 ─────────────                              ────────────────────────────────
 read file as bytes ───── stdin ──────────▶ converter:
                                              detect type
                                              office → PDF (LibreOffice)
                                              PDF/image → pixels (MuPDF)
 validate stream  ◀────── stdout ────────── page count, then per page:
 OCR (Vision, optional)                       width, height, raw RGB
 build PDF (Core Graphics)
 write <name>-safe.pdf                      VM destroyed
```

### Parts

1. **Sandbox image** (`image/`). A Debian-slim Linux image containing
   LibreOffice (headless), PyMuPDF, libmagic, a base font set, and a small
   Python converter. Built once on the Mac with `container build`, exported as
   an OCI archive, and loaded into Pixelwash's own image store.
2. **`PixelwashCore`** (Swift library). The sandbox runner, the pixel-stream
   parser, the PDF builder, OCR, and first-run setup.
3. **`pixelwash`** (CLI). Built on swift-argument-parser.
4. **`Pixelwash.app`** (SwiftUI). A thin window over the core library.

### The sandbox

Each conversion creates a new container with:

- no network interface (loopback only);
- the image's root filesystem mounted read-only, shared by all runs, so nothing
  persists and start-up needs no unpacking;
- a size-limited in-memory `/tmp` as the only writable space;
- an unprivileged user, no capabilities, and no-new-privileges;
- 2 CPUs and 4 GB of memory;
- no shared folders: the document goes in on standard input and pixels come
  out on standard output.

The container is stopped and deleted when the conversion ends, fails, is
cancelled, or exceeds its time limit. The time limit scales with input size,
with a floor of 2 minutes.

### The pixel stream

The same shape as Dangerzone's protocol. All integers are big-endian unsigned
16-bit.

```
page_count
repeat page_count times:
    width  height  (width × height × 3 bytes of RGB)
```

The Mac-side parser is the trust boundary and is deliberately strict:

- page count between 1 and 10,000;
- width and height between 1 and 10,000;
- exactly the expected number of bytes per page, and nothing after the last page;
- any violation, a non-zero exit, or a timeout fails the whole conversion and
  no output file is written.

Standard error from the sandbox is used only for a debug log. It is
length-limited and stripped to printable ASCII before being shown.

Pages render at 150 DPI, as in Dangerzone.

### Rebuilding the PDF

Pages are processed one at a time as they arrive, so memory stays flat for long
documents. Each page becomes an image drawn into a Core Graphics PDF context at
its original physical size.

When OCR is on, Vision recognises text in the page image and Pixelwash draws it
as an invisible text layer under the image, so the PDF is searchable and
selectable. Vision only ever sees pixels that passed validation.

The output is written to a temporary file and moved into place only on success.

### First-run setup

Stored in `~/Library/Application Support/Pixelwash/`:

- a Linux kernel, downloaded once from the pinned Kata Containers release that
  Apple's own tooling uses, and checked against a SHA-256 recorded in the source;
- Apple's init image `ghcr.io/apple/containerization/vminit:0.54.0`, pulled once;
- the sandbox image, loaded from the archive that `make image` produced.

`pixelwash setup` does this explicitly. The app runs the same step with a
progress display the first time it is opened.

## Command line

```
pixelwash convert <file>... [--output <path>] [--no-ocr] [--jpeg <quality>]
pixelwash setup [--image <oci-archive>]
pixelwash doctor
```

- Default output is `<name>-safe.pdf` beside the original. An existing file is
  never overwritten; a number is appended instead.
- The original is never modified, moved or deleted.
- `--output` is allowed only with a single input file.
- Exit status is 0 only if every file converted.
- `doctor` reports whether the kernel, init image and sandbox image are present
  and boots a trivial container to prove the sandbox works.

## The app

One window:

```
┌──────────────────────────────────────────────┐
│  Pixelwash                                   │
│  ┌────────────────────────────────────────┐  │
│  │                                        │  │
│  │     Drop documents here, or Choose…    │  │
│  │                                        │  │
│  └────────────────────────────────────────┘  │
│  report.docx      ● Converting page 3 of 12  │
│  invoice.pdf      ✓ Safe PDF saved    Show   │
│  scan.tiff        ✗ Failed: timed out        │
│                                              │
│  ☑ Make text searchable (OCR)                │
│  ☐ Open safe PDF when done                   │
└──────────────────────────────────────────────┘
```

- Files can be dropped on the window or the Dock icon, chosen with a file
  picker, or sent with Finder's "Open With".
- Documents convert one at a time, in order.
- "Show" reveals the safe PDF in Finder.
- The app never previews or opens the original.

## Decisions made by Claude, for Kenrick to check

- **Name:** Pixelwash.
- **Location:** `~/Documents/Projects/pixelwash`, local git repo, not pushed.
- **Lossless by default.** Pages are stored without lossy compression so text
  stays crisp. `--jpeg <quality>` trades quality for smaller files.
- **OCR on by default** in both the CLI and the app.
- **Build system:** Swift Package Manager plus a Makefile. The `.app` bundle is
  assembled and ad-hoc signed by a script, so there is no Xcode project file.
- **Type detection happens inside the sandbox**, not on the Mac.
- **Building the sandbox image uses the installed `container` tool**, which
  needs its background service running during the build only
  (`container system start`). Nothing depends on it afterwards.
- **Image upkeep is manual.** `make image` rebuilds with current Debian
  security updates; the README says to do this periodically.

## Testing

- Unit tests for the pixel-stream parser, including truncated streams, extra
  trailing bytes, zero and oversized dimensions, and oversized page counts.
- Unit tests for the PDF builder: page count, page size, and that OCR text is
  findable in the output.
- Integration tests that run real conversions of small fixture files (PDF,
  DOCX, PNG) and check page counts.
- A hostile-sandbox test: a converter that emits garbage must produce a clean
  failure and no output file.
- A sandbox property test: from inside the container, confirm there is no
  network route and the root filesystem cannot be written.

## Left to the builder

- Module layout inside `PixelwashCore`.
- The exact Debian package list and fonts.
- How progress is reported from core to the CLI and app.
- Per-page time-limit arithmetic.
