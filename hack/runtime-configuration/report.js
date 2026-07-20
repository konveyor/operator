#!/usr/bin/env node
// hack/runtime-deployment.js - Runtime deployment introspection for konveyor-operator
//
// Queries a live cluster to report all container images, CRD instances, and
// deployment topology for the Konveyor operator stack.
//
// Usage:
//   node hack/runtime-deployment.js                        # markdown (default)
//   node hack/runtime-deployment.js --json                 # JSON output
//   node hack/runtime-deployment.js -n <namespace>         # custom namespace
//
// Requires: kubectl (or oc) in PATH, Node.js >= 22
//
// To support new CRDs:
//   1. Add a collector function in the "CRD Collectors" section
//   2. Register it in the CRD_COLLECTORS array
//   3. Add a renderer function in the "Markdown Renderers" section
//   4. Register it in the SECTION_RENDERERS array
//
// No external dependencies - uses child_process and Node.js built-ins only.

import { execSync } from "node:child_process";
import { parseArgs } from "node:util";

import componentMap from "./known-components-flags-map.json" with { type: "json" };

// ─────────────────────────────────────────────────────────────────────────────
// CLI Argument Parsing
// ─────────────────────────────────────────────────────────────────────────────

const { values: args } = parseArgs({
  options: {
    namespace: { type: "string", short: "n", default: "konveyor-tackle" },
    json: { type: "boolean", default: false },
    help: { type: "boolean", short: "h", default: false },
  },
  strict: true,
});

if (args.help) {
  console.log(`Usage: node hack/runtime-deployment.js [OPTIONS]

Query a live cluster to report all container images and CRD instances
for the Konveyor operator stack.

Options:
  -n, --namespace NS    Namespace (default: konveyor-tackle)
  --json                Output as JSON
  -h, --help            Show this help

Requires: kubectl (or oc) in PATH`);
  process.exit(0);
}

const NAMESPACE = args.namespace;

// ─────────────────────────────────────────────────────────────────────────────
// Kubectl Execution
// ─────────────────────────────────────────────────────────────────────────────

const KUBECTL = resolveKubectl();

function resolveKubectl() {
  try {
    execSync("which kubectl", { stdio: "pipe" });
    return "kubectl";
  } catch {
    try {
      execSync("which oc", { stdio: "pipe" });
      return "oc";
    } catch {
      fatal("neither kubectl nor oc found in PATH");
    }
  }
}

function kubectl(resource, opts = {}) {
  const ns = opts.allNamespaces ? "" : `-n ${NAMESPACE}`;
  const output = opts.outputType || "json";
  const cmd = `${KUBECTL} get ${resource} ${ns} -o ${output}`;
  try {
    const result = execSync(cmd, { stdio: "pipe", encoding: "utf-8" });
    return output === "json" ? JSON.parse(result) : result;
  } catch {
    return opts.fallback ?? null;
  }
}

function kubectlRaw(cmd) {
  try {
    return execSync(`${KUBECTL} ${cmd}`, { stdio: "pipe", encoding: "utf-8" });
  } catch {
    return null;
  }
}

function fatal(msg) {
  console.error(`Error: ${msg}`);
  process.exit(1);
}

// ─────────────────────────────────────────────────────────────────────────────
// Verify Cluster Access
// ─────────────────────────────────────────────────────────────────────────────

