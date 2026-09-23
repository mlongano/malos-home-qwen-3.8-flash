#!/usr/bin/env python3
"""Compare a candidate KV cache against the accepted q8_0 KV configuration.

The gate uses one-step teacher forcing. It tokenizes fixed local text, sends successively longer
token prefixes, and records the raw top-K next-token distribution at each position. Prefix reuse
means each position evaluates one new token after the initial prefill.

KLD is approximate because llama.cpp returns top-K probabilities, not the full vocabulary. Each
missing candidate probability uses its average tail probability, and each distribution's remaining
tail is one aggregate bin. Run q8_0 against itself first. That control must be effectively zero KLD
and 100% top-1 before a compressed KV result is accepted.
"""
import argparse
import json
import math
import os
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
PORT = 18098
TOP_K = 64
DEFAULT_POSITIONS = 256


def get(path, timeout=30):
    return json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}", timeout=timeout))


def post(path, body, timeout=1800):
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}{path}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def corpus():
    items = []
    for name in ("RESULTS.md", "EVIDENCE.md", "run-mtp-pr-test.sh", "summary.json"):
        path = os.path.join(ROOT, name)
        if not os.path.exists(path):
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        if len(text) < 3000:
            continue
        items.append({
            "name": name,
            "prompt": text[:1600] + "\n\n### Fixed continuation\n",
            "continuation": text[1600:3000],
        })
    return items


def launch(label, cache_type_k, cache_type_v, n_cpu_moe):
    log_dir = os.path.join(ROOT, "results", "quality-kv-gate")
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, f"{label}.server.log")
    log = open(log_path, "w")
    env = dict(
        os.environ,
        BIND_HOST="127.0.0.1",
        PORT=str(PORT),
        CTX_SIZE="8192",
        MTP="0",
        VISION="0",
        CACHE_PROMPT="1",
        CACHE_RAM_MIB="2048",
        UBATCH_SIZE="512",
        BATCH_SIZE="2048",
        CT_K=cache_type_k,
        CT_V=cache_type_v,
        N_CPU_MOE=str(n_cpu_moe),
    )
    proc = subprocess.Popen(
        [os.path.join(ROOT, "run-mtp-pr-test.sh")],
        stdout=log,
        stderr=subprocess.STDOUT,
        env=env,
        preexec_fn=os.setsid,
    )
    for _ in range(180):
        try:
            if get("/health", timeout=3).get("status") == "ok":
                return proc, log, log_path
        except Exception:
            if proc.poll() is not None:
                log.close()
                raise RuntimeError(f"server died while starting; see {log_path}")
        time.sleep(2)
    stop(proc, log)
    raise RuntimeError(f"server did not become healthy; see {log_path}")


def stop(proc, log):
    if proc and proc.poll() is None:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            proc.wait(timeout=20)
    if log:
        log.close()
    time.sleep(5)


def tokenize(text):
    return post("/tokenize", {"content": text})["tokens"]


def one_distribution(prefix_tokens, vocab_size):
    data = post("/completion", {
        "prompt": prefix_tokens,
        "n_predict": 1,
        "n_probs": TOP_K,
        "cache_prompt": True,
        "temperature": 0,
        "seed": 42,
        "repeat_penalty": 1.0,
        "presence_penalty": 0.0,
        "frequency_penalty": 0.0,
    })
    row = data["completion_probabilities"][0]
    probs = {str(x["id"]): math.exp(x["logprob"]) for x in row["top_logprobs"]}
    tail = max(1e-15, 1.0 - sum(probs.values()))
    return {
        "argmax": str(row["top_logprobs"][0]["id"]),
        "probs": probs,
        "tail": tail,
        "vocab_size": vocab_size,
    }


def score(items, max_positions):
    model = get("/v1/models")["data"][0]
    vocab_size = int(model["meta"]["n_vocab"])
    out = {}
    for item in items:
        prefix = tokenize(item["prompt"])
        full = tokenize(item["prompt"] + item["continuation"])
        common = 0
        while common < min(len(prefix), len(full)) and prefix[common] == full[common]:
            common += 1
        start = common
        end = min(len(full), start + max_positions)
        rows = []
        print(f"  {item['name']}: scoring {end - start} positions", flush=True)
        for i in range(start, end):
            dist = one_distribution(full[:i], vocab_size)
            dist["reference_token"] = str(full[i])
            rows.append(dist)
            if (i - start + 1) % 64 == 0:
                print(f"    {i - start + 1}/{end - start}", flush=True)
        out[item["name"]] = rows
    return out


