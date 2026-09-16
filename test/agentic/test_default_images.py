"""Exercise the real Ansible defaults/status tasks with an in-memory Kubernetes API.

Run: python3 -m unittest discover -s test/agentic -v
Requires PyYAML and ansible-playbook. No cluster or collections are required.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]

# Replace only the Kubernetes boundary; discovery, lookups, conditionals, facts,
# object merging, and task includes execute in Ansible itself.
ACTION = '''
import json
import os
from ansible.plugins.action import ActionBase

class ActionModule(ActionBase):
    def run(self, tmp=None, task_vars=None):
        path = os.environ["AGENTIC_TEST_STATE"]
        with open(path) as stream:
            state = json.load(stream)
        args = self._task.args
        module = self._task.action.split(".")[-1]
        if module == "k8s_info":
            if args["kind"] == "Deployment":
                return {"resources": [{"status": {"replicas": 1, "readyReplicas": 1, "updatedReplicas": 1}}]}
            return {"resources": [obj for obj in state["objects"].values()
                                  if obj["kind"] == args["kind"]
                                  and obj["metadata"].get("labels", {}).get("app.kubernetes.io/managed-by") == "agentic-controller-defaults"]}
        if module == "k8s_status":
            state["conditions"].append(args["conditions"][0])
            state["snapshots"].append(dict(state["objects"]))
        elif args["state"] == "absent":
            state["objects"].pop(args["kind"] + "/" + args["name"], None)
        else:
            obj = args["definition"]
            if obj["metadata"]["name"] == os.environ.get("AGENTIC_TEST_FAIL_NAME"):
                return {"failed": True, "msg": "simulated Kubernetes API failure"}
            assert args["server_side_apply"] == {"field_manager": "agentic-controller-defaults", "force_conflicts": True}
            state["objects"][obj["kind"] + "/" + obj["metadata"]["name"]] = obj
        with open(path, "w") as stream:
            json.dump(state, stream)
        return {"changed": True}
'''


def resource(name, binding=None, image=True, managed=True):
    obj = {"apiVersion": "konveyor.io/v1alpha1", "kind": "Agent",
           "metadata": {"name": name}, "spec": {"description": "preserve me"}}
    if managed:
        obj["metadata"]["labels"] = {"app.kubernetes.io/managed-by": "agentic-controller-defaults"}
    if image:
        obj["spec"]["image"] = "quay.io/example/original:latest"
    if binding is not None:
        obj["metadata"]["annotations"] = {"konveyor.io/related-image": binding}
    return obj


class DefaultImagesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.role = self.path / "role"
        shutil.copytree(ROOT / "roles/tackle/tasks", self.role / "tasks")
        self.defaults = self.role / "templates/agentic/defaults"
        shutil.copytree(ROOT / "roles/tackle/templates/agentic/defaults", self.defaults)
        plugins = self.path / "action_plugins"
        plugins.mkdir()
        for name in ("k8s", "k8s_info"):
            (plugins / (name + ".py")).write_text(ACTION)
        collection = self.path / "collections/ansible_collections/operator_sdk/util/plugins/action"
        collection.mkdir(parents=True)
        (collection / "k8s_status.py").write_text(ACTION)
        self.state_file = self.path / "state.json"
        self.state_file.write_text(json.dumps({"objects": {}, "conditions": [], "snapshots": []}))
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("RELATED_IMAGE_")}
        self.env.update({
            "ANSIBLE_LOCAL_TEMP": str(self.path / "local"),
            "ANSIBLE_REMOTE_TEMP": str(self.path / "remote"),
            "ANSIBLE_ACTION_PLUGINS": str(plugins),
            "ANSIBLE_COLLECTIONS_PATH": str(self.path / "collections"),
            "ANSIBLE_COLLECTIONS_PATHS": str(self.path / "collections"),
            "AGENTIC_TEST_STATE": str(self.state_file),
            "RELATED_IMAGE_AGENT_JAVA": "registry.example/java@sha256:1234",
            "RELATED_IMAGE_AGENT_SKILLS": "registry.example/skills:release",
            "RELATED_IMAGE_NEW_RUNTIME": "registry.example/new:release",
            "NOT_A_RELATED_IMAGE": "registry.example/wrong:release",
        })

    def cycle(self):
        return [{"include_tasks": str(self.role / "tasks" / name)}
                for name in ("agentic-defaults.yml", "agentic-status.yml")]

    def run_tasks(self, tasks, success=True):
        play = [{"hosts": "localhost", "connection": "local", "gather_facts": False,
                 "vars": {"role_path": str(self.role), "app_namespace": "test",
                          "agentic_state": "present", "agentic_enabled": True,
                          "agentic_sandbox_crd_present": True,
                          "agentic_component_name": "agentic-controller",
                          "ansible_operator_meta": {"name": "tackle", "namespace": "test"}},
                 "tasks": tasks}]
        playbook = self.path / "play.yml"
        playbook.write_text(yaml.safe_dump(play))
        result = subprocess.run(["ansible-playbook", "-i", "localhost,", str(playbook)],
                                env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("simulated Kubernetes API failure", result.stdout)
        return json.loads(self.state_file.read_text())

    def test_shipped_images_and_generic_binding(self):
        self.write_default(resource("new-runtime", "RELATED_IMAGE_NEW_RUNTIME"))
        state = self.run_tasks(self.cycle())
        self.assertEqual(state["conditions"][-1]["reason"], "DeploymentReady")
        for path in self.defaults.glob("*.yaml"):
            original = yaml.safe_load(path.read_text())
            installed = state["objects"][original["kind"] + "/" + original["metadata"]["name"]]
            if "image" in original.get("spec", {}):
                binding = original["metadata"]["annotations"]["konveyor.io/related-image"]
                original["spec"]["image"] = self.env[binding]
            self.assertEqual(installed, original)

    def write_default(self, obj):
        path = self.defaults / (obj["metadata"]["name"] + ".yaml")
        path.write_text(yaml.safe_dump(obj))
        return path

    def test_partial_success_recovery_and_disable(self):
        null_annotations = resource("null-annotations")
        null_annotations["metadata"]["annotations"] = None
        bad = [resource("missing"), resource("unknown", "RELATED_IMAGE_UNKNOWN"),
               resource("empty", "RELATED_IMAGE_EMPTY"), resource("wrong", "NOT_A_RELATED_IMAGE"),
               resource("boolean-binding", True), resource("numeric-binding", 123),
               null_annotations]
        self.env["RELATED_IMAGE_EMPTY"] = "   "
        for obj in bad:
            self.write_default(obj)
        self.write_default(resource("no-image", "NOT_A_RELATED_IMAGE", image=False))
        image_free_null_annotations = resource("no-image-null-annotations", image=False)
        image_free_null_annotations["metadata"]["annotations"] = None
        self.write_default(image_free_null_annotations)
        preserved = resource("unknown", "RELATED_IMAGE_UNKNOWN")
        customer = resource("customer", managed=False)
        orphan = resource("orphan")
        self.state_file.write_text(json.dumps({"objects": {"Agent/unknown": preserved,
            "Agent/customer": customer, "Agent/orphan": orphan}, "conditions": [], "snapshots": []}))
        repairs = [{"copy": {"dest": str(self.defaults / (obj["metadata"]["name"] + ".yaml")),
                              "content": yaml.safe_dump(resource(obj["metadata"]["name"], "RELATED_IMAGE_AGENT_JAVA"))}}
                   for obj in bad]
        state = self.run_tasks(self.cycle() + repairs + self.cycle() +
                               [{"set_fact": {"agentic_state": "absent", "agentic_enabled": False}}] + self.cycle())
        first, recovered, disabled = state["snapshots"]
        error, ready, off = state["conditions"]
        self.assertEqual(str(error["status"]), "False")
        self.assertEqual(error["reason"], "DefaultContentImageBindingInvalid")
        for obj in bad:
            self.assertIn("Agent/" + obj["metadata"]["name"], error["message"])
        self.assertEqual(first["Agent/unknown"], preserved)
        self.assertNotIn("Agent/missing", first)
        self.assertNotIn("Agent/null-annotations", first)
        self.assertNotIn("Agent/orphan", first)
        self.assertIn("Agent/no-image", first)
        self.assertEqual(first["Agent/no-image-null-annotations"], image_free_null_annotations)
        self.assertIn("Agent/migration-plan-agent", first)
        self.assertEqual(str(ready["status"]), "True")
        self.assertEqual(ready["reason"], "DeploymentReady")
        for obj in bad:
            self.assertEqual(recovered["Agent/" + obj["metadata"]["name"]]["spec"]["image"],
                             self.env["RELATED_IMAGE_AGENT_JAVA"])
        self.assertEqual(off["reason"], "Disabled")
        self.assertEqual(disabled, {"Agent/customer": customer})

    def test_kubernetes_failures_are_not_suppressed(self):
        self.env["AGENTIC_TEST_FAIL_NAME"] = "migration-plan-agent"
        self.run_tasks(self.cycle(), success=False)


if __name__ == "__main__":
    unittest.main()
