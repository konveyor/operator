# Agent Sandbox development verification

Build and install the operator and bundle from this branch using the
[development instructions](development.md). Agent Sandbox v1.0.0 CRDs are
vendored from the upstream `sandbox-with-extensions.yaml` release asset.
When updating that dependency, refresh all four CRDs and both controller RBAC
roles together, then run `make bundle`.

These checks are manual and intended for a disposable development cluster.

## Managed controller

Enable agentic on an installed Tackle:

```sh
kubectl patch tackle tackle -n konveyor-tackle --type=merge \
  -p '{"spec":{"agentic_enabled":true,"agent_sandbox_managed":true}}'
kubectl wait deployment/tackle-agent-sandbox-controller -n konveyor-tackle \
  --for=condition=Available --timeout=120s
kubectl wait tackle/tackle -n konveyor-tackle \
  --for=condition=AgentSandboxReady --timeout=120s
```

Create a Sandbox and confirm that its controller creates a running pod:

```sh
kubectl apply -n konveyor-tackle -f - <<'EOF'
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: sandbox-smoke
spec:
  podTemplate:
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: sleeper
          image: busybox:1.36
          command: ["sleep", "3600"]
          securityContext:
            runAsUser: 1000
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
EOF
kubectl wait sandbox/sandbox-smoke -n konveyor-tackle \
  --for=condition=Ready --timeout=120s
```

## Existing standalone installation

On a fresh development cluster, install upstream first:

```sh
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.0/sandbox-with-extensions.yaml
kubectl wait deployment/agent-sandbox-controller -n agent-sandbox-system \
  --for=condition=Available --timeout=120s
```

Then install Konveyor through OLM, and repeat on a fresh cluster through Helm.
Create Tackle with `agentic_enabled: true` and `agent_sandbox_managed: false`.
Verify that the external Deployment and ClusterRoleBindings retain their
original UIDs and subjects, no `tackle-agent-sandbox-controller` is created,
the agentic controller starts, and the Sandbox example above becomes ready.
`AgentSandboxReady` should be `Unknown` / `ExternalControllerUnverified`.

Helm skips existing external CRDs, but continues managing CRDs installed by its
own release on subsequent upgrades. Verify both paths with a Helm upgrade and
confirm all four CRDs remain present.

## Toggle and ownership checks

- After the managed-controller check, set `agent_sandbox_managed: false`.
  Verify that Konveyor's controller Deployment and Service disappear, the
  Sandbox and its pod retain their UIDs, and CRDs and RBAC remain present.
  This test intentionally leaves the Sandbox without reconciliation until a
  controller is enabled again.
- Re-enable management and verify the Sandbox still works. Then disable
  `agentic_enabled`; both controllers should disappear and
  `AgentSandboxReady` should be `False` / `AgentSandboxDisabled`.
- With agentic disabled, create a Deployment or Service named
  `tackle-agent-sandbox-controller` without Konveyor's ownership annotation.
  Reconcile again and verify it is untouched. Enable managed agentic and
  verify `AgentSandboxResourceConflict` is reported without adopting it.
- On a disposable cluster with no sandbox workloads, select external mode and
  remove the Sandbox CRD. Reconcile and verify that the agentic Deployment is
  absent, `AgentSandboxMissing` is reported, and the rest of Tackle reconciles.
  Restore the CRD and verify the condition recovers on a subsequent reconcile.

For release validation, check that the generated CSV includes
`RELATED_IMAGE_AGENT_SANDBOX_CONTROLLER`, the four owned CRDs, and cluster
permissions for `agent-sandbox-controller`. The release workflow mirrors the
pinned upstream image and replaces its tag with a digest alongside other
related images.
