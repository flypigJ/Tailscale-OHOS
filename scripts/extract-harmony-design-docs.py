#!/usr/bin/env python3
"""Extract readable article text from Huawei SingleFile design-document snapshots."""

from __future__ import annotations

import argparse
import json
import re
from html.parser import HTMLParser
from pathlib import Path


BLOCK_TAGS = {
    "h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "dt", "dd",
    "th", "td", "figcaption", "blockquote", "summary",
}
SKIP_TAGS = {"script", "style", "svg", "canvas", "noscript", "template"}


class ArticleTextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.skip_depth = 0
        self.block_stack: list[str] = []
        self.buffer: list[str] = []
        self.lines: list[dict[str, str]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        if tag in SKIP_TAGS:
            self.skip_depth += 1
            return
        if self.skip_depth:
            return
        if tag in BLOCK_TAGS:
            self._flush()
            self.block_stack.append(tag)
        elif tag == "br" and self.block_stack:
            self._flush()

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in SKIP_TAGS:
            if self.skip_depth:
                self.skip_depth -= 1
            return
        if self.skip_depth:
            return
        if tag in BLOCK_TAGS:
            self._flush(tag)
            if self.block_stack:
                self.block_stack.pop()

    def handle_data(self, data: str) -> None:
        if not self.skip_depth and self.block_stack:
            self.buffer.append(data)

    def _flush(self, explicit_tag: str | None = None) -> None:
        text = re.sub(r"\s+", " ", "".join(self.buffer)).strip()
        self.buffer.clear()
        if not text:
            return
        if text.startswith("data:") or len(text) > 3000:
            return
        tag = explicit_tag or (self.block_stack[-1] if self.block_stack else "p")
        if self.lines and self.lines[-1]["text"] == text:
            return
        self.lines.append({"tag": tag, "text": text})


def score_line(text: str) -> int:
    score = 0
    if re.search(r"[\u4e00-\u9fff]", text):
        score += 2
    if 8 <= len(text) <= 240:
        score += 1
    if any(token in text for token in ("设计", "应用", "布局", "动效", "色彩", "组件", "导航", "页面")):
        score += 1
    if any(token in text for token in ("开发者", "登录", "搜索", "文档中心", "Cookie", "版权所有")):
        score -= 2
    return score


def extract(path: Path) -> dict[str, object]:
    parser = ArticleTextParser()
    parser.feed(path.read_text(encoding="utf-8", errors="ignore"))

    lines = parser.lines
    meaningful = [line for line in lines if score_line(line["text"]) > 0]
    headings = [line["text"] for line in meaningful if line["tag"].startswith("h")]
    return {
        "file": path.name,
        "title": headings[0] if headings else path.stem,
        "headings": headings,
        "blocks": meaningful,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path)
    ap.add_argument("output", type=Path)
    args = ap.parse_args()

    files = sorted(
        p for p in args.source.glob("*.htm*")
        if p.name.lower() != "upstream-sync.htm"
        and "华为HarmonyOS开发者" in p.name
    )
    docs = [extract(path) for path in files]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(docs, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"extracted {len(docs)} documents to {args.output}")
    for doc in docs:
        print(f"{doc['title']}: {len(doc['blocks'])} blocks")


if __name__ == "__main__":
    main()