def approximate_kld(p, q):
    q_unseen = max(q["tail"] / max(q["vocab_size"] - len(q["probs"]), 1), 1e-15)
    total = 0.0
    for token, prob in p["probs"].items():
        qprob = max(q["probs"].get(token, q_unseen), 1e-15)
        total += prob * math.log(prob / qprob)
    total += p["tail"] * math.log(p["tail"] / max(q["tail"], 1e-15))
    return total


def compare(reference, candidate):
    item_results = {}
    total_kld = 0.0
    top1_same = 0
    total_positions = 0
    reference_token_delta = []
    for name, ref_rows in reference.items():
        cand_rows = candidate.get(name, [])
        count = min(len(ref_rows), len(cand_rows))
        item_kld = 0.0
        item_same = 0
        for ref, cand in zip(ref_rows[:count], cand_rows[:count]):
            item_kld += approximate_kld(ref, cand)
            same = ref["argmax"] == cand["argmax"]
            item_same += int(same)
            token = ref["reference_token"]
            if token in ref["probs"] and token in cand["probs"]:
                reference_token_delta.append(
                    abs(math.log(ref["probs"][token]) - math.log(cand["probs"][token]))
                )
        item_results[name] = {
            "positions": count,
            "mean_kld": item_kld / max(count, 1),
            "top1_agreement": item_same / max(count, 1),
        }
        total_kld += item_kld
        top1_same += item_same
        total_positions += count
    return {
        "per_item": item_results,
        "scored_positions": total_positions,
        "mean_kld": total_kld / max(total_positions, 1),
        "top1_agreement": top1_same / max(total_positions, 1),
        "mean_abs_reference_token_logprob_delta": (
            sum(reference_token_delta) / len(reference_token_delta)
            if reference_token_delta else None
        ),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate-k", default="q4_0")
    parser.add_argument("--candidate-v", default="q4_0")
    parser.add_argument("--candidate-ncmoe", type=int, default=34)
    parser.add_argument("--positions-per-item", type=int, default=DEFAULT_POSITIONS)
    parser.add_argument("--kld-max", type=float, default=0.01)
    parser.add_argument("--top1-min", type=float, default=0.98)
    args = parser.parse_args()

    items = corpus()
    if not items:
        sys.exit("no corpus files found")

    proc = log = None
    try:
        print("reference: q8_0 KV, n-cpu-moe 34")
        proc, log, _ = launch("reference-q8", "q8_0", "q8_0", 34)
        reference = score(items, args.positions_per_item)
        stop(proc, log)
        proc = log = None

        print(f"candidate: K={args.candidate_k} V={args.candidate_v}, n-cpu-moe {args.candidate_ncmoe}")
        proc, log, _ = launch(
            f"candidate-{args.candidate_k}-{args.candidate_v}-n{args.candidate_ncmoe}",
            args.candidate_k,
            args.candidate_v,
            args.candidate_ncmoe,
        )
        candidate = score(items, args.positions_per_item)
        stop(proc, log)
        proc = log = None
    finally:
        if proc:
            stop(proc, log)

    result = compare(reference, candidate)
    is_control = args.candidate_k == "q8_0" and args.candidate_v == "q8_0" and args.candidate_ncmoe == 34
    kld_limit = 1e-6 if is_control else args.kld_max
    top1_limit = 1.0 if is_control else args.top1_min
    result.update({
        "method": "one-step teacher forcing, top-64 approximate KLD",
        "reference": {"kv": "q8_0", "n_cpu_moe": 34},
        "candidate": {"cache_type_k": args.candidate_k, "cache_type_v": args.candidate_v, "n_cpu_moe": args.candidate_ncmoe},
        "gate": {
            "kld_max": kld_limit,
            "top1_min": top1_limit,
            "pass_kld": result["mean_kld"] <= kld_limit,
            "pass_top1": result["top1_agreement"] >= top1_limit,
        },
    })
    result["gate"]["verdict"] = (
        "accept" if result["gate"]["pass_kld"] and result["gate"]["pass_top1"] else "reject"
    )

    out_dir = os.path.join(ROOT, "results", "quality-kv-gate")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"{args.candidate_k}-{args.candidate_v}-n{args.candidate_ncmoe}.json")
    with open(out_path, "w") as handle:
        json.dump(result, handle, indent=2)
    print(json.dumps(result, indent=2))
    print(f"wrote {out_path}")
    if result["gate"]["verdict"] != "accept":
        raise SystemExit(2)


if __name__ == "__main__":
    main()
