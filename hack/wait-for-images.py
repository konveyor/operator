#!/usr/bin/env python3
"""Wait for registry manifests listed in a file, one image reference per line."""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import math
from pathlib import Path
import subprocess
import time


def inspect_image(image, timeout):
    """Check the published tag without downloading image layers."""
    try:
        result = subprocess.run(
            ["docker", "manifest", "inspect", image],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return f"Registry check timed out after {timeout:g}s"
    except OSError as error:
        return str(error)
    if result.returncode:
        return result.stderr.strip() or f"Registry check exited {result.returncode}"
    return None


def wait_for_images(images, timeout=7200, interval=180, probe_timeout=30):
    pending = dict.fromkeys(images, "Not checked yet")
    if not pending:
        raise ValueError("Image list must not be empty")
    total = len(pending)
    started = time.monotonic()
    deadline = started + timeout

    with ThreadPoolExecutor(max_workers=total) as executor:
        while pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            checks = {
                executor.submit(inspect_image, image, min(probe_timeout, remaining)): image
                for image in pending
            }
            for future in as_completed(checks):
                image = checks[future]
                error = future.result()
                if error is None:
                    del pending[image]
                    print(f"Ready: {image}", flush=True)
                else:
                    pending[image] = error

            elapsed = time.monotonic() - started
            print(
                f"{total - len(pending)}/{total} images ready; "
                f"elapsed {elapsed:.0f}s / {timeout:g}s",
                flush=True,
            )
            for image, error in pending.items():
                print(f"Waiting: {image}: {error}", flush=True)
            if not pending:
                print("All release images are available.", flush=True)
                return True
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(interval, remaining))

    print("Timed out waiting for release images:", flush=True)
    for image, error in pending.items():
        print(f"Missing: {image}: {error}", flush=True)
    return False


def positive_seconds(value):
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("Must be a positive, finite number of seconds")
    return seconds


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", type=Path)
    parser.add_argument("--timeout", type=positive_seconds, default=7200)
    parser.add_argument("--interval", type=positive_seconds, default=180)
    args = parser.parse_args()
    images = [line.strip() for line in args.images.read_text().splitlines() if line.strip()]
    if not images or any(image == "null" for image in images):
        parser.error("Expected a nonempty list of image references")
    return 0 if wait_for_images(images, args.timeout, args.interval) else 1


if __name__ == "__main__":
    raise SystemExit(main())