if (!kubectlRaw(`get namespace ${NAMESPACE}`)) {
  fatal(
    `cannot access namespace '${NAMESPACE}'. Check cluster connectivity and namespace name.`
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Core Data Collectors
// ─────────────────────────────────────────────────────────────────────────────

function collectOperator() {
  const deploy = kubectl(`deployment/tackle-operator`, {
    fallback: null,
  });
  if (!deploy) return null;

  const container = deploy.spec.template.spec.containers[0];
  const envMap = Object.fromEntries(
    (container.env || []).map((e) => [e.name, e.value])
  );

  const relatedImages = Object.fromEntries(
    Object.entries(envMap).filter(([k]) => k.startsWith("RELATED_IMAGE_"))
  );

  return {
    image: container.image,
    appName: envMap.APP_NAME || "unknown",
    version: envMap.VERSION || "unknown",
    profile: envMap.PROFILE || "unknown",
    relatedImages,
  };
}

function collectFeatureFlags(tackleSpec) {
  const defs = componentMap.feature_flags || {};
  const flags = {};
  for (const [flag, def] of Object.entries(defs)) {
    const specVal = tackleSpec[flag];
    if (specVal == null) {
      flags[flag] = def.default;
    } else {
      flags[flag] = String(specVal).toLowerCase() === "true" || specVal === true;
    }
  }
  return flags;
}

function buildImageCatalog(relatedImages, featureFlags) {
  const components = componentMap.components || {};
  return Object.entries(relatedImages).map(([envVar, image]) => {
    const mapping = components[envVar];
    const condition = mapping?.condition || "always";
    let active;
    if (condition === "always") {
      active = true;
    } else {
      active = featureFlags[condition] === true;
    }
    return {
      envVar,
      image,
      component: mapping?.component || null,
      condition,
      deploymentPrefix: mapping?.deployment_prefix || null,
      inMap: !!mapping,
      active,
    };
  });
}

function collectRunningContainers() {
  const deployments = kubectl("deployments", { fallback: { items: [] } });
  const containers = [];
  for (const deploy of deployments.items || []) {
    const name = deploy.metadata.name;
    for (const c of deploy.spec.template.spec.containers || []) {
      containers.push({
        deployment: name,
        container: c.name,
        image: c.image,
      });
    }
  }
  return containers;
}

function collectCrOverrides(tackleSpec) {
  const overrides = {};
  for (const [key, val] of Object.entries(tackleSpec)) {
    if (key.endsWith("_fqin")) {
      overrides[key] = val;
    }
  }
  return overrides;
}

// ─────────────────────────────────────────────────────────────────────────────
// CRD Collectors
// ─────────────────────────────────────────────────────────────────────────────
// Each collector returns { kind, items[] } where items have a consistent shape.
// To support a new CRD, add a function here and register it in CRD_COLLECTORS.

function collectTackleCR() {
  const result = kubectl("tackles.tackle.konveyor.io", {
    fallback: { items: [] },
  });
  const items = (result.items || []).map((item) => ({
    name: item.metadata.name,
    spec: item.spec || {},
    status: item.status || {},
    conditions: item.status?.conditions || [],
  }));
  return { kind: "Tackle", items };
}

function collectAddons() {
  const result = kubectl("addons.tackle.konveyor.io", {
    fallback: { items: [] },
  });
  const items = (result.items || []).map((item) => ({
    name: item.metadata.name,
    image: item.spec?.container?.image || item.spec?.image || null,
    task: item.spec?.task || null,
    selector: item.spec?.selector || null,
  }));
  return { kind: "Addon", items };
}

function collectExtensions() {
  const result = kubectl("extensions.tackle.konveyor.io", {
    fallback: { items: [] },
  });
  const items = (result.items || []).map((item) => ({
    name: item.metadata.name,
    image: item.spec?.container?.image || null,
    addon: item.spec?.addon || null,
    selector: item.spec?.selector || null,
    metadata: item.spec?.metadata || {},
  }));
  return { kind: "Extension", items };
}

function collectTasks() {
  const result = kubectl("tasks.tackle.konveyor.io", {
    fallback: { items: [] },
  });
  const items = (result.items || []).map((item) => ({
    name: item.metadata.name,
    dependencies: item.spec?.dependencies || [],
    priority: item.spec?.priority ?? null,
    data: item.spec?.data || {},
  }));
  return { kind: "Task", items };
}

function collectSchemas() {
  const result = kubectl("schemas.tackle.konveyor.io", {
    fallback: { items: [] },
  });
  const items = (result.items || []).map((item) => ({
    name: item.metadata.name,
    domain: item.spec?.domain || null,
    subject: item.spec?.subject || null,
    variant: item.spec?.variant || null,
  }));
  return { kind: "Schema", items };
}

function collectCSV() {
  const result = kubectl("csv", { fallback: { items: [] } });
  const csv = (result.items || []).find((i) =>
    i.metadata.name.includes("konveyor")
  );
  if (!csv) return null;
  const related = (csv.spec?.relatedImages || []).map((r) => ({
    name: r.name,
    image: r.image,
  }));
  return { name: csv.metadata.name, relatedImages: related };
}

/**
 * Registry of CRD collectors.
 * To add support for a new CRD:
 *   1. Write a collect function above
 *   2. Add it here with a key matching the CRD's Kind
 */
const CRD_COLLECTORS = {
  Tackle: collectTackleCR,
  Addon: collectAddons,
  Extension: collectExtensions,
  Task: collectTasks,
  Schema: collectSchemas,
};

// ─────────────────────────────────────────────────────────────────────────────
// Drift Detection
// ─────────────────────────────────────────────────────────────────────────────

function detectDrift(catalog, runningContainers) {
  const drifts = [];
  for (const entry of catalog) {
    if (!entry.active || !entry.deploymentPrefix) continue;
    const running = runningContainers.find((c) =>
      c.deployment.startsWith(entry.deploymentPrefix)
    );
    if (running && running.image !== entry.image) {
      drifts.push({
        component: entry.component || entry.envVar,
        configured: entry.image,
        running: running.image,
        envVar: entry.envVar,
      });
    }
  }
  return drifts;
}

// ─────────────────────────────────────────────────────────────────────────────
// Relationship Graph Builder
// ─────────────────────────────────────────────────────────────────────────────

function buildRelationshipGraph(crds) {
  const tasks = crds.Task?.items || [];
  const addons = crds.Addon?.items || [];
  const extensions = crds.Extension?.items || [];

  const graph = tasks.map((task) => {
    const matchingAddons = addons.filter((a) => {
      if (!a.task) return false;
      try {
        return new RegExp(a.task).test(task.name);
      } catch {
        return a.task === task.name;
      }
    });

    const addonEntries = matchingAddons.map((addon) => {
      const matchingExtensions = extensions.filter((ext) => {
        if (!ext.addon) return false;
        try {
          return new RegExp(ext.addon).test(addon.name);
        } catch {
          return ext.addon === addon.name;
        }
      });
      return { ...addon, extensions: matchingExtensions };
    });

    return {
      task: task.name,
      priority: task.priority,
      dependencies: task.dependencies,
      addons: addonEntries,
    };
  });

  return graph;
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Collection
// ─────────────────────────────────────────────────────────────────────────────

const operator = collectOperator();
if (!operator) fatal("cannot find tackle-operator deployment");

const crds = {};
for (const [kind, collector] of Object.entries(CRD_COLLECTORS)) {
  crds[kind] = collector();
}

const tackleSpec = crds.Tackle.items[0]?.spec || {};
const tackleConditions = crds.Tackle.items[0]?.conditions || [];
const featureFlags = collectFeatureFlags(tackleSpec);
const imageCatalog = buildImageCatalog(operator.relatedImages, featureFlags);
const crOverrides = collectCrOverrides(tackleSpec);
const runningContainers = collectRunningContainers();
const drift = detectDrift(imageCatalog, runningContainers);
const csv = collectCSV();
const relationshipGraph = buildRelationshipGraph(crds);

// ─────────────────────────────────────────────────────────────────────────────
// JSON Output
// ─────────────────────────────────────────────────────────────────────────────

if (args.json) {
  const report = {
    namespace: NAMESPACE,
    generatedAt: new Date().toISOString(),
    operator: {
      image: operator.image,
      appName: operator.appName,
      version: operator.version,
      profile: operator.profile,
    },
    featureFlags,
    imageCatalog,
    crOverrides,
    runningContainers,
    crds: {
      addons: crds.Addon.items,
      extensions: crds.Extension.items,
      tasks: crds.Task.items,
      schemas: crds.Schema.items,
    },
    relationshipGraph,
    csv: csv
      ? { name: csv.name, relatedImages: csv.relatedImages }
      : null,
    tackleStatus: tackleConditions,
    drift,
  };
  console.log(JSON.stringify(report, null, 2));
  process.exit(0);
}

// ─────────────────────────────────────────────────────────────────────────────
// Markdown Renderers
// ─────────────────────────────────────────────────────────────────────────────
// Each renderer is a function that returns a string (or empty string to skip).
// To add a new section, write a renderer and register it in SECTION_RENDERERS.

function renderHeader() {
  return `# Konveyor Operator - Runtime Deployment Report

**Namespace:** \`${NAMESPACE}\`
**Generated:** ${new Date().toISOString()}`;
}

function renderOperator() {
  return `## Operator

| Field | Value |
|-------|-------|
| Deployment | \`tackle-operator\` |
| Image | \`${operator.image}\` |
| Version | \`${operator.version}\` |
| Profile | \`${operator.profile}\` |`;
}

function renderTackleStatus() {
  if (tackleConditions.length === 0) return "";
  const rows = tackleConditions.map(
    (c) =>
      `| \`${c.type}\` | ${c.status === "True" ? "✅" : "❌"} ${c.status} | ${c.reason || "-"} | ${c.message || "-"} |`
  );
  return `## Tackle CR Status

| Condition | Status | Reason | Message |
|-----------|--------|--------|---------|
${rows.join("\n")}`;
}

function renderFeatureFlags() {
  const defs = componentMap.feature_flags || {};
  const rows = Object.entries(featureFlags).map(
    ([flag, val]) =>
      `| \`${flag}\` | \`${val}\` | ${defs[flag]?.description || "-"} |`
  );
  return `## Feature Flags

These flags determine which optional components are deployed.

| Flag | Value | Effect |
|------|-------|--------|
${rows.join("\n")}`;
}

function renderImageCatalog() {
  const rows = imageCatalog.map((entry) => {
    const status = entry.active ? "🟢 ACTIVE" : "⚫ INACTIVE";
    let name;
    if (entry.inMap) {
      name = entry.component;
    } else {
      const readable = entry.envVar
        .replace("RELATED_IMAGE_", "")
        .replaceAll("_", " ")
        .toLowerCase();
      name = `⚠️  ${readable} (unmapped)`;
    }
    return `| ${status} | ${name} | \`${entry.envVar}\` | \`${entry.image}\` |`;
  });

  const unmapped = imageCatalog.filter((e) => !e.inMap);
  let note = "";
  if (unmapped.length > 0) {
    note = `\n> **Note:** ${unmapped.length} image(s) not in component map. Update \`hack/report-images-map.json\`.`;
  }

  return `## Image Catalog (from Operator Deployment env)

All images the operator is configured to deploy. Status reflects current feature flags.

| Status | Component | Env Var | Image |
|--------|-----------|---------|-------|
${rows.join("\n")}${note}`;
}

function renderCrOverrides() {
  const entries = Object.entries(crOverrides);
  if (entries.length === 0) {
    return `## Tackle CR Overrides

_No image overrides in Tackle CR spec._`;
  }
  const rows = entries.map(
    ([field, img]) => `| \`${field}\` | \`${img}\` |`
  );
  return `## Tackle CR Overrides

| CR Field | Image |
|----------|-------|
${rows.join("\n")}`;
}

function renderRunningContainers() {
  const rows = runningContainers.map(
    (c) => `| \`${c.deployment}\` | \`${c.container}\` | \`${c.image}\` |`
  );
  return `## Running Containers

| Deployment | Container | Image |
|------------|-----------|-------|
${rows.join("\n")}`;
}

function renderAddons() {
  const items = crds.Addon.items;
  if (items.length === 0) return `## Addon CRs\n\n_No Addon CRs found._`;
  const rows = items.map(
    (a) => `| \`${a.name}\` | \`${a.image || "n/a"}\` | \`${a.task || "-"}\` |`
  );
  return `## Addon CRs

| Name | Image | Task Pattern |
|------|-------|--------------|
${rows.join("\n")}`;
}

function renderExtensions() {
  const items = crds.Extension.items;
  if (items.length === 0)
    return `## Extension CRs\n\n_No Extension CRs found._`;
  const rows = items.map((e) => {
    const img = e.image || "(uses generic provider)";
    return `| \`${e.name}\` | \`${img}\` | \`${e.addon || "-"}\` | \`${e.selector || "-"}\` |`;
  });
  return `## Extension CRs

| Name | Image | Addon Pattern | Selector |
|------|-------|---------------|----------|
${rows.join("\n")}`;
}

function renderTasks() {
  const items = crds.Task.items;
  if (items.length === 0) return `## Task CRs\n\n_No Task CRs found._`;
  const rows = items.map((t) => {
    const deps = t.dependencies.length > 0 ? t.dependencies.join(", ") : "-";
    return `| \`${t.name}\` | ${t.priority ?? "-"} | ${deps} |`;
  });
  return `## Task CRs

| Name | Priority | Dependencies |
|------|----------|--------------|
${rows.join("\n")}`;
}

function renderSchemas() {
  const items = crds.Schema.items;
  if (items.length === 0) return "";
  const rows = items.map(
    (s) =>
      `| \`${s.name}\` | ${s.domain || "-"} | ${s.subject || "-"} | ${s.variant || "-"} |`
  );
  return `## Schema CRs

| Name | Domain | Subject | Variant |
|------|--------|---------|---------|
${rows.join("\n")}`;
}

function renderRelationshipGraph() {
  if (relationshipGraph.length === 0) return "";

  const lines = ["## Task → Addon → Extension Graph", ""];
  lines.push(
    "Shows which addons serve each task, and which extensions attach to those addons.",
    ""
  );

  for (const entry of relationshipGraph) {
    const deps =
      entry.dependencies.length > 0
        ? ` (depends on: ${entry.dependencies.join(", ")})`
        : "";
    lines.push(
      `- **Task: \`${entry.task}\`** [priority: ${entry.priority ?? "default"}]${deps}`
    );
    if (entry.addons.length === 0) {
      lines.push("  - _(no matching addon)_");
    }
    for (const addon of entry.addons) {
      lines.push(
        `  - Addon: \`${addon.name}\` → image: \`${addon.image || "n/a"}\``
      );
      for (const ext of addon.extensions || []) {
        lines.push(
          `    - Extension: \`${ext.name}\` → image: \`${ext.image || "(generic)"}\` [selector: ${ext.selector || "-"}]`
        );
      }
    }
  }
  return lines.join("\n");
}

function renderCSV() {
  if (!csv) return "";
  const rows = csv.relatedImages.map(
    (r) => `| \`${r.name}\` | \`${r.image}\` |`
  );
  return `## OLM ClusterServiceVersion - Related Images

CSV: \`${csv.name}\`

| Name | Image |
|------|-------|
${rows.join("\n")}`;
}

function renderDrift() {
  if (drift.length === 0) {
    return `## Image Drift Detection

_No drift detected. All running images match operator configuration._`;
  }
  const rows = drift.map(
    (d) =>
      `| ${d.component} | \`${d.configured}\` | \`${d.running}\` | \`${d.envVar}\` |`
  );
  return `## Image Drift Detection

| Component | Configured | Running | Env Var |
|-----------|------------|---------|---------|
${rows.join("\n")}`;
}

/**
 * Ordered list of section renderers.
 * To add a new report section, write a render function and add it here.
 */
const SECTION_RENDERERS = [
  renderHeader,
  renderOperator,
  renderTackleStatus,
  renderFeatureFlags,
  renderImageCatalog,
  renderCrOverrides,
  renderRunningContainers,
  renderAddons,
  renderExtensions,
  renderTasks,
  renderSchemas,
  renderRelationshipGraph,
  renderCSV,
  renderDrift,
];

// ─────────────────────────────────────────────────────────────────────────────
// Render Markdown
// ─────────────────────────────────────────────────────────────────────────────

const sections = SECTION_RENDERERS.map((fn) => fn()).filter(Boolean);
console.log(sections.join("\n\n"));
