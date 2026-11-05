"""Focused controller rendering and lifecycle regressions using the shared role runner."""

import json

import yaml

from ansible_test_case import AnsibleTestCase


class ControllerTest(AnsibleTestCase):
    def render(self, template):
        output = self.path / "rendered.yml"
        self.run_tasks(
            [{"template": {"src": str(self.role / "templates" / template), "dest": str(output)}}]
        )
        return [obj for obj in yaml.safe_load_all(output.read_text()) if obj]

    def test_resource_defaults_and_cr_overrides(self):
        manager = self.render("agentic/deployment.yaml.j2")[0]["spec"]["template"]["spec"][
            "containers"
        ][0]
        self.assertEqual(
            manager["resources"],
            {
                "limits": {"cpu": "500m", "memory": "400Mi"},
                "requests": {"cpu": "10m", "memory": "64Mi"},
            },
        )
        self.assertIn("--metrics-bind-address=:8443", manager["args"])
        self.assertIn("--memory-log-interval=30s", manager["args"])
        self.assertIn("--pprof-bind-address=0", manager["args"])

        self.variables.update(
            agentic_container_limits_cpu="1",
            agentic_container_limits_memory="512Mi",
            agentic_container_requests_cpu="100m",
            agentic_container_requests_memory="256Mi",
            agentic_metrics_enabled=False,
        )
        manager = self.render("agentic/deployment.yaml.j2")[0]["spec"]["template"]["spec"][
            "containers"
        ][0]
        self.assertEqual(
            manager["resources"],
            {
                "limits": {"cpu": "1", "memory": "512Mi"},
                "requests": {"cpu": "100m", "memory": "256Mi"},
            },
        )
        self.assertIn("--metrics-bind-address=0", manager["args"])

    def test_metrics_ingress_allows_only_the_metrics_port_without_namespace_labels(self):
        policy = next(
            obj
            for obj in self.render("networkpolicy.yml.j2")
            if obj["metadata"]["name"] == "tackle-agentic-metrics"
        )
        self.assertEqual(
            policy["spec"]["podSelector"]["matchLabels"]["app.kubernetes.io/name"],
            "agentic-controller",
        )
        self.assertEqual(
            policy["spec"]["ingress"], [{"ports": [{"port": 8443, "protocol": "TCP"}]}]
        )

    def test_metrics_lifecycle(self):
        tasks = [{"include_tasks": str(self.role / "tasks/agentic-metrics.yml")}]
        monitor = "ServiceMonitor/agentic-controller-metrics"
        ca = "ConfigMap/agentic-controller-metrics-ca"
        endpoint = {
            "Service/agentic-controller-metrics",
            ca,
            "Secret/agentic-controller-metrics-token",
        }
        state = self.run_tasks(tasks)
        self.assertEqual(set(state["objects"]), endpoint)

        crd = "CustomResourceDefinition/servicemonitors.monitoring.coreos.com"
        state["objects"][crd] = {
            "kind": "CustomResourceDefinition",
            "metadata": {"name": "servicemonitors.monitoring.coreos.com"},
        }
        self.state_file.write_text(json.dumps(state))
        state = self.run_tasks(tasks)
        self.assertNotIn(monitor, state["objects"])  # CRD alone is not enough without CA data.

        state["objects"][ca]["data"] = {"service-ca.crt": "test-ca"}
        self.state_file.write_text(json.dumps(state))
        ready = self.run_tasks(tasks)
        self.assertEqual(set(ready["objects"]), endpoint | {crd, monitor})

        ready_state = json.dumps(ready)
        del ready["objects"][ca]["data"]
        self.state_file.write_text(json.dumps(ready))
        state = self.run_tasks(tasks)
        self.assertEqual(set(state["objects"]), endpoint | {crd})

        for changes in ({"agentic_metrics_enabled": False}, {"agentic_state": "absent"}):
            with self.subTest(changes=changes):
                self.state_file.write_text(ready_state)
                self.variables.update(agentic_metrics_enabled=True, agentic_state="present")
                self.variables.update(changes)
                self.assertEqual(set(self.run_tasks(tasks)["objects"]), {crd})
