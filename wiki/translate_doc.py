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
from pathlib import Path

import fitz
from deep_translator import GoogleTranslator
from deep_translator.exceptions import RequestError, TooManyRequests

CHUNK_LIMIT = 4500
MAX_RETRIES = 4
RETRY_BASE_DELAY = 1.5

CODE_FENCE_RE = re.compile(r"^(```|~~~)")


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


def translate_chunk(translator: GoogleTranslator, chunk: str) -> str:
    if not chunk.strip():
        return chunk
    for attempt in range(MAX_RETRIES):
        try:
            result = translator.translate(chunk)
            return result if result else chunk
        except (RequestError, TooManyRequests) as e:
            wait = RETRY_BASE_DELAY * (2**attempt)
            print(f"  ! retry {attempt + 1}/{MAX_RETRIES} after {wait:.1f}s ({e.__class__.__name__})", file=sys.stderr)
            time.sleep(wait)
        except Exception as e:
            print(f"  ! chunk failed permanently: {e.__class__.__name__}: {e}", file=sys.stderr)
            return chunk
    print("  ! chunk failed after retries, keeping source", file=sys.stderr)
    return chunk


def translate_text(text: str, src: str, tgt: str, label: str = "") -> str:
    if not text.strip():
        return text
    translator = GoogleTranslator(source=src, target=tgt)
    chunks = chunk_text(text)
    out: list[str] = []
    total = len(chunks)
    for i, chunk in enumerate(chunks, 1):
        out.append(translate_chunk(translator, chunk))
        if total > 1:
            print(f"  {label}chunk {i}/{total}", file=sys.stderr, end="\r")
    if total > 1:
        print(" " * 60, file=sys.stderr, end="\r")
    return "\n\n".join(out)


def translate_markdown(src_path: Path, dst_path: Path, src: str, tgt: str) -> None:
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
            translated.append(translate_text(content, src, tgt, label=label))
        else:
            translated.append(content)

    dst_path.write_text("\n".join(translated) + "\n", encoding="utf-8")


def translate_pdf(src_path: Path, dst_path: Path, src: str, tgt: str) -> None:
    """Extract text per page, translate, render a clean text-only PDF."""
    doc = fitz.open(src_path)
    out = fitz.open()
    margin = 50
    page_w, page_h = fitz.paper_size("a4")
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

        translated = translate_text(text, src, tgt, label=f"[p{i}] ")
        rendered = _render_text_to_pages(out, translated, page_w, page_h, margin, fontsize, i)
        if rendered == 0:
            new_page = out.new_page(width=page_w, height=page_h)
            new_page.insert_text((margin, margin), f"[page {i}: render failed]", fontsize=fontsize)

    out.save(dst_path, garbage=4, deflate=True)
    out.close()
    doc.close()


def _render_text_to_pages(
    out_doc: fitz.Document,
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
        rect = fitz.Rect(margin, margin, page_w - margin, page_h - margin)
        leftover = new_page.insert_textbox(
            rect,
            remaining,
            fontsize=fontsize,
            fontname="helv",
            align=fitz.TEXT_ALIGN_LEFT,
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

    print(f"translating {src_path.name} ({args.source} -> {args.target}) -> {dst_path.name}", file=sys.stderr)
    started = time.time()

    if ext == ".pdf":
        translate_pdf(src_path, dst_path, args.source, args.target)
    elif ext in (".md", ".txt", ".markdown"):
        translate_markdown(src_path, dst_path, args.source, args.target)
    else:
        print(f"error: unsupported extension {ext} (supported: .pdf, .md, .txt)", file=sys.stderr)
        return 1

    elapsed = time.time() - started
    print(f"done in {elapsed:.1f}s -> {dst_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
