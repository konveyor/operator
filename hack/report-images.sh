#!/bin/bash
#
# hack/report-images.sh - Runtime image introspection for konveyor-operator
#
# Queries a live cluster to report all container images configured and running
# for the Konveyor operator stack.
#
# Usage:
#   hack/report-images.sh                        # markdown output (default)
#   hack/report-images.sh --json                 # JSON output
#   hack/report-images.sh -n <namespace>         # custom namespace
#   hack/report-images.sh -n <namespace> --json  # both
#
# The component map is loaded from hack/report-images-map.json. Any new
# RELATED_IMAGE_* env vars discovered on the operator that aren't in the map
# will still be reported (as "Unknown" components assumed always active).
#
# Requires: kubectl (or oc), jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="konveyor-tackle"
OUTPUT_FORMAT="markdown"
OPERATOR_DEPLOYMENT="tackle-operator"
MAP_FILE="${SCRIPT_DIR}/report-images-map.json"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Query a live cluster to report all container images for the Konveyor operator.

Options:
  -n, --namespace NS    Namespace where operator is installed (default: konveyor-tackle)
  --json                Output as JSON instead of markdown
  -m, --map FILE        Path to component map JSON (default: hack/report-images-map.json)
  -h, --help            Show this help message

Dependencies: kubectl (or oc), jq
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -m|--map) MAP_FILE="$2"; shift 2 ;;
        --json) OUTPUT_FORMAT="json"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Dependency checks ---

KUBECTL="kubectl"
if ! command -v kubectl &>/dev/null; then
    if command -v oc &>/dev/null; then
        KUBECTL="oc"
    else
        echo "Error: neither kubectl nor oc found in PATH" >&2
        exit 1
    fi
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not found in PATH" >&2
    echo "Install: https://jqlang.github.io/jq/download/" >&2
    exit 1
fi

if [[ ! -f "$MAP_FILE" ]]; then
    echo "Error: component map not found at '$MAP_FILE'" >&2
    echo "Expected alongside this script at hack/report-images-map.json" >&2
    exit 1
fi

# Load and validate the component map
COMPONENT_MAP=$(jq '.components' "$MAP_FILE")
FLAG_DEFINITIONS=$(jq '.feature_flags' "$MAP_FILE")

# Verify cluster connectivity
if ! $KUBECTL get namespace "$NAMESPACE" &>/dev/null; then
    echo "Error: cannot access namespace '$NAMESPACE'. Check cluster connectivity and namespace name." >&2
    exit 1
fi

# --- Data Collection (all as raw JSON) ---

