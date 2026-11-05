"""Exercise curated content image resolution with the shared Ansible role runner."""

import json
import unittest

import yaml

from ansible_test_case import AnsibleTestCase


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


class DefaultImagesTest(AnsibleTestCase):
    def setUp(self):
        super().setUp()
        self.defaults = self.role / "templates/agentic/defaults"
        self.env.update({
            "RELATED_IMAGE_AGENT_JAVA": "registry.example/java@sha256:1234",
            "RELATED_IMAGE_AGENT_SKILLS": "registry.example/skills:release",
            "RELATED_IMAGE_NEW_RUNTIME": "registry.example/new:release",
            "NOT_A_RELATED_IMAGE": "registry.example/wrong:release",
        })

    def cycle(self):
        return [{"include_tasks": str(self.role / "tasks" / name)}
                for name in ("agentic-defaults.yml", "agentic-status.yml")]

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
