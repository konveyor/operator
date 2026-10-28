"""Exercise metrics reconciliation in Ansible with only Kubernetes replaced."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
ACTION = '''
import json
import os
from pathlib import Path
from ansible.plugins.action import ActionBase

class ActionModule(ActionBase):
    def run(self, tmp=None, task_vars=None):
        path = os.environ["AGENTIC_METRICS_TEST_STATE"]
        with open(path) as stream:
            state = json.load(stream)
        if self._task.action == "k8s_info":
            return {"resources": [{}] if task_vars.get("agentic_test_monitor_present", True) else []}
        args = self._task.args
        template = str(Path(task_vars["agentic_test_templates"]) / args["template"])
        expression = "{{ lookup('template', " + repr(template) + ") | from_yaml }}"
        # Ansible 2.19+ requires dynamically built test expressions to be trusted.
        try:
            from ansible.template import trust_as_template
        except ImportError:
            pass
        else:
            expression = trust_as_template(expression)
        obj = self._templar.template(expression)
        key = obj["kind"] + "/" + obj["metadata"]["name"]
        if args["state"] == "absent":
            state["objects"].pop(key, None)
        else:
            state["objects"][key] = obj
        state["calls"].append([key, args["state"]])
        with open(path, "w") as stream:
            json.dump(state, stream)
        return {"changed": True}
'''


class MetricsLifecycleTest(unittest.TestCase):
    def run_metrics(self, changes=None, monitor_present=True):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            plugins = path / "action_plugins"
            plugins.mkdir()
            for name in ("k8s", "k8s_info"):
                (plugins / (name + ".py")).write_text(ACTION)
            state = path / "state.json"
            state.write_text(json.dumps({"objects": {}, "calls": []}))
            cycle = {"include_tasks": str(ROOT / "roles/tackle/tasks/agentic-metrics.yml")}
            tasks = [cycle]
            if changes:
                tasks.extend([{"set_fact": changes}, cycle])
            play = [{
                "hosts": "localhost", "connection": "local", "gather_facts": False,
                "vars_files": [str(ROOT / "roles/tackle/defaults/main.yml")],
                "vars": {"agentic_state": "present", "agentic_test_monitor_present": monitor_present,
                         "agentic_test_templates": str(ROOT / "roles/tackle/templates")},
                "tasks": tasks,
            }]
            playbook = path / "play.yml"
            playbook.write_text(yaml.safe_dump(play))
            env = dict(os.environ, ANSIBLE_ACTION_PLUGINS=str(plugins),
                       ANSIBLE_LOCAL_TEMP=str(path / "local"),
                       ANSIBLE_REMOTE_TEMP=str(path / "remote"),
                       AGENTIC_METRICS_TEST_STATE=str(state))
            result = subprocess.run(["ansible-playbook", "-i", "localhost,", str(playbook)],
                                    env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertEqual(result.returncode, 0, result.stdout)
            return json.loads(state.read_text())

    def test_enabled_metrics_create_scrape_resources(self):
        state = self.run_metrics()
        self.assertEqual(set(state["objects"]), {
            "Service/agentic-controller-metrics", "ConfigMap/agentic-controller-metrics-ca",
            "Secret/agentic-controller-metrics-token", "ServiceMonitor/agentic-controller-metrics",
        })

    def test_missing_monitor_crd_preserves_endpoint_resources(self):
        state = self.run_metrics(monitor_present=False)
        self.assertEqual(len(state["objects"]), 3)
        self.assertFalse(any(key.startswith("ServiceMonitor/") for key in state["objects"]))

    def test_disabling_metrics_or_controller_cleans_up_scrape_resources(self):
        for changes in ({"agentic_metrics_enabled": False}, {"agentic_state": "absent"}):
            with self.subTest(changes=changes):
                state = self.run_metrics(changes)
                self.assertEqual(state["objects"], {})
                self.assertEqual([call[1] for call in state["calls"]], ["present"] * 4 + ["absent"] * 4)


if __name__ == "__main__":
    unittest.main()
