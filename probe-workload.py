#!/usr/bin/env python3
"""Allocate production text and vision paths while probe-vram.sh samples VRAM."""
import argparse
import base64
import json
from pathlib import Path
import urllib.request


def post(port, path, body, timeout=600):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--prompt-tokens", type=int, default=4096)
    args = parser.parse_args()

    seed = "Prefill probe: alpha beta gamma delta 0123456789. " * (args.prompt_tokens // 8 + 1024)
    tokens = post(args.port, "/tokenize", {"content": seed})["tokens"][: args.prompt_tokens]
    text = post(args.port, "/completion", {
        "prompt": tokens,
        "n_predict": 16,
        "temperature": 0,
        "cache_prompt": False,
    })

    image = base64.b64encode(Path(args.image).read_bytes()).decode()
    vision = post(args.port, "/v1/chat/completions", {
        "model": "probe",
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": "Transcribe all visible text exactly."},
                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{image}"}},
            ],
        }],
        "max_tokens": 96,
        "temperature": 0,
    })
    result = {
        "text_prompt_tokens": len(tokens),
        "text_timings": text.get("timings"),
        "vision_content": vision["choices"][0]["message"].get("content"),
        "vision_reasoning": vision["choices"][0]["message"].get("reasoning_content"),
        "vision_usage": vision.get("usage"),
        "vision_timings": vision.get("timings"),
    }
    Path(args.output).write_text(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
