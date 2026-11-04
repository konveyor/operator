# Runtime Configuration Report

Introspects a live cluster running the Konveyor operator and produces a full
report of what is deployed, what images are configured, and how the CRD
instances relate to each other.

## What it looks at

The report queries the following resources in the operator's namespace:

| Resource | What we extract |
|----------|-----------------|
| `Deployment/tackle-operator` | Operator image, version, profile, and the full `RELATED_IMAGE_*` env var catalog |
| `tackles.tackle.konveyor.io` | CR spec (feature flags, image overrides via `*_fqin` fields), CR status conditions |
| `addons.tackle.konveyor.io` | Addon name, container image, task-matching regex |
| `extensions.tackle.konveyor.io` | Extension name, container image (or null → uses generic provider), addon-matching regex, selector |
| `tasks.tackle.konveyor.io` | Task name, priority, dependency list |
| `schemas.tackle.konveyor.io` | Schema name, domain, subject, variant |
| All `Deployments` in namespace | Running container images for drift detection |
| `ClusterServiceVersion` (if OLM) | `relatedImages` declared for disconnected installs |

## What it reports

1. **Operator metadata** — image, version, profile
2. **Tackle CR status** — reconciliation conditions (Ready, Failure, etc.)
3. **Feature flags** — current values vs. defaults, showing which optional
   components are active
4. **Image catalog** — every `RELATED_IMAGE_*` env var, enriched with component
   names from `known-components-flags-map.json`, marked ACTIVE or INACTIVE
   based on feature flags
5. **CR overrides** — any `*_fqin` fields in the Tackle CR spec that override
   the operator's default images
6. **Running containers** — actual images deployed in the namespace
7. **Addon CRs** — images and the task regex they serve
8. **Extension CRs** — images (or generic provider fallback), addon binding,
   and application selectors
9. **Task CRs** — execution priority and dependency graph
10. **Schema CRs** — registered schema definitions
11. **Task → Addon → Extension relationship graph** — how tasks dispatch to
    addons, and which extensions (language providers) attach as sidecars
12. **OLM CSV related images** — if installed via OLM
13. **Image drift detection** — compares configured images against what is
    actually running

## Usage

```bash
# Markdown output (default)
node hack/runtime-configuration/report.js

# JSON output
node hack/runtime-configuration/report.js --json

# Custom namespace
node hack/runtime-configuration/report.js -n my-namespace
```

Requires `kubectl` (or `oc`) in PATH and Node.js >= 22. No npm dependencies.

## Files

| File | Purpose |
|------|---------|
| `report.js` | Main script (Node.js, zero dependencies) |
| `report.sh` | Bash equivalent (uses jq) |
| `known-components-flags-map.json` | Maps `RELATED_IMAGE_*` env vars to human-readable names, activation conditions, and deployment prefixes |

## Extending for new CRDs

When a new CRD is added to the operator (e.g. a hypothetical
`pipelines.tackle.konveyor.io`):

1. **Add a collector** in the "CRD Collectors" section of `report.js` — a
   function that calls `kubectl(...)` and returns `{ kind, items }`.
2. **Register it** in the `CRD_COLLECTORS` object.
3. **Add a renderer** in the "Markdown Renderers" section — a function that
   returns a markdown string for that section.
4. **Register it** in the `SECTION_RENDERERS` array.

If the new CRD carries container images governed by feature flags, also add
its `RELATED_IMAGE_*` entry to `known-components-flags-map.json`.

## Updating the component map

When images are added or removed from `helm/templates/deployment.yaml`, update
`known-components-flags-map.json`:

- `components.<ENV_VAR>.component` — human-readable name
- `components.<ENV_VAR>.condition` — `"always"` or a feature flag key
- `components.<ENV_VAR>.deployment_prefix` — prefix of the Deployment name
  this image ends up in (used for drift detection), or `null` if it runs as a
  task sidecar rather than a long-lived deployment

Any `RELATED_IMAGE_*` env var found on the operator that isn't in the map will
still be reported, flagged as "unmapped" so it's obvious what needs updating.
