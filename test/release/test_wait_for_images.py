"""Run with python3 -m unittest discover -s test/release -v."""

from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "hack/wait-for-images.py"
SPEC = importlib.util.spec_from_file_location("wait_for_images", SCRIPT)
waiter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(waiter)


class WaitForImagesTest(unittest.TestCase):
    def test_checks_concurrently_and_retries_only_missing_images(self):
        # Both first checks must start before either can finish.
        barrier = threading.Barrier(2, timeout=2)
        calls = {"published:v1": 0, "building:v1": 0}

        def inspect(image, timeout):
            calls[image] += 1
            if calls[image] == 1:
                barrier.wait()
                if image == "building:v1":
                    return "manifest unknown"
            return None

        output = io.StringIO()
        with patch.object(waiter, "inspect_image", side_effect=inspect), redirect_stdout(output):
            result = waiter.wait_for_images(list(calls), timeout=3, interval=0.01)
        self.assertTrue(result)
        self.assertEqual(calls, {"published:v1": 1, "building:v1": 2})
        self.assertIn("1/2 images ready", output.getvalue())
        self.assertIn("Waiting: building:v1: manifest unknown", output.getvalue())
        self.assertIn("All release images are available", output.getvalue())

    def test_shared_deadline_and_final_errors_for_every_missing_image(self):
        output = io.StringIO()
        started = time.monotonic()
        with patch.object(waiter, "inspect_image", return_value="manifest unknown"), redirect_stdout(output):
            result = waiter.wait_for_images(["one:v1", "two:v1"], timeout=0.1, interval=180)
        self.assertFalse(result)
        self.assertLess(time.monotonic() - started, 1)
        self.assertIn("Missing: one:v1: manifest unknown", output.getvalue())
        self.assertIn("Missing: two:v1: manifest unknown", output.getvalue())

    def test_registry_requests_are_bounded_by_remaining_budget(self):
        output = io.StringIO()
        real_run = subprocess.run

        def slow_registry(command, **kwargs):
            return real_run([sys.executable, "-c", "import time; time.sleep(10)"], **kwargs)

        started = time.monotonic()
        with patch.object(waiter.subprocess, "run", side_effect=slow_registry) as run:
            with redirect_stdout(output):
                self.assertFalse(waiter.wait_for_images(["slow:v1"], timeout=0.1, interval=180))
        self.assertLess(time.monotonic() - started, 1)
        self.assertLessEqual(run.call_args.kwargs["timeout"], 0.1)
        self.assertIn("Registry check timed out", output.getvalue())

    def test_registry_errors_are_preserved(self):
        result = subprocess.CompletedProcess([], 1, stderr="unauthorized: access denied\n")
        with patch.object(waiter.subprocess, "run", return_value=result):
            self.assertEqual(waiter.inspect_image("private:v1", 1), "unauthorized: access denied")

    def test_empty_input_cannot_pass(self):
        with self.assertRaisesRegex(ValueError, "must not be empty"):
            waiter.wait_for_images([])


if __name__ == "__main__":
    unittest.main()