OPERATOR_JSON=$($KUBECTL get deployment "$OPERATOR_DEPLOYMENT" -n "$NAMESPACE" -o json 2>/dev/null || echo '{}')
TACKLE_CR_JSON=$($KUBECTL get tackles.tackle.konveyor.io -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
DEPLOYMENTS_JSON=$($KUBECTL get deployments -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
ADDONS_JSON=$($KUBECTL get addons.tackle.konveyor.io -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
EXTENSIONS_JSON=$($KUBECTL get extensions.tackle.konveyor.io -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')

# CSV may not exist (Helm-only installs)
CSV_JSON=$($KUBECTL get csv -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
CSV_JSON=$(echo "$CSV_JSON" | jq '[.items[] | select(.metadata.name | test("konveyor"))] | if length > 0 then .[0] else null end')

# --- Structured data extraction via jq ---

# Operator metadata and full image catalog from deployment env vars
OPERATOR_DATA=$(echo "$OPERATOR_JSON" | jq '{
  image: .spec.template.spec.containers[0].image,
  app_name: ([.spec.template.spec.containers[0].env[] | select(.name == "APP_NAME")] | first | .value // "unknown"),
  version: ([.spec.template.spec.containers[0].env[] | select(.name == "VERSION")] | first | .value // "unknown"),
  profile: ([.spec.template.spec.containers[0].env[] | select(.name == "PROFILE")] | first | .value // "unknown"),
  image_catalog: ([.spec.template.spec.containers[0].env[] | select(.name | startswith("RELATED_IMAGE_")) | {(.name): .value}] | add // {})
}')

# Tackle CR spec (first item)
TACKLE_SPEC_JSON=$(echo "$TACKLE_CR_JSON" | jq '
  if .items and (.items | length) > 0 then .items[0].spec // {}
  else {}
  end
')

# Feature flags: read from CR spec, apply defaults from the map file
FEATURE_FLAGS=$(jq -n \
  --argjson spec "$TACKLE_SPEC_JSON" \
  --argjson defs "$FLAG_DEFINITIONS" \
  '
  $defs | to_entries | map({
    key: .key,
    value: (
      $spec[.key] as $val |
      .value.default as $default |
      if $val == null then $default
      else ($val | tostring | ascii_downcase == "true")
      end
    )
  }) | from_entries
  ')

# CR image overrides (any spec field ending in _fqin)
CR_OVERRIDES=$(echo "$TACKLE_SPEC_JSON" | jq '[to_entries[] | select(.key | test("_fqin$")) | {(.key): .value}] | add // {}')

# Running containers from all deployments in namespace
RUNNING_CONTAINERS=$(echo "$DEPLOYMENTS_JSON" | jq '[.items[] | .metadata.name as $deploy | .spec.template.spec.containers[] | {deployment: $deploy, container: .name, image: .image}]')

# Addon images
ADDON_IMAGES=$(echo "$ADDONS_JSON" | jq '[.items[] | {(.metadata.name): .spec.container.image}] | add // {}')

# Extension images
EXTENSION_IMAGES=$(echo "$EXTENSIONS_JSON" | jq '[.items[] | {(.metadata.name): .spec.container.image}] | add // {}')

# CSV related images (null if no CSV)
CSV_RELATED=$(echo "$CSV_JSON" | jq 'if . != null then ([.spec.relatedImages[]? | {(.name): .image}] | add // {}) else null end')

# --- Build enriched image catalog ---
# Merges the external component map with dynamically discovered env vars.
# Unknown env vars (not in map) are reported as "Discovered" with condition "always".
IMAGE_CATALOG=$(jq -n \
  --argjson operator "$OPERATOR_DATA" \
  --argjson flags "$FEATURE_FLAGS" \
  --argjson map "$COMPONENT_MAP" \
  '
  [$operator.image_catalog | to_entries[] | {
    env_var: .key,
    image: .value,
    component: ($map[.key].component // null),
    condition: ($map[.key].condition // "always"),
    deployment_prefix: ($map[.key].deployment_prefix // null),
    in_map: ($map[.key] != null),
    active: (
      ($map[.key].condition // "always") as $cond |
      if $cond == "always" then true
      elif $flags[$cond] == true then true
      else false
      end
    )
  }]
  ')

# --- Output ---

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -n \
        --arg ns "$NAMESPACE" \
        --argjson operator "$OPERATOR_DATA" \
        --argjson feature_flags "$FEATURE_FLAGS" \
        --argjson image_catalog "$IMAGE_CATALOG" \
        --argjson cr_overrides "$CR_OVERRIDES" \
        --argjson running_containers "$RUNNING_CONTAINERS" \
        --argjson addon_images "$ADDON_IMAGES" \
        --argjson extension_images "$EXTENSION_IMAGES" \
        --argjson csv_related_images "$CSV_RELATED" \
        '{
          namespace: $ns,
          operator: {
            image: $operator.image,
            app_name: $operator.app_name,
            version: $operator.version,
            profile: $operator.profile
          },
          feature_flags: $feature_flags,
          image_catalog: $image_catalog,
          cr_overrides: $cr_overrides,
          running_containers: $running_containers,
          addon_images: $addon_images,
          extension_images: $extension_images,
          csv_related_images: $csv_related_images
        }'
else
    # --- Markdown output ---

    echo "# Konveyor Operator - Runtime Image Report"
    echo ""
    echo "**Namespace:** \`$NAMESPACE\`"
    echo "**Report generated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo ""

    # Section 1: Operator metadata
    echo "## Operator"
    echo ""
    echo "| Field | Value |"
    echo "|-------|-------|"
    echo "$OPERATOR_DATA" | jq -r '
      "| Deployment | `'"$OPERATOR_DEPLOYMENT"'` |",
      "| Image | `\(.image)` |",
      "| Version | `\(.version)` |",
      "| Profile | `\(.profile)` |"
    '
    echo ""

    # Section 2: Feature Flags (driven by map file)
    echo "## Feature Flags"
    echo ""
    echo "These flags determine which optional components are deployed."
    echo ""
    echo "| Flag | Value | Effect |"
    echo "|------|-------|--------|"
    jq -n --argjson flags "$FEATURE_FLAGS" --argjson defs "$FLAG_DEFINITIONS" \
      '$defs | to_entries[] | "| `\(.key)` | `\($flags[.key])` | \(.value.description) |"' -r
    echo ""

    # Section 3: Image Catalog with active/inactive status
    echo "## Image Catalog (from Operator Deployment env)"
    echo ""
    echo "All images the operator is configured to deploy. Status reflects current feature flags."
    echo ""
    echo "| Status | Component | Env Var | Image |"
    echo "|--------|-----------|---------|-------|"
    echo "$IMAGE_CATALOG" | jq -r '.[] |
      (if .active then "✅ ACTIVE" else "⬚ INACTIVE" end) as $status |
      (if .in_map then .component else "⚠️  \(.env_var | ltrimstr("RELATED_IMAGE_") | gsub("_"; " ") | ascii_downcase) (unmapped)" end) as $name |
      "| \($status) | \($name) | `\(.env_var)` | `\(.image)` |"
    '
    echo ""

    # Warn about unmapped images
    UNMAPPED_COUNT=$(echo "$IMAGE_CATALOG" | jq '[.[] | select(.in_map == false)] | length')
    if [[ "$UNMAPPED_COUNT" -gt 0 ]]; then
        echo "> **Note:** $UNMAPPED_COUNT image(s) found on the operator deployment are not in the component map."
        echo "> Update \`hack/report-images-map.json\` to add component names and activation conditions."
        echo ""
    fi

    # Section 4: Tackle CR Overrides
    echo "## Tackle CR Overrides"
    echo ""
    OVERRIDE_COUNT=$(echo "$CR_OVERRIDES" | jq 'length')
    if [[ "$OVERRIDE_COUNT" -gt 0 ]]; then
        echo "The Tackle CR spec overrides the following images (these take precedence over the operator env vars):"
        echo ""
        echo "| CR Field | Image |"
        echo "|----------|-------|"
        echo "$CR_OVERRIDES" | jq -r 'to_entries[] | "| `\(.key)` | `\(.value)` |"'
    else
        echo "_No image overrides in Tackle CR spec._"
    fi
    echo ""

    # Section 5: Running Containers
    echo "## Running Containers"
    echo ""
    echo "Actual container images currently deployed in the namespace."
    echo ""
    echo "| Deployment | Container | Image |"
    echo "|------------|-----------|-------|"
    echo "$RUNNING_CONTAINERS" | jq -r '.[] | "| `\(.deployment)` | `\(.container)` | `\(.image)` |"'
    echo ""

    # Section 6: Addon CRs
    echo "## Addon CRs"
    echo ""
    ADDON_COUNT=$(echo "$ADDON_IMAGES" | jq 'length')
    if [[ "$ADDON_COUNT" -gt 0 ]]; then
        echo "| Addon Name | Image |"
        echo "|------------|-------|"
        echo "$ADDON_IMAGES" | jq -r 'to_entries[] | "| `\(.key)` | `\(.value)` |"'
    else
        echo "_No Addon CRs found._"
    fi
    echo ""

    # Section 7: Extension CRs
    echo "## Extension CRs"
    echo ""
    EXTENSION_COUNT=$(echo "$EXTENSION_IMAGES" | jq 'length')
    if [[ "$EXTENSION_COUNT" -gt 0 ]]; then
        echo "| Extension Name | Image |"
        echo "|----------------|-------|"
        echo "$EXTENSION_IMAGES" | jq -r 'to_entries[] | "| `\(.key)` | `\(.value)` |"'
    else
        echo "_No Extension CRs found._"
    fi
    echo ""

    # Section 8: CSV (if OLM install)
    CSV_IS_NULL=$(echo "$CSV_RELATED" | jq 'if . == null then "yes" else "no" end' -r)
    if [[ "$CSV_IS_NULL" == "no" ]]; then
        echo "## OLM ClusterServiceVersion - Related Images"
        echo ""
        echo "Images declared in the CSV \`relatedImages\` (used for disconnected/air-gapped installs)."
        echo ""
        echo "| Name | Image |"
        echo "|------|-------|"
        echo "$CSV_RELATED" | jq -r 'to_entries[] | "| `\(.key)` | `\(.value)` |"'
        echo ""
    fi

    # Section 9: Image drift detection
    echo "## Image Drift Detection"
    echo ""
    echo "Compares operator-configured images (env vars) against what is actually running."
    echo ""

    # Use deployment_prefix from the map to match catalog entries to running deployments
    DRIFT=$(jq -n \
        --argjson catalog "$IMAGE_CATALOG" \
        --argjson running "$RUNNING_CONTAINERS" \
        '
        [
          $catalog[] | select(.active and .deployment_prefix != null) |
          . as $entry |
          ($running[] | select(.deployment | startswith($entry.deployment_prefix)) | .image) as $running_img |
          if $running_img != $entry.image then
            {component: ($entry.component // $entry.env_var), configured: $entry.image, running: $running_img, env_var: $entry.env_var}
          else empty
          end
        ] | unique_by(.env_var)
        ')

    DRIFT_COUNT=$(echo "$DRIFT" | jq 'length')
    if [[ "$DRIFT_COUNT" -gt 0 ]]; then
        echo "| Component | Configured | Running | Env Var |"
        echo "|-----------|------------|---------|---------|"
        echo "$DRIFT" | jq -r '.[] | "| \(.component) | `\(.configured)` | `\(.running)` | `\(.env_var)` |"'
    else
        echo "_No drift detected. All running images match operator configuration._"
    fi
    echo ""
fi
