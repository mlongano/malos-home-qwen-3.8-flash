#!/usr/bin/env python3
"""Bounded Qwen3.8 Flash Next residency sweep for this R9700 host."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent
CONFIG = {}
for line in (ROOT / "config.env").read_text().splitlines():
    if line and not line.startswith("#"):
        key, value = line.split("=", 1)
        CONFIG[key] = value

VRAM_LIMIT_MIB = 30576
TEMP_LIMITS = {"edge_c": 85.0, "junction_c": 95.0, "memory_c": 90.0}
PROMPT = (
    "Continue with exactly eight concise numbered observations about reliable "
    "local inference benchmarking. Do not repeat the instruction.\n1."
)


def read_int(path):
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return None


def gpu_paths():
    cards = []
    for device in Path("/sys/class/drm").glob("card*/device"):
        total = read_int(device / "mem_info_vram_total")
        if total:
            cards.append((total, device))
    if not cards:
        raise RuntimeError("No DRM GPU with VRAM counters found")
    device = max(cards)[1]
    hwmons = list((device / "hwmon").glob("hwmon*"))
    if not hwmons:
        raise RuntimeError("AMDGPU hwmon unavailable")
    return device, hwmons[0]


GPU, HWMON = gpu_paths()


def metrics(pid=None):
    out = {
        "time": time.time(),
        "vram_mib": (read_int(GPU / "mem_info_vram_used") or 0) / 1048576,
        "edge_c": (read_int(HWMON / "temp1_input") or 0) / 1000,
        "junction_c": (read_int(HWMON / "temp2_input") or 0) / 1000,
        "memory_c": (read_int(HWMON / "temp3_input") or 0) / 1000,
    }
    if pid:
        status = Path(f"/proc/{pid}/status")
        if status.exists():
            for line in status.read_text().splitlines():
                if line.startswith(("VmRSS:", "VmHWM:")):
                    key, value, _ = line.split()
                    out[key[:-1].lower() + "_mib"] = int(value) / 1024
    return out


def vmstat():
    wanted = {"pswpin", "pswpout", "pgmajfault"}
    return {key: int(value) for key, value in
            (line.split() for line in Path("/proc/vmstat").read_text().splitlines())
            if key in wanted}


def meminfo():
    wanted = {"MemAvailable", "SwapFree", "Cached"}
    result = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        parts = line.split()
        key = parts[0].rstrip(":")
        if key in wanted:
            result[key] = int(parts[1]) * 1024
    return result


def model_block_device():
    source = subprocess.run(
        ["findmnt", "-no", "SOURCE", "-T", str(ROOT)],
        check=True, text=True, capture_output=True).stdout.strip()
    parent = subprocess.run(
        ["lsblk", "-no", "PKNAME", source],
        check=True, text=True, capture_output=True).stdout.strip()
    return parent or Path(source).name


BLOCK = model_block_device()


def diskstat():
    values = [int(x) for x in Path(f"/sys/block/{BLOCK}/stat").read_text().split()]
    return {"reads": values[0], "read_sectors": values[2],
            "writes": values[4], "write_sectors": values[6]}


def delta(after, before):
    return {key: after[key] - before[key] for key in before}


def post(port, path, payload, timeout):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def healthy(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
            return json.loads(response.read()).get("status") == "ok"
    except Exception:
        return False


def terminate(process):
    if process is None or process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGINT)
    try:
        process.wait(60)
        return
    except subprocess.TimeoutExpired:
        pass
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(20)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


class Watchdog:
    def __init__(self, process):
        self.process = process
        self.stop = threading.Event()
        self.reason = None
        self.samples = []
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop.wait(0.5):
            sample = metrics(self.process.pid)
            self.samples.append(sample)
            if sample["vram_mib"] > VRAM_LIMIT_MIB:
                self.reason = f"VRAM {sample['vram_mib']:.1f} MiB exceeds {VRAM_LIMIT_MIB}"
            for key, limit in TEMP_LIMITS.items():
                if sample[key] >= limit:
                    self.reason = f"{key} {sample[key]:.1f} C exceeds {limit:.1f} C"
            if self.reason:
                terminate(self.process)
                return

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(3)

    def summary(self):
        result = {"reason": self.reason, "samples": len(self.samples)}
        for key in ("vram_mib", "edge_c", "junction_c", "memory_c", "vmrss_mib", "vmhwm_mib"):
            values = [sample[key] for sample in self.samples if key in sample]
            result["max_" + key] = max(values) if values else None
        return result


def run_case(model_profile, n_cpu_moe, lazy_mode, mtp, ctx_size, tokens, port, output):
    name = f"{model_profile}-ncmoe-{n_cpu_moe}-lazy-{lazy_mode}-mtp-{int(mtp)}-ctx-{ctx_size}-n-{tokens}"
    log = output / f"{name}.server.log"
    env = os.environ.copy()
    env.update({"MODEL_PROFILE": model_profile, "N_CPU_MOE": str(n_cpu_moe),
                "LAZY_MODE": lazy_mode, "MTP": "1" if mtp else "0",
                "CTX_SIZE": str(ctx_size), "PORT": str(port)})
    record = {"name": name, "model_profile": model_profile,
              "n_cpu_moe": n_cpu_moe, "lazy_mode": lazy_mode,
              "mtp": mtp, "ctx_size": ctx_size, "tokens": tokens,
              "port": port, "log": str(log),
              "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    process = None
    before = vmstat()
    try:
        with log.open("wb") as stream:
            start = time.monotonic()
            process = subprocess.Popen([str(ROOT / "run-server.sh")], env=env,
                                       stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            with Watchdog(process) as watch:
                for _ in range(2400):
                    if watch.reason or process.poll() is not None or healthy(port):
                        break
                    time.sleep(0.5)
                record["startup_seconds"] = time.monotonic() - start
                record["startup_ok"] = process.poll() is None and healthy(port) and not watch.reason
                if record["startup_ok"]:
                    record["chat_smoke"] = post(port, "/v1/chat/completions", {
                        "model": "qwen3.8-flash-next",
                        "messages": [{"role": "user", "content": "Reply with exactly: READY"}],
                        "temperature": 0, "seed": 424242, "max_tokens": 32,
                    }, 600)
                    post(port, "/completion", {"prompt": "warmup", "n_predict": 8,
                                               "temperature": 0, "seed": 424242,
                                               "cache_prompt": False}, 600)
                    measured_vm_before = vmstat()
                    measured_disk_before = diskstat()
                    measured_mem_before = meminfo()
                    request_start = time.monotonic()
                    completion = post(port, "/completion", {
                        "prompt": PROMPT, "n_predict": tokens, "temperature": 0,
                        "seed": 424242, "cache_prompt": False,
                    }, 900)
                    record["request_seconds"] = time.monotonic() - request_start
                    record["completion"] = {
                        "content": completion.get("content", ""),
                        "tokens_predicted": completion.get("tokens_predicted"),
                        "stop_type": completion.get("stop_type"),
                        "timings": completion.get("timings", {}),
                    }
                    record["measured_vmstat_delta"] = delta(vmstat(), measured_vm_before)
                    record["measured_disk_delta"] = delta(diskstat(), measured_disk_before)
                    record["measured_mem_before"] = measured_mem_before
                    record["measured_mem_after"] = meminfo()
                record["watchdog"] = watch.summary()
    except Exception as error:
        record["error"] = repr(error)
    finally:
        terminate(process)
        record["exit_code"] = process.returncode if process else None
        record["total_vmstat_delta"] = delta(vmstat(), before)
        record["ended_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-profile", choices=("q4", "iq4"), default="q4")
    parser.add_argument("--profiles", nargs="+", type=int, default=[32, 28, 24])
    parser.add_argument("--lazy", choices=("on", "off", "auto"), default="on")
    parser.add_argument("--mtp", action="store_true")
    parser.add_argument("--ctx", type=int, default=int(CONFIG["DEFAULT_CTX"]))
    parser.add_argument("--tokens", type=int, default=128)
    parser.add_argument("--port", type=int, default=int(CONFIG["DEFAULT_PORT"]))
    parser.add_argument("--output")
    args = parser.parse_args()
    output = Path(args.output) if args.output else ROOT / "results" / time.strftime("%Y%m%d-%H%M%S")
    if output.exists():
        parser.error(f"output already exists: {output}")
    output.mkdir(parents=True)
    result = {
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "options": vars(args), "block_device": BLOCK,
        "runtime_version": "\n".join(filter(None, (
            lambda completed: (completed.stdout.strip(), completed.stderr.strip())
        )(subprocess.run(
            [str(Path(CONFIG["LLAMA_BIN"]) / "llama-server"), "--version"],
            env={**os.environ, "LD_LIBRARY_PATH": CONFIG["LLAMA_BIN"]},
            text=True, capture_output=True)))),
        "cases": [],
    }
    for profile in args.profiles:
        case = run_case(args.model_profile, profile, args.lazy, args.mtp,
                        args.ctx, args.tokens, args.port, output)
        result["cases"].append(case)
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        speed = case.get("completion", {}).get("timings", {}).get("predicted_per_second")
        print(case["name"], "ok=" + str(case.get("startup_ok")), "tg=" + str(speed), flush=True)
        if case.get("watchdog", {}).get("reason"):
            break
    successful = [case for case in result["cases"] if case.get("completion")]
    if successful:
        reference = successful[0]["completion"]["content"]
        result["exact_completion_across_successful_cases"] = all(
            case["completion"]["content"] == reference for case in successful)
    result["completed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print("Results:", output)


if __name__ == "__main__":
    main()
