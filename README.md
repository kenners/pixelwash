# Pixelwash

Pixelwash turns an untrusted PDF, office document or image into a clean PDF that
is safe to open. It is a personal-use take on [Dangerzone](https://dangerzone.rocks)
for Apple silicon Macs, built on Apple's
[Containerization](https://github.com/apple/containerization) framework instead
of podman or Docker.

## How it works

1. The document is read as raw bytes and sent into a brand-new Linux virtual
   machine. The Mac never parses it.
2. Inside the VM, LibreOffice and MuPDF render every page to raw pixels.
3. The Mac checks the pixel stream strictly, then rebuilds a new PDF from it.
   With OCR on, Apple's Vision adds an invisible, searchable text layer.
4. The VM is destroyed.

Scripts, macros, embedded files, odd fonts and metadata in the original do not
survive, because only pixels cross the boundary.

Each VM has:

- no network device (loopback only);
- a read-only system disk shared by all runs;
- an in-memory `/tmp` as its only writable space;
- an unprivileged user with no capabilities;
- no shared folders: the document goes in on standard input and pixels come out
  on standard output.

`pixelwash doctor` boots a sandbox and checks each of these, plus that a stuck,
misbehaving or cancelled sandbox is stopped and leaves nothing behind.

### Limits

- The safe PDF is a picture of each page. Links, form fields, bookmarks and
  attachments are gone. Text is selectable only through OCR, which can misread.
- Pages are stored losslessly by default, so outputs can be much larger than
  the original. Use `--jpeg 0.8` for smaller files.
- A malicious document could still attack LibreOffice or MuPDF inside the VM.
  The protection is that the VM has nothing to steal and nowhere to send it, and
  that an escape would need a hypervisor bug as well. Keep the image updated.
- Password-protected documents, files over 256 MB, and documents over 10,000
  pages are rejected.
- This is not notarised or audited software. It is for personal use.

## Requirements

- Apple silicon Mac, macOS 26 or later, Xcode 26 or later.
- Apple's [`container`](https://github.com/apple/container) tool, used once to
  build the sandbox image. It is not needed to run Pixelwash.

## Build and install

```bash
container system start      # only needed while building the image
make image                  # builds build/pixelwash-sandbox.tar
container system stop
make setup                  # kernel (290 MB download), init image, sandbox image
make install                # ~/.local/bin/pixelwash and /Applications/Pixelwash.app
```

`make setup` stores everything in `~/Library/Application Support/Pixelwash`
(about 1.5 GB).

## Use

Command line:

```bash
pixelwash report.docx                 # writes report-safe.pdf beside it
pixelwash a.pdf b.xlsx c.png          # several at once
pixelwash scan.pdf -o clean.pdf       # choose the output path
pixelwash big.pdf --jpeg 0.8 --no-ocr # smaller, no text layer
pixelwash doctor                      # check the installation and isolation
```

App: open Pixelwash, then drop documents on the window or the Dock icon, use
**Choose…**, or use Finder's **Open With**. Documents convert one at a time.

The original is never changed, and an existing file is never overwritten: a
second conversion writes `report-safe 2.pdf`.

The very first conversion after a new build can take a minute or more while
macOS prepares its OCR model. After that a typical document takes a few seconds.

Supported inputs: PDF; Word, Excel, PowerPoint (old and new formats);
OpenDocument text, spreadsheet, presentation and drawing; RTF, plain text, CSV;
PNG, JPEG, GIF, TIFF, BMP, WebP, SVG. The type is detected inside the sandbox
from the file's contents, not its name.

## Keeping it up to date

The sandbox image contains LibreOffice and MuPDF from Debian. Rebuild it now and
then to pick up security fixes:

```bash
container system start
make image
container system stop
make setup
```

The Containerization package is pinned to an exact version in `Package.swift`
because its API changes between releases. If you change it, change the init
image tag in `Sources/PixelwashCore/Setup.swift` to match.

## Tests

```bash
make test               # unit tests: stream parser, PDF writer, OCR, converter
make integration-test   # real conversions in the sandbox, after make setup
```

## Uninstall

Delete `/Applications/Pixelwash.app`, `~/.local/bin/pixelwash` and
`~/Library/Application Support/Pixelwash`.

## Layout

| Path | What it is |
|---|---|
| `image/` | Sandbox image: `Containerfile` and the in-sandbox converter |
| `Sources/PixelwashCore/` | Sandbox runner, stream parser, PDF writer, OCR, setup |
| `Sources/pixelwash/` | Command-line tool |
| `Sources/PixelwashApp/` | SwiftUI app |
| `docs/superpowers/` | Design and implementation plan |
