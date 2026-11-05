"""Shared runner for the agentic role tests; only the Kubernetes boundary is replaced."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
ACTION = """
import json
import os
from pathlib import Path
from ansible.plugins.action import ActionBase

class ActionModule(ActionBase):
    def run(self, tmp=None, task_vars=None):
        path = Path(os.environ["AGENTIC_TEST_STATE"])
        state = json.loads(path.read_text())
        args = self._task.args
        module = self._task.action.split(".")[-1]
        if module == "k8s_info":
            if args["kind"] == "Deployment":
                return {"resources": [{"status": {"replicas": 1, "readyReplicas": 1, "updatedReplicas": 1}}]}
            labels = dict(selector.split("=", 1) for selector in args.get("label_selectors", []))
            return {"resources": [obj for obj in state["objects"].values()
                if obj["kind"] == args["kind"]
                and ("name" not in args or obj["metadata"]["name"] == args["name"])
                and ("namespace" not in args or obj["metadata"].get("namespace", task_vars["app_namespace"]) == args["namespace"])
                and all(obj["metadata"].get("labels", {}).get(key) == value for key, value in labels.items())]}
        if module == "k8s_status":
            state["conditions"].append(args["conditions"][0])
            state["snapshots"].append(dict(state["objects"]))
        else:
            obj = args.get("definition")
            if "template" in args:
                template = str(Path(task_vars["role_path"]) / "templates" / args["template"])
                expression = "{{ lookup('template', " + repr(template) + ") | from_yaml }}"
                try:
                    from ansible.template import trust_as_template
                except ImportError:
                    pass
                else:
                    expression = trust_as_template(expression)
                obj = self._templar.template(expression)
            kind = obj["kind"] if obj else args["kind"]
            name = obj["metadata"]["name"] if obj else args["name"]
            key = kind + "/" + name
            if args["state"] == "absent":
                state["objects"].pop(key, None)
            else:
                if name == os.environ.get("AGENTIC_TEST_FAIL_NAME"):
                    return {"failed": True, "msg": "simulated Kubernetes API failure"}
                if "definition" in args:
                    assert args["server_side_apply"] == {"field_manager": "agentic-controller-defaults", "force_conflicts": True}
                state["objects"].setdefault(key, {}).update(obj)
        path.write_text(json.dumps(state))
        return {"changed": True}
"""


class AnsibleTestCase(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name)
        self.role = self.path / "role"
        shutil.copytree(ROOT / "roles/tackle", self.role)
        plugins = self.path / "action_plugins"
        plugins.mkdir()
        for name in ("k8s", "k8s_info"):
            (plugins / (name + ".py")).write_text(ACTION)
        collection = self.path / "collections/ansible_collections/operator_sdk/util/plugins/action"
        collection.mkdir(parents=True)
        (collection / "k8s_status.py").write_text(ACTION)
        self.state_file = self.path / "state.json"
        self.state_file.write_text(json.dumps({"objects": {}, "conditions": [], "snapshots": []}))
        self.env = {
            key: value for key, value in os.environ.items() if not key.startswith("RELATED_IMAGE_")
        }
        self.env.update(
            {
                "ANSIBLE_LOCAL_TEMP": str(self.path / "local"),
                "ANSIBLE_REMOTE_TEMP": str(self.path / "remote"),
                "ANSIBLE_ACTION_PLUGINS": str(plugins),
                "ANSIBLE_COLLECTIONS_PATH": str(self.path / "collections"),
                "ANSIBLE_COLLECTIONS_PATHS": str(self.path / "collections"),
                "AGENTIC_TEST_STATE": str(self.state_file),
            }
        )
        self.variables = {
            "app_name": "tackle",
            "app_namespace": "test",
            "agentic_state": "present",
            "agentic_enabled": True,
            "agentic_sandbox_crd_present": True,
            "agentic_component_name": "agentic-controller",
            "agentic_fqin": "registry.example/controller:test",
            "ansible_operator_meta": {"name": "tackle", "namespace": "test"},
        }

    def run_tasks(self, tasks, success=True):
        # Load defaults as role defaults, so CR values and set_fact can override them.
        (self.role / "tasks/__test.yml").write_text(yaml.safe_dump(tasks))
        play = [
            {
                "hosts": "localhost",
                "connection": "local",
                "gather_facts": False,
                "vars": self.variables,
                "tasks": [{"import_role": {"name": str(self.role), "tasks_from": "__test.yml"}}],
            }
        ]
        playbook = self.path / "play.yml"
        playbook.write_text(yaml.safe_dump(play))
        result = subprocess.run(
            ["ansible-playbook", "-i", "localhost,", str(playbook)],
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout)
        if not success:
            self.assertIn("simulated Kubernetes API failure", result.stdout)
        return json.loads(self.state_file.read_text())
