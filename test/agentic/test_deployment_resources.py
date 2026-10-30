"""Render the agentic Deployment with real Ansible defaults and CR overrides.

Run: python3 -m unittest discover -s test/agentic -v
Requires PyYAML and ansible-playbook. No cluster or collections are required.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RESOURCES = {
    "limits": {"cpu": "500m", "memory": "400Mi"},
    "requests": {"cpu": "10m", "memory": "64Mi"},
}


class DeploymentResourcesTest(unittest.TestCase):
    def render_templates(self, templates, overrides=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            play = [{
                "hosts": "localhost",
                "connection": "local",
                "gather_facts": False,
                "vars_files": [str(ROOT / "roles/tackle/defaults/main.yml")],
                "tasks": [{"ansible.builtin.template": {
                    "src": str(ROOT / "roles/tackle/templates" / template),
                    "dest": str(path / Path(template).name),
                }} for template in templates],
            }]
            playbook = path / "play.yml"
            playbook.write_text(yaml.safe_dump(play))
            variables = {
                "app_namespace": "test",
                "app_name": "tackle",
                "agentic_fqin": "registry.example/agentic-controller:test",
            }
            variables.update(overrides or {})
            env = dict(os.environ, ANSIBLE_LOCAL_TEMP=str(path / "local"),
                       ANSIBLE_REMOTE_TEMP=str(path / "remote"))
            result = subprocess.run(
                ["ansible-playbook", "-i", "localhost,", str(playbook),
                 "--extra-vars", json.dumps(variables)],
                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            return {template: list(yaml.safe_load_all((path / Path(template).name).read_text()))
                    for template in templates}

    def render_deployment(self, overrides=None):
        template = "agentic/deployment.yaml.j2"
        return self.render_templates([template], overrides)[template][0]

    def render_resources(self, overrides=None):
        obj = self.render_deployment(overrides)
        return obj["spec"]["template"]["spec"]["containers"][0]["resources"]

    def test_default_resources(self):
        self.assertEqual(self.render_resources(), DEFAULT_RESOURCES)

    def test_all_resource_overrides(self):
        self.assertEqual(self.render_resources({
            "agentic_container_limits_cpu": "1",
            "agentic_container_limits_memory": "512Mi",
            "agentic_container_requests_cpu": "100m",
            "agentic_container_requests_memory": "256Mi",
        }), {
            "limits": {"cpu": "1", "memory": "512Mi"},
            "requests": {"cpu": "100m", "memory": "256Mi"},
        })

    def test_memory_limit_override_preserves_other_resources(self):
        self.assertEqual(self.render_resources({
            "agentic_container_limits_memory": "512Mi",
        }), {
            "limits": {"cpu": "500m", "memory": "512Mi"},
            "requests": {"cpu": "10m", "memory": "64Mi"},
        })

    def test_diagnostics_enabled_by_default_with_profiling_off(self):
        pod = self.render_deployment({"openshift_cluster": True})["spec"]["template"]["spec"]
        manager = pod["containers"][0]
        for arg in ("--metrics-bind-address=:8443", "--metrics-cert-path=/etc/metrics-certs",
                    "--memory-log-interval=30s", "--pprof-bind-address=0"):
            self.assertIn(arg, manager["args"])
        self.assertIn({"name": "https", "containerPort": 8443, "protocol": "TCP"}, manager["ports"])
        self.assertFalse(pod["volumes"][0]["secret"]["optional"])
        self.assertTrue(manager["volumeMounts"][0]["readOnly"])
        self.assertEqual(manager["volumeMounts"][0]["mountPath"], "/etc/metrics-certs")

    def test_disabled_metrics_do_not_require_serving_certificate(self):
        pod = self.render_deployment({"openshift_cluster": True,
                                      "agentic_metrics_enabled": False})["spec"]["template"]["spec"]
        self.assertIn("--metrics-bind-address=0", pod["containers"][0]["args"])
        self.assertTrue(pod["volumes"][0]["secret"]["optional"])

    def test_diagnostic_overrides(self):
        manager = self.render_deployment({"agentic_memory_log_interval": "10s",
                                          "agentic_pprof_bind_address": "127.0.0.1:6060"})["spec"]["template"]["spec"]["containers"][0]
        self.assertIn("--memory-log-interval=10s", manager["args"])
        self.assertIn("--pprof-bind-address=127.0.0.1:6060", manager["args"])
        self.assertNotIn(6060, [port["containerPort"] for port in manager["ports"]])

    def test_metrics_service_scrape_credentials_tls_and_network_policy(self):
        templates = ["agentic/" + name + ".yaml.j2" for name in
                     ("deployment", "service-metrics", "servicemonitor-metrics",
                      "secret-metrics-token", "configmap-metrics-ca")]
        templates.append("networkpolicy.yml.j2")
        objects = self.render_templates(templates, {"openshift_cluster": True})
        deployment, service, monitor, token, ca = [objects[name][0] for name in templates[:5]]
        pod_labels = deployment["spec"]["template"]["metadata"]["labels"]
        for key, value in service["spec"]["selector"].items():
            self.assertEqual(pod_labels[key], value)
        for key, value in monitor["spec"]["selector"]["matchLabels"].items():
            self.assertEqual(service["metadata"]["labels"][key], value)
        endpoint = monitor["spec"]["endpoints"][0]
        self.assertEqual(endpoint["scheme"], "https")
        self.assertEqual(endpoint["port"], service["spec"]["ports"][0]["name"])
        self.assertEqual(endpoint["authorization"]["credentials"],
                         {"name": token["metadata"]["name"], "key": "token"})
        self.assertEqual(token["metadata"]["annotations"]["kubernetes.io/service-account.name"],
                         "agentic-controller-metrics-reader")
        self.assertNotIn("bearerTokenFile", endpoint)
        self.assertNotIn("insecureSkipVerify", endpoint["tlsConfig"])
        self.assertEqual(endpoint["tlsConfig"]["ca"]["configMap"],
                         {"name": ca["metadata"]["name"], "key": "service-ca.crt"})
        self.assertEqual(endpoint["tlsConfig"]["serverName"],
                         service["metadata"]["name"] + ".test.svc")
        self.assertEqual(service["metadata"]["annotations"]["service.beta.openshift.io/serving-cert-secret-name"],
                         deployment["spec"]["template"]["spec"]["volumes"][0]["secret"]["secretName"])
        policy = next(obj for obj in objects["networkpolicy.yml.j2"]
                      if obj["metadata"]["name"] == "tackle-agentic-metrics")
        self.assertEqual(policy["spec"]["podSelector"]["matchLabels"], pod_labels)
        self.assertEqual(policy["spec"]["ingress"], [{
            "from": [{"namespaceSelector": {"matchLabels": {
                "network.openshift.io/policy-group": "monitoring"}}}],
            "ports": [{"port": 8443, "protocol": "TCP"}],
        }])


if __name__ == "__main__":
    unittest.main()
