"""Check installed agentic permissions in both the Helm chart and OLM bundle."""

import os
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


class AgenticRBACTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rendered = subprocess.check_output(
            [os.environ.get("HELM", "helm"), "template", "test", str(ROOT / "helm")], text=True
        )
        cls.objects = [obj for obj in yaml.safe_load_all(rendered) if obj]
        cls.csv = yaml.safe_load(
            (ROOT / "bundle/manifests/konveyor-operator.clusterserviceversion.yaml").read_text()
        )

    def rules(self, account, cluster=False):
        kind = "ClusterRole" if cluster else "Role"
        roles = {
            obj["roleRef"]["name"]
            for obj in self.objects
            if obj["kind"] == kind + "Binding"
            and obj["roleRef"]["kind"] == kind
            and any(
                subject["kind"] == "ServiceAccount" and subject["name"] == account
                for subject in obj["subjects"]
            )
        }
        return {
            "Helm": [
                rule
                for obj in self.objects
                if obj["kind"] == kind and obj["metadata"]["name"] in roles
                for rule in obj["rules"]
            ],
            "OLM": [
                rule
                for permission in self.csv["spec"]["install"]["spec"][
                    "clusterPermissions" if cluster else "permissions"
                ]
                if permission["serviceAccountName"] == account
                for rule in permission["rules"]
            ],
        }

    def test_operator_can_manage_default_content(self):
        for source, rules in self.rules("tackle-operator").items():
            for resource in ("agents", "agentworkflows", "skillcards", "skillcollections"):
                for verb in ("get", "list", "watch", "create", "update", "patch", "delete"):
                    with self.subTest(source=source, resource=resource, verb=verb):
                        self.assertTrue(
                            any(
                                "konveyor.io" in rule.get("apiGroups", [])
                                and resource in rule.get("resources", [])
                                and verb in rule["verbs"]
                                and not rule.get("resourceNames")
                                for rule in rules
                            )
                        )

    def test_controller_can_authenticate_metrics(self):
        for source, rules in self.rules("agentic-controller", cluster=True).items():
            for group, resource in (
                ("authentication.k8s.io", "tokenreviews"),
                ("authorization.k8s.io", "subjectaccessreviews"),
            ):
                with self.subTest(source=source, resource=resource):
                    self.assertTrue(
                        any(
                            group in rule.get("apiGroups", [])
                            and resource in rule.get("resources", [])
                            and "create" in rule["verbs"]
                            for rule in rules
                        )
                    )

    def test_reader_can_only_scrape_metrics(self):
        reader = "agentic-controller-metrics-reader"
        for source, rules in self.rules(reader, cluster=True).items():
            with self.subTest(source=source):
                self.assertEqual(rules, [{"nonResourceURLs": ["/metrics"], "verbs": ["get"]}])
        self.assertTrue(
            any(
                obj["kind"] == "ServiceAccount"
                and obj["metadata"]["name"] == reader
                and obj.get("automountServiceAccountToken") is False
                for obj in self.objects
            )
        )
