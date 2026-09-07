#!/usr/bin/env python3
"""
Translate a document (.pdf, .md, .txt) using Google Translate via deep-translator.

Free, no API key. Chunks text to stay under per-request limits and retries on
transient failures. Output is written next to the source as <name>_copy.<ext>
unless -o is given.

Usage:
    python translate_doc.py dossier_projet_fr_dylan.pdf
    python translate_doc.py README.md -s en -t fr
    python translate_doc.py notes.txt -o notes_es.txt -t es
"""

from __future__ import annotations

import argparse
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import pymupdf
import requests
from deep_translator import GoogleTranslator
from deep_translator.exceptions import RequestError, TooManyRequests, TranslationNotFound

BROWSER_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
_plain_get = requests.get


def _get_as_browser(url, **kwargs):
    """deep-translator sets no headers (google.py:67), so requests advertises
    "python-requests/X". Google soft-blocks that UA once an IP looks automated,
    answering with an "Error 500" page served as HTTP 200 — which surfaces as
    TranslationNotFound on every chunk. A browser UA keeps working."""
    headers = {"User-Agent": BROWSER_UA, **(kwargs.pop("headers", None) or {})}
    return _plain_get(url, headers=headers, **kwargs)


requests.get = _get_as_browser

CHUNK_LIMIT = 4500
MAX_RETRIES = 6
RETRY_BASE_DELAY = 1.5
CONSECUTIVE_FAILURE_LIMIT = 3

# Google's /m endpoint intermittently serves an "Error 500" page with HTTP status 200;
# deep-translator surfaces that as TranslationNotFound, so it retries like any hiccup.
RETRIABLE = (RequestError, TooManyRequests, TranslationNotFound)

CODE_FENCE_RE = re.compile(r"^(```|~~~)")


class BackendDown(RuntimeError):
    """The backend failed repeatedly — abort rather than grind through every chunk."""


@dataclass
class Tally:
    """Per-run chunk accounting. The exit code derives from `failed`."""

    total: int = 0
    translated: int = 0
    failed: int = 0
    streak: int = 0

    def record(self, ok: bool) -> None:
        self.total += 1
        if ok:
            self.translated += 1
            self.streak = 0
            return
        self.failed += 1
        self.streak += 1
        if self.streak >= CONSECUTIVE_FAILURE_LIMIT:
            raise BackendDown(f"{self.streak} consecutive chunks failed after {MAX_RETRIES} retries each")


def chunk_text(text: str, limit: int = CHUNK_LIMIT) -> list[str]:
    """Greedy split on paragraph then sentence boundaries; never exceeds `limit`."""
    if len(text) <= limit:
        return [text]

    out: list[str] = []
    for para in text.split("\n\n"):
        if len(para) <= limit:
            out.append(para)
            continue
        buf = ""
        for sentence in re.split(r"(?<=[.!?])\s+", para):
            if len(sentence) > limit:
                for i in range(0, len(sentence), limit):
                    out.append(sentence[i : i + limit])
                continue
            if len(buf) + len(sentence) + 1 > limit:
                if buf:
                    out.append(buf)
                buf = sentence
            else:
                buf = f"{buf} {sentence}".strip()
        if buf:
            out.append(buf)
    return out


def has_translatable_text(chunk: str) -> bool:
    """Markdown rules ("---"), table borders and numeric rows carry no prose to translate."""
    return any(ch.isalpha() for ch in chunk)


def translate_chunk(translator: GoogleTranslator, chunk: str) -> tuple[str, bool]:
    """Return (text, translated_ok). On failure the source text comes back untouched."""
    if not chunk.strip() or not has_translatable_text(chunk):
        return chunk, True
    for attempt in range(MAX_RETRIES):
        try:
            result = translator.translate(chunk)
            if result:
                return result, True
            print("  ! translator returned an empty result", file=sys.stderr)
            return chunk, False
        except RETRIABLE as e:
            wait = RETRY_BASE_DELAY * (2**attempt)
            print(f"  ! retry {attempt + 1}/{MAX_RETRIES} after {wait:.1f}s ({e.__class__.__name__})", file=sys.stderr)
            time.sleep(wait)
        except Exception as e:
            print(f"  ! chunk failed permanently: {e.__class__.__name__}: {e}", file=sys.stderr)
            return chunk, False
    print(f"  ! chunk failed after {MAX_RETRIES} retries, keeping source", file=sys.stderr)
    return chunk, False


def translate_text(text: str, src: str, tgt: str, tally: Tally, label: str = "") -> str:
    if not text.strip():
        return text
    translator = GoogleTranslator(source=src, target=tgt)
    chunks = chunk_text(text)
    out: list[str] = []
    total = len(chunks)
    for i, chunk in enumerate(chunks, 1):
        translated, ok = translate_chunk(translator, chunk)
        if has_translatable_text(chunk):
            tally.record(ok)
        out.append(translated)
        if total > 1:
            print(f"  {label}chunk {i}/{total}", file=sys.stderr, end="\r")
    if total > 1:
        print(" " * 60, file=sys.stderr, end="\r")
    return "\n\n".join(out)


