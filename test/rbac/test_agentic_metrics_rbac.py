"""Verify metrics authentication and least-privilege scrape identities in Helm/OLM."""

import os
from pathlib import Path
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
READER = "agentic-controller-metrics-reader"


class AgenticMetricsRBACTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rendered = subprocess.check_output(
            [os.environ.get("HELM", "helm"), "template", "test", str(ROOT / "helm")],
            text=True,
        )
        cls.objects = [obj for obj in yaml.safe_load_all(rendered) if obj]
        cls.csv = yaml.safe_load(
            (ROOT / "bundle/manifests/konveyor-operator.clusterserviceversion.yaml").read_text()
        )

    def helm_rules(self, account):
        roles = {obj["roleRef"]["name"] for obj in self.objects
                 if obj["kind"] == "ClusterRoleBinding"
                 and any(subject["kind"] == "ServiceAccount" and subject["name"] == account
                         for subject in obj["subjects"])}
        return [rule for obj in self.objects
                if obj["kind"] == "ClusterRole" and obj["metadata"]["name"] in roles
                for rule in obj["rules"]]

    def bundle_rules(self, account):
        return [rule for permission in self.csv["spec"]["install"]["spec"]["clusterPermissions"]
                if permission["serviceAccountName"] == account for rule in permission["rules"]]

    def assert_authentication_permissions(self, rules):
        for group, resource in (("authentication.k8s.io", "tokenreviews"),
                                ("authorization.k8s.io", "subjectaccessreviews")):
            self.assertTrue(any(group in rule.get("apiGroups", [])
                                and resource in rule.get("resources", [])
                                and "create" in rule["verbs"] for rule in rules), resource)

    def assert_reader_permissions(self, rules):
        self.assertEqual(rules, [{"nonResourceURLs": ["/metrics"], "verbs": ["get"]}])

    def test_helm_controller_can_authenticate_scrapes(self):
        self.assert_authentication_permissions(self.helm_rules("agentic-controller"))

    def test_bundle_controller_can_authenticate_scrapes(self):
        self.assert_authentication_permissions(self.bundle_rules("agentic-controller"))

    def test_helm_reader_can_only_get_metrics(self):
        self.assert_reader_permissions(self.helm_rules(READER))
        self.assertTrue(any(obj["kind"] == "ServiceAccount" and obj["metadata"]["name"] == READER
                            for obj in self.objects))

    def test_bundle_reader_can_only_get_metrics(self):
        self.assert_reader_permissions(self.bundle_rules(READER))


if __name__ == "__main__":
    unittest.main()
