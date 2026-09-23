#!/usr/bin/env python3
"""Create a local agent-shaped benchmark corpus from a Pi JSONL session."""
import argparse, json
from pathlib import Path


def content_text(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return json.dumps(content, ensure_ascii=False)
    out=[]
    for item in content:
        if isinstance(item, str): out.append(item); continue
        if not isinstance(item, dict): continue
        typ=item.get("type", "item")
        text=item.get("text") or item.get("thinking") or item.get("content")
        if text: out.append(f"[{typ}] {text}")
        elif typ in ("toolCall", "tool_call"):
            out.append(f"[tool] {item.get('name')} {json.dumps(item.get('arguments'), ensure_ascii=False)}")
    return "\n".join(out)


def main():
    ap=argparse.ArgumentParser(); ap.add_argument("session"); ap.add_argument("output"); a=ap.parse_args()
    chunks=[]
    for line in open(a.session, errors="replace"):
        try: d=json.loads(line)
        except Exception: continue
        if d.get("type")=="message":
            m=d.get("message") or {}; role=m.get("role","message"); text=content_text(m.get("content"))
            if role=="toolResult": text=text[:2000]
            if text: chunks.append(f"[{role}]\n{text}\n")
        elif d.get("type")=="compaction":
            chunks.append(f"[compaction summary]\n{d.get('summary','')}\n")
    Path(a.output).parent.mkdir(parents=True, exist_ok=True)
    Path(a.output).write_text("\n".join(chunks))

if __name__=="__main__": main()
