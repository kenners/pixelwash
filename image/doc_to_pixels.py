#!/usr/bin/python3
"""Runs inside the Pixelwash sandbox.

Reads one untrusted document on stdin and writes its pages to stdout as raw
pixels:

    u16 page_count
    repeat: u16 width, u16 height, width*height*3 bytes of RGB

All integers are big-endian. Nothing else may be written to stdout.

Exit codes: 0 ok, 2 unsupported or empty, 3 password-protected,
4 too many pages or a page too large.
"""

import os
import struct
import subprocess
import sys
import zipfile

import magic

try:
    import pymupdf as fitz
except ImportError:  # older PyMuPDF
    import fitz

DPI = 150
MAX_PAGES = 10_000
MAX_DIMENSION = 10_000
WORK = "/tmp/work"

EXIT_UNSUPPORTED = 2
EXIT_ENCRYPTED = 3
EXIT_TOO_LARGE = 4

# Opened directly by MuPDF. Value is the filetype hint.
DIRECT = {
    "application/pdf": "pdf",
    "image/png": "png",
    "image/jpeg": "jpeg",
    "image/gif": "gif",
    "image/tiff": "tiff",
    "image/bmp": "bmp",
    "image/x-ms-bmp": "bmp",
    "image/webp": "webp",
    "image/svg+xml": "svg",
}

# Converted to PDF by LibreOffice first. Value is the extension it is given.
OFFICE = {
    "application/msword": "doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
    "application/vnd.ms-word.document.macroenabled.12": "docm",
    "application/vnd.ms-excel": "xls",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
    "application/vnd.ms-excel.sheet.macroenabled.12": "xlsm",
    "application/vnd.ms-powerpoint": "ppt",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
    "application/vnd.ms-powerpoint.presentation.macroenabled.12": "pptm",
    "application/vnd.oasis.opendocument.text": "odt",
    "application/vnd.oasis.opendocument.spreadsheet": "ods",
    "application/vnd.oasis.opendocument.presentation": "odp",
    "application/vnd.oasis.opendocument.graphics": "odg",
    "application/rtf": "rtf",
    "text/rtf": "rtf",
    "text/plain": "txt",
    "text/csv": "csv",
}


def log(message):
    print(message, file=sys.stderr, flush=True)


def fail(code, message):
    log(message)
    sys.exit(code)


def sniff_zip(path):
    """libmagic sometimes reports OOXML files as a plain zip."""
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
    except Exception:
        return None
    for prefix, ext in (("word/", "docx"), ("xl/", "xlsx"), ("ppt/", "pptx")):
        if any(n.startswith(prefix) for n in names):
            return ext
    return None


def office_to_pdf(path, ext):
    src = os.path.join(WORK, "in." + ext)
    os.rename(path, src)
    result = subprocess.run(
        [
            "soffice",
            "-env:UserInstallation=file:///tmp/lo-profile",
            "--headless", "--norestore", "--nolockcheck",
            "--convert-to", "pdf", "--outdir", WORK, src,
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=None,  # the host enforces the time limit
    )
    out = os.path.join(WORK, "in.pdf")
    if result.returncode != 0 or not os.path.exists(out):
        fail(EXIT_UNSUPPORTED, f"LibreOffice could not convert the document (exit {result.returncode})")
    return out


def main():
    os.makedirs(WORK, exist_ok=True)
    path = os.path.join(WORK, "in")
    size = 0
    with open(path, "wb") as f:
        while chunk := sys.stdin.buffer.read(1 << 20):
            f.write(chunk)
            size += len(chunk)
    if size == 0:
        fail(EXIT_UNSUPPORTED, "empty input")

    mime = magic.from_file(path, mime=True)
    log(f"detected {mime}, {size} bytes")

    filetype = DIRECT.get(mime)
    if filetype is None:
        ext = OFFICE.get(mime)
        if ext is None and mime in ("application/zip", "application/octet-stream"):
            ext = sniff_zip(path)
        if ext is None:
            fail(EXIT_UNSUPPORTED, f"unsupported type {mime}")
        path = office_to_pdf(path, ext)
        filetype = "pdf"

    try:
        doc = fitz.open(path, filetype=filetype)
    except Exception as e:
        fail(EXIT_UNSUPPORTED, f"cannot open document: {e}")
    if doc.needs_pass:
        fail(EXIT_ENCRYPTED, "document is password-protected")

    count = doc.page_count
    if count < 1:
        fail(EXIT_UNSUPPORTED, "document has no pages")
    if count > MAX_PAGES:
        fail(EXIT_TOO_LARGE, f"{count} pages is more than {MAX_PAGES}")

    out = sys.stdout.buffer
    out.write(struct.pack(">H", count))
    for page in doc:
        pix = page.get_pixmap(dpi=DPI, colorspace=fitz.csRGB, alpha=False)
        if not (1 <= pix.width <= MAX_DIMENSION and 1 <= pix.height <= MAX_DIMENSION):
            fail(EXIT_TOO_LARGE, f"page {page.number + 1} is {pix.width}x{pix.height} pixels")
        out.write(struct.pack(">HH", pix.width, pix.height))
        out.write(pix.samples)
        out.flush()
        log(f"page {page.number + 1}/{count}")


if __name__ == "__main__":
    main()