def translate_markdown(src_path: Path, dst_path: Path, src: str, tgt: str, tally: Tally) -> None:
    """Translate Markdown while leaving fenced code blocks untouched."""
    raw = src_path.read_text(encoding="utf-8")
    lines = raw.splitlines(keepends=False)

    segments: list[tuple[str, str]] = []
    buf: list[str] = []
    in_code = False
    for line in lines:
        if CODE_FENCE_RE.match(line.strip()):
            if buf:
                segments.append(("code" if in_code else "text", "\n".join(buf)))
                buf = []
            in_code = not in_code
            segments.append(("fence", line))
            continue
        buf.append(line)
    if buf:
        segments.append(("code" if in_code else "text", "\n".join(buf)))

    translated: list[str] = []
    text_segments = [s for s in segments if s[0] == "text" and s[1].strip()]
    print(f"  markdown: {len(text_segments)} text segments, "
          f"{sum(1 for s in segments if s[0] == 'code')} code blocks preserved",
          file=sys.stderr)

    text_idx = 0
    for kind, content in segments:
        if kind == "text" and content.strip():
            text_idx += 1
            label = f"[seg {text_idx}/{len(text_segments)}] "
            translated.append(translate_text(content, src, tgt, tally, label=label))
        else:
            translated.append(content)

    # Never leave a half-translated file behind masquerading as a translation.
    if not tally.failed:
        dst_path.write_text("\n".join(translated) + "\n", encoding="utf-8")


def translate_pdf(src_path: Path, dst_path: Path, src: str, tgt: str, tally: Tally) -> None:
    """Extract text per page, translate, render a clean text-only PDF."""
    doc = pymupdf.open(src_path)
    out = pymupdf.open()
    margin = 50
    page_w, page_h = pymupdf.paper_size("a4")
    fontsize = 10

    total = doc.page_count
    print(f"  pdf: {total} pages", file=sys.stderr)
    for i, page in enumerate(doc, 1):
        print(f"  page {i}/{total}", file=sys.stderr)
        text = page.get_text("text").strip()
        if not text:
            new_page = out.new_page(width=page_w, height=page_h)
            new_page.insert_text((margin, margin), f"[page {i}: no extractable text]", fontsize=fontsize)
            continue

        translated = translate_text(text, src, tgt, tally, label=f"[p{i}] ")
        rendered = _render_text_to_pages(out, translated, page_w, page_h, margin, fontsize, i)
        if rendered == 0:
            new_page = out.new_page(width=page_w, height=page_h)
            new_page.insert_text((margin, margin), f"[page {i}: render failed]", fontsize=fontsize)

    if not tally.failed:
        out.save(dst_path, garbage=4, deflate=True)
    out.close()
    doc.close()


def _render_text_to_pages(
    out_doc: pymupdf.Document,
    text: str,
    page_w: float,
    page_h: float,
    margin: float,
    fontsize: int,
    source_page: int,
) -> int:
    """Flow text across as many pages as needed. Returns number of pages added."""
    remaining = text
    pages_added = 0
    safety = 0
    while remaining and safety < 50:
        safety += 1
        new_page = out_doc.new_page(width=page_w, height=page_h)
        rect = pymupdf.Rect(margin, margin, page_w - margin, page_h - margin)
        leftover = new_page.insert_textbox(
            rect,
            remaining,
            fontsize=fontsize,
            fontname="helv",
            align=pymupdf.TEXT_ALIGN_LEFT,
        )
        pages_added += 1
        if leftover <= 0:
            break
        consumed = len(remaining) - int(leftover) if isinstance(leftover, (int, float)) else 0
        if consumed <= 0:
            fontsize_local = max(7, fontsize - 1)
            new_page = out_doc.new_page(width=page_w, height=page_h)
            new_page.insert_textbox(rect, remaining, fontsize=fontsize_local, fontname="helv")
            pages_added += 1
            break
        remaining = remaining[consumed:].lstrip()
    return pages_added


def default_output(src: Path) -> Path:
    return src.with_name(f"{src.stem}_copy{src.suffix}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0] if __doc__ else "")
    ap.add_argument("input", type=Path, help="Source file (.pdf, .md, .txt)")
    ap.add_argument("-o", "--output", type=Path, help="Output path (default: <stem>_copy.<ext>)")
    ap.add_argument("-s", "--source", default="fr", help="Source language code (default: fr)")
    ap.add_argument("-t", "--target", default="en", help="Target language code (default: en)")
    args = ap.parse_args()

    src_path: Path = args.input
    if not src_path.exists():
        print(f"error: {src_path} not found", file=sys.stderr)
        return 1

    dst_path: Path = args.output or default_output(src_path)
    ext = src_path.suffix.lower()

    if ext not in (".pdf", ".md", ".txt", ".markdown"):
        print(f"error: unsupported extension {ext} (supported: .pdf, .md, .txt)", file=sys.stderr)
        return 1

    print(f"translating {src_path.name} ({args.source} -> {args.target}) -> {dst_path.name}", file=sys.stderr)
    started = time.time()
    tally = Tally()

    try:
        if ext == ".pdf":
            translate_pdf(src_path, dst_path, args.source, args.target, tally)
        else:
            translate_markdown(src_path, dst_path, args.source, args.target, tally)
        code = 1 if tally.failed else 0
    except BackendDown as e:
        print(f"aborted: {e}", file=sys.stderr)
        code = 2

    # The summary prints on success too: "exit 0" only means something next to the counts.
    print(f"chunks: {tally.total} total, {tally.translated} translated, "
          f"{tally.failed} failed in {time.time() - started:.1f}s", file=sys.stderr)
    if code:
        print(f"error: {tally.failed} chunk(s) untranslated, {dst_path} not written", file=sys.stderr)
    else:
        print(f"done -> {dst_path}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
