# Tackle2-Operator OIDC Refactoring - Implementation Plan

**Date**: 2026-05-30  
**Branch**: oidc2  
**Purpose**: Implementation plan for OIDC refactoring based on REQUIREMENTS.md

---

## Overview

### Goals
Remove operator responsibility for deploying/managing Keycloak/RHBK/RHSSO because Hub now provides OIDC functionality directly.

### Documents
- **CURRENT.md**: Baseline - current auth implementation on konveyor/main
- **REQUIREMENTS.md**: Target - desired state after refactoring
- **This document**: Implementation strategy and phased approach

### Key Changes
1. **Remove**: All Keycloak deployment/management code (~700 lines of tasks, 13 templates)
2. **Add**: IdpClient CR creation, Keycloak detection logic, Hub OIDC env vars
3. **Modify**: Hub/UI deployments, llm-proxy configuration, upgrade handling

---

## Implementation Strategy

### Approach: Incremental with Feature Flag

**Phase 1**: Preparation (validate, copy CRDs)  
**Phase 2**: Core Changes (remove Keycloak deployment, add detection)  
**Phase 3**: Environment Variables (Hub/UI OIDC configuration)  
**Phase 4**: LLM Proxy Routing (apply patch changes)  
**Phase 5**: Upgrade Logic (IdentityProvider CR creation on detection)  
**Phase 6**: Cleanup (remove variables, update documentation)  
**Phase 7**: Testing & Validation

Each phase should be independently testable.

---

## Phase 1: Preparation & CRD Management

### 1.1 Copy CRDs from Hub

**Source**: tackle2-hub repository CRD definitions  
**Destination**: `roles/tackle/templates/`

**CRDs to copy**:
- `crd-idpclient.yml.j2` - OIDC clients that authenticate to Hub
- `crd-identityprovider.yml.j2` - External OIDC IdPs for federation
- `crd-ldapprovider.yml.j2` - LDAP servers for federation

**Action**:
```bash
# Copy CRD YAML from tackle2-hub
# Convert to Jinja2 templates if needed
# Add to roles/tackle/templates/
```

**Validation**: CRDs can be applied to cluster without errors

### 1.2 Add CRD Installation Tasks

**File**: `roles/tackle/tasks/main.yml`

**Location**: Early in task list (before other resource creation)

**Tasks**:
```yaml
- name: "Setup IdpClient CRD"
  k8s:
    state: present
    definition: "{{ lookup('template', 'crd-idpclient.yml.j2') }}"

- name: "Setup IdentityProvider CRD"
  k8s:
    state: present
    definition: "{{ lookup('template', 'crd-identityprovider.yml.j2') }}"

- name: "Setup LdapProvider CRD"
  k8s:
    state: present
    definition: "{{ lookup('template', 'crd-ldapprovider.yml.j2') }}"
```

**Validation**: CRDs appear in `kubectl get crds`

---

## Phase 2: Remove Keycloak Deployment Code

### 2.1 Remove Task Blocks

**File**: `roles/tackle/tasks/main.yml`

**Remove these sections** (per CURRENT.md §5):

| Phase | Lines | Description |
|-------|-------|-------------|
| OAuth Setup | 56-102 | Cookie secret generation, OAuth client secret |
| Keycloak PostgreSQL | 104-163 | PostgreSQL PVC, Deployment, Service, wait |
| PostgreSQL Migration | 164-325 | v12→v15 migration logic |
| Keycloak SSO Setup | 332-413 | Keycloak Deployment, Service, Secret (konveyor) |
| RHBK Setup | 415-548 | RHBK CR, Service, Secret (mta) |
| Keycloak Deprovisioning | 784-813 | Delete Keycloak when auth disabled |
| RHSSO Operator Cleanup | 932-946 | Remove RHSSO Subscription/CSV |

**Total removal**: ~730 lines

**Method**:
- Comment out blocks initially (for rollback)
- Test after each removal
- Delete commented code once stable

### 2.2 Remove Templates

**Directory**: `roles/tackle/templates/`

**Remove these files** (per CURRENT.md §4):

**Keycloak Deployments**:
- `deployment-keycloak-sso.yml.j2`
- `deployment-keycloak-postgresql.yml.j2`

**Keycloak Services**:
- `service-keycloak-sso.yml.j2`
- `service-keycloak-rhbk.yml.j2`
- `service-keycloak-postgresql.yml.j2`
- `service-keycloak-postgresql-migration.yml.j2`

**Keycloak Secrets**:
- `secret-keycloak-sso.yml.j2`
- `secret-keycloak-postgresql.yml.j2`
- `secret-keycloak-db.yml.j2`
- `secret-cookie-secret.yml.j2` (OAuth)

**Keycloak PVC**:
- `persistentvolumeclaim-keycloak-postgresql.yml.j2`

**Keycloak CRs**:
- `customresource-rhbk-keycloak.yml.j2`
- `customresource-rhsso-keycloak.yml.j2`

**Total removal**: 13 templates

**Keep** (still needed):
- `ingress-ui.yml.j2` - `/auth` path routing for backward compatibility
- `route-ui.yml.j2` - May need updates but not removed

### 2.3 Remove OAuth Proxy from UI Deployment

**File**: `roles/tackle/templates/deployment-ui.yml.j2`

**Remove**:
- Lines 38-82: OAuth proxy sidecar container
- Lines 177-181: OAuth-specific volume mounts (conditionally)
- Lines 14-18: OAuth-specific topology annotations

**Keep topology annotation logic but change condition**:
```yaml
# OLD
{% if feature_auth_required|bool and feature_auth_type == "keycloak" %}

# NEW (detect Keycloak at runtime)
{% if keycloak_detected|bool %}
```

---

## Phase 3: Environment Variables

### 3.1 Hub Deployment Changes

**File**: `roles/tackle/templates/deployment-hub.yml.j2`

**Remove** (lines 140-153):
```yaml
- name: KEYCLOAK_ADMIN_USER
- name: KEYCLOAK_ADMIN_PASS
- name: KEYCLOAK_REQ_PASS_UPDATE
```

**Keep** (for IdentityProvider federation):
```yaml
- name: KEYCLOAK_REALM
- name: KEYCLOAK_CLIENT_ID
- name: KEYCLOAK_HOST
- name: KEYCLOAK_AUDIENCE
```

**Note**: These will be conditionally set only when IdentityProvider CR exists

**Remove** (lines 11-21):
```yaml
# OAuth-specific topology annotation - replace with detection
```

**Add**:
```yaml
- name: APIKEY_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ hub_secret_name }}
      key: apikey-secret

{% if kai_llm_proxy_enabled|bool %}
- name: LLM_PROXY_URL
  value: "{{ kai_llm_proxy_internal_url }}"
{% endif %}
```

**No OIDC_ISSUER** - Hub derives from X-Forwarded-Host

### 3.2 UI Deployment Changes

**File**: `roles/tackle/templates/deployment-ui.yml.j2`

**Remove**:
```yaml
{% if kai_llm_proxy_enabled|bool %}
- name: KAI_LLM_PROXY_URL
  value: "{{ kai_llm_proxy_url }}"
{% endif %}
```

**Update**:
```yaml
- name: AUTH_REQUIRED
  value: "{{ feature_auth_required | string | lower }}"

# ADD
- name: OIDC_ISSUER
  value: "{{ hub_url }}/oidc"
- name: OIDC_CLIENT_ID
  value: "web-ui"

# Conditional - only when Keycloak detected
{% if keycloak_detected|bool %}
- name: KEYCLOAK_SERVER_URL
  value: "{{ keycloak_service_url }}"
{% endif %}
```

### 3.3 Hub Secret Generation

**File**: `roles/tackle/tasks/main.yml`

**Add to Hub secret creation block** (around line 591-599):

```yaml
- name: "Generate Hub API key secret"
  set_fact:
    hub_apikey_secret: "{{ lookup('password', '/dev/null chars=ascii_lowercase,ascii_uppercase,digits length=32') }}"
  when: (hub_secret_status.resources | length) == 0

- name: "Encode Hub API key secret"
  set_fact:
    hub_apikey_secret_b64: "{{ hub_apikey_secret | b64encode }}"
  when: (hub_secret_status.resources | length) == 0
```

**Update secret template**:
```yaml
# In secret-hub.yml.j2
apikey-secret: {{ hub_apikey_secret_b64 }}
```

---

## Phase 4: Keycloak Detection Logic

### 4.1 Add Detection Task Block

**File**: `roles/tackle/tasks/main.yml`

**Location**: Early in execution (after cluster detection, before resource creation)

```yaml
- name: "Detect existing Keycloak deployment"
  block:
    - name: "Check for Keycloak SSO Deployment (konveyor)"
      k8s_info:
        api_version: apps/v1
        kind: Deployment
        name: "{{ app_name }}-keycloak-sso"
        namespace: "{{ app_namespace }}"
      register: keycloak_sso_deployment

    - name: "Check for RHBK StatefulSet (mta)"
      k8s_info:
        api_version: apps/v1
        kind: StatefulSet
        name: "keycloak"
        namespace: "{{ app_namespace }}"
      register: rhbk_statefulset

    - name: "Set Keycloak detection flags"
      set_fact:
        keycloak_detected: "{{ (keycloak_sso_deployment.resources | length > 0) or (rhbk_statefulset.resources | length > 0) }}"
        keycloak_is_rhbk: "{{ rhbk_statefulset.resources | length > 0 }}"

    - name: "Get Keycloak service URL when detected"
      set_fact:
        keycloak_service_url: "{{ 'https://' + app_name + '-rhbk-service.' + app_namespace + '.svc:8443' if keycloak_is_rhbk else 'http://' + app_name + '-keycloak-sso.' + app_namespace + '.svc:8080' }}"
      when: keycloak_detected|bool
```

### 4.2 Use Detection for Conditional Resources

**Templates that need keycloak_detected**:
- `deployment-hub.yml.j2` - topology annotations
- `deployment-ui.yml.j2` - topology annotations, KEYCLOAK_SERVER_URL env var
- `ingress-ui.yml.j2` - `/auth` path routing
- `route-ui.yml.j2` - potentially `/auth` path routing (check if needed)

**Example** (`ingress-ui.yml.j2`):
```yaml
{% if keycloak_detected|bool %}
  - path: /auth
    pathType: Prefix
    backend:
      service:
        name: {{ app_name }}-keycloak-sso
        port:
          number: 8080
{% endif %}
```

---

## Phase 5: IdpClient CR Creation

### 5.1 Create IdpClient Template

The operator must create **all three IdpClient CRs** to support different client types:

1. **web-ui**: Web application client for the UI
2. **kantra**: Native/CLI client for kantra tool
3. **kai-ide**: Native client for IDE extensions (VS Code, etc.)

**File**: `roles/tackle/templates/customresource-idpclients.yml.j2`

```yaml
---
# web-ui client
apiVersion: tackle.konveyor.io/v1alpha1
kind: IdpClient
metadata:
  name: web-ui
  namespace: {{ app_namespace }}
  labels:
    app.kubernetes.io/name: web-ui
    app.kubernetes.io/component: idp-client
    app.kubernetes.io/part-of: {{ app_name }}
spec:
  id: 1
  clientId: web-ui
  applicationType: web
  grants:
  - urn:ietf:params:oauth:grant-type:jwt-bearer
  - authorization_code
  - refresh_token
  redirectURIs:
  - ${issuer.proto}://${issuer.host}*
  scopes:
  - offline_access
  - openid
  - profile
  - email

---
# kantra client (public client - no secret needed)
apiVersion: tackle.konveyor.io/v1alpha1
kind: IdpClient
metadata:
  name: kantra
  namespace: {{ app_namespace }}
  labels:
    app.kubernetes.io/name: kantra
    app.kubernetes.io/component: idp-client
    app.kubernetes.io/part-of: {{ app_name }}
spec:
  id: 2
  clientId: kantra
  applicationType: native
  grants:
  - urn:ietf:params:oauth:grant-type:device_code
  - authorization_code
  - refresh_token
  scopes:
  - offline_access
  - openid
  - profile
  - email

---
# kai-ide client (public client - no secret needed)
apiVersion: tackle.konveyor.io/v1alpha1
kind: IdpClient
metadata:
  name: kai-ide
  namespace: {{ app_namespace }}
  labels:
    app.kubernetes.io/name: kai-ide
    app.kubernetes.io/component: idp-client
    app.kubernetes.io/part-of: {{ app_name }}
spec:
  id: 3
  clientId: kai-ide
  applicationType: native
  grants:
  - urn:ietf:params:oauth:grant-type:jwt-bearer
  - authorization_code
  - refresh_token
  redirectURIs:
  - vscode://konveyor.konveyor-core/auth
  - http://127.0.0.1/callback
  scopes:
  - offline_access
  - openid
  - profile
  - email
```

**Note**: 
- Single template file with all three client definitions (YAML multi-document)
- Hub supports wildcard `"*"` in redirectURIs, so web-ui doesn't need external hostname
- kantra has no redirectURIs (device code flow)
- kai-ide has specific IDE callback URIs

### 5.2 Add IdpClient Creation Task

**File**: `roles/tackle/tasks/main.yml`

**Location**: After CRD installation, before Hub deployment

```yaml
- name: "Create IdpClient CRs (web-ui, kantra, kai-ide)"
  k8s:
    state: present
    definition: "{{ lookup('template', 'customresource-idpclients.yml.j2') }}"
  register: idpclients_result
  failed_when: idpclients_result.failed
```

**Error handling**: Task fails reconciliation if IdpClient creation fails (per REQ-5)

**Rationale**: Creating all three clients ensures:
- Web UI can authenticate users via browser
- kantra CLI tool can authenticate via device code flow
- IDE extensions (VS Code Konveyor plugin) can authenticate with proper callbacks

---

## Phase 6: Upgrade - IdentityProvider CR Creation

### 6.1 Create IdentityProvider Template

**File**: `roles/tackle/templates/customresource-identityprovider.yml.j2`

```yaml
---
apiVersion: tackle.konveyor.io/v1alpha1
kind: IdentityProvider
metadata:
  name: keycloak-{{ app_name }}
  namespace: {{ app_namespace }}
  labels:
    app.kubernetes.io/name: keycloak-{{ app_name }}
    app.kubernetes.io/component: identity-provider
    app.kubernetes.io/part-of: {{ app_name }}
spec:
  # Fields to be defined based on Hub's CRD schema
  # Likely includes:
  # - issuer: "{{ keycloak_service_url }}/auth/realms/{{ app_name }}"
  # - authorizationURL: "{{ keycloak_service_url }}/auth/realms/{{ app_name }}/protocol/openid-connect/auth"
  # - tokenURL: "{{ keycloak_service_url }}/auth/realms/{{ app_name }}/protocol/openid-connect/token"
  # - clientId: "{{ app_name }}-ui"
  # - clientSecret: (from existing secret?)
```

**Note**: Schema depends on Hub CRD - update after copying

### 6.2 Add Upgrade Logic Task

**File**: `roles/tackle/tasks/main.yml`

**Location**: After Keycloak detection block

```yaml
- name: "Create IdentityProvider CR for detected Keycloak"
  when:
    - feature_auth_required|bool
    - keycloak_detected|bool
  k8s:
    state: present
    definition: "{{ lookup('template', 'customresource-identityprovider.yml.j2') }}"
```

**Purpose**: On upgrade from operator-deployed Keycloak, auto-configure Hub to federate

---

## Phase 7: No-Auth Cleanup

### 7.1 Add Keycloak Deletion Task

**File**: `roles/tackle/tasks/main.yml`

**Location**: Replace old deprovisioning block (lines 784-813)

```yaml
- name: "Remove Keycloak resources when auth disabled"
  when: not(feature_auth_required|bool)
  block:
    - name: "Delete Keycloak SSO Deployment"
      k8s:
        state: absent
        api_version: apps/v1
        kind: Deployment
        name: "{{ app_name }}-keycloak-sso"
        namespace: "{{ app_namespace }}"

    - name: "Delete RHBK StatefulSet"
      k8s:
        state: absent
        api_version: apps/v1
        kind: StatefulSet
        name: "keycloak"
        namespace: "{{ app_namespace }}"

    - name: "Delete Keycloak PostgreSQL Deployment"
      k8s:
        state: absent
        api_version: apps/v1
        kind: Deployment
        name: "{{ app_name }}-keycloak-postgresql-15"
        namespace: "{{ app_namespace }}"

    - name: "Delete Keycloak PostgreSQL Service"
      k8s:
        state: absent
        api_version: v1
        kind: Service
        name: "{{ app_name }}-keycloak-postgresql"
        namespace: "{{ app_namespace }}"

    - name: "Delete Keycloak Service"
      k8s:
        state: absent
        api_version: v1
        kind: Service
        name: "{{ app_name }}-keycloak-sso"
        namespace: "{{ app_namespace }}"

    - name: "Delete RHBK Service"
      k8s:
        state: absent
        api_version: v1
        kind: Service
        name: "{{ app_name }}-rhbk-service"
        namespace: "{{ app_namespace }}"
```

**Note**: Secrets and PVCs intentionally NOT deleted (per REQ-8a)

---

## Phase 8: LLM Proxy Routing

### 8.1 Apply llm-proxy-routing.patch Changes

**Reference**: `~/llm-proxy-routing.patch` (commit 6cf0d71)

**Changes**:

1. **Variable rename** (`roles/tackle/defaults/main.yml`):
   ```yaml
   # OLD
   kai_llm_proxy_url: "http://llm-proxy.{{ app_namespace }}.svc.cluster.local:8321"
   
   # NEW
   kai_llm_proxy_internal_url: "http://llm-proxy.{{ app_namespace }}.svc:8321"
   ```

2. **Hub Deployment** (`roles/tackle/templates/deployment-hub.yml.j2`):
   ```yaml
   {% if kai_llm_proxy_enabled|bool %}
   - name: LLM_PROXY_URL
     value: "{{ kai_llm_proxy_internal_url }}"
   {% endif %}
   ```

3. **UI Deployment** (`roles/tackle/templates/deployment-ui.yml.j2`):
   ```yaml
   # REMOVE
   {% if kai_llm_proxy_enabled|bool %}
   - name: KAI_LLM_PROXY_URL
     value: "{{ kai_llm_proxy_url }}"
   {% endif %}
   ```

4. **LLM Proxy ConfigMap** (`roles/tackle/templates/kai/llm-proxy-configmap.yaml.j2`):
   ```yaml
   # REMOVE lines 99-117 (OAuth2 token auth block)
   # ADD comment explaining routing through Hub
   ```

**Method**: Can apply patch directly or manually make changes

---

## Phase 9: Variable Cleanup

### 9.1 Remove Variables from defaults/main.yml

**File**: `roles/tackle/defaults/main.yml`

**Remove these variable groups** (per CURRENT.md §3):

**Keycloak Database** (lines ~86-107):
- All `keycloak_database_*` variables (22 variables)

**Keycloak SSO** (lines ~108-137):
- All `keycloak_sso_*` variables except those needed for detection (29 variables)
- Keep: `keycloak_sso_realm` (for IdentityProvider CR)

**OAuth** (lines ~168-172):
- All `oauth_*` variables (5 variables)
- `cookie_secret_data`

**RHSSO** (lines ~266-274):
- All `rhsso_*` variables (9 variables)

**RHBK** (lines ~277-284):
- All `rhbk_*` variables (7 variables)

**Other**:
- `keycloak_api_audience` (line 130)

**Total removal**: ~73 variables

**Keep for detection/upgrade**:
- `app_name` (used to build resource names for detection)
- Derive service URLs dynamically in detection block

### 9.2 Remove feature_auth_type

**File**: `roles/tackle/defaults/main.yml`

**Remove**:
```yaml
feature_auth_type: keycloak
```

**Keep**:
```yaml
feature_auth_required: "{{ false if app_profile == 'konveyor' else true }}"
```

---

## Phase 10: Update Service/Route Templates

### 10.1 UI Service Template

**File**: `roles/tackle/templates/service-ui.yml.j2`

**Remove OAuth-specific sections**:
```yaml
# Remove lines 3-5 (OAuth annotation)
# Remove lines 11-14 (OAuth port mapping)
# Keep only standard UI service definition
```

**Simplified service**:
```yaml
spec:
  ports:
    - name: ui
      port: {{ ui_port }}
      targetPort: {{ ui_port }}
```

### 10.2 UI Route Template

**File**: `roles/tackle/templates/route-ui.yml.j2`

**Remove OAuth TLS termination override**:
```yaml
# OLD
{% if feature_auth_required|bool and feature_auth_type == "oauth" %}
  termination: reencrypt
{% else %}
  termination: {{ ui_route_tls_termination }}
{% endif %}

# NEW
  termination: {{ ui_route_tls_termination }}
```

### 10.3 UI ServiceAccount Template

**File**: `roles/tackle/templates/serviceaccount-ui.yml.j2`

**Remove OAuth redirect annotation**:
```yaml
# Remove lines 6-7 (OAuth redirect reference)
```

---

## Phase 11: Testing Strategy

### 11.1 Fresh Installation Testing

**Scenario**: New Tackle CR on clean cluster

**Expected Behavior**:
- ✅ CRDs installed
- ✅ IdpClient CR created
- ✅ Hub deployment with APIKEY_SECRET, LLM_PROXY_URL (if kai enabled)
- ✅ Hub deployment NO OIDC_ISSUER
- ✅ UI deployment with OIDC_ISSUER (internal), OIDC_CLIENT_ID
- ✅ No Keycloak resources created
- ✅ No IdentityProvider CR created
- ✅ `keycloak_detected: false`

**Test Cases**:
1. Deploy with `feature_auth_required: true` → Hub standalone OIDC
2. Deploy with `feature_auth_required: false` → No auth
3. Deploy with `kai_llm_proxy_enabled: true` → LLM_PROXY_URL set

### 11.2 Upgrade Testing - With Operator-Deployed Keycloak

**Scenario**: Existing deployment with Keycloak in namespace

**Expected Behavior**:
- ✅ CRDs installed
- ✅ IdpClient CR created
- ✅ IdentityProvider CR created (points to existing Keycloak)
- ✅ Keycloak Deployment/StatefulSet preserved (not deleted)
- ✅ Keycloak Service preserved
- ✅ Keycloak Secret preserved
- ✅ UI KEYCLOAK_SERVER_URL set
- ✅ Ingress/Route `/auth` path routing added
- ✅ Hub/UI topology annotations include Keycloak
- ✅ `keycloak_detected: true`

**Test Cases**:
1. Upgrade konveyor profile with Keycloak SSO
2. Upgrade mta profile with RHBK
3. Verify users can still login via Keycloak
4. Verify `/auth` accessible through ingress/route

### 11.3 Upgrade Testing - No-Auth Mode

**Scenario**: Existing deployment with Keycloak, set `feature_auth_required: false`

**Expected Behavior**:
- ✅ Keycloak Deployment deleted
- ✅ RHBK StatefulSet deleted
- ✅ Keycloak PostgreSQL Deployment deleted
- ✅ Keycloak Services deleted
- ✅ Keycloak Secrets preserved
- ✅ Keycloak PVCs preserved
- ✅ No IdentityProvider CR created
- ✅ UI no KEYCLOAK_SERVER_URL
- ✅ Ingress/Route no `/auth` path

**Test Cases**:
1. Set feature_auth_required: false on existing Keycloak deployment
2. Verify Keycloak pods deleted
3. Verify secrets/PVCs remain

### 11.4 LLM Proxy Testing

**Scenario**: kai_llm_proxy_enabled: true

**Expected Behavior**:
- ✅ Hub has LLM_PROXY_URL env var
- ✅ UI no KAI_LLM_PROXY_URL env var
- ✅ llm-proxy ConfigMap has no auth block
- ✅ Access via `/hub/services/llm-proxy/*` works with auth

**Test Cases**:
1. Run `test/e2e/llm-proxy/test-llm-proxy.sh`
2. Verify auth required for llm-proxy access
3. Verify invalid token rejected

---

## Phase 12: Documentation

### 12.1 Migration Guide

**File**: Create `docs/OIDC-MIGRATION.md`

**Content**:
- Overview of changes
- What happens on upgrade
- How to remove operator-deployed Keycloak after upgrade
- How to configure IdentityProvider CR for external OIDC
- How to configure LdapProvider CR for LDAP
- Troubleshooting common issues

### 12.2 OIDC Configuration Guide

**File**: Create `docs/OIDC-CONFIG.md`

**Content**:
- Hub as OIDC provider architecture
- IdentityProvider CR examples (Okta, Azure AD, external Keycloak)
- LdapProvider CR examples
- IdpClient CR for additional clients
- Token validation and RBAC

### 12.3 Update Main README

**File**: `README.md`

**Add section**:
- Authentication architecture overview
- Link to OIDC-CONFIG.md
- Link to OIDC-MIGRATION.md

---

## Rollout Strategy

### Recommended Order

1. **Phase 1**: CRDs → Validate CRDs install correctly
2. **Phase 2**: Remove templates → Reduce code size
3. **Phase 4**: Detection logic → Foundation for conditionals
4. **Phase 5**: IdpClient creation → Core requirement
5. **Phase 3**: Environment variables → Hub/UI configuration
6. **Phase 6**: IdentityProvider upgrade → Upgrade path
7. **Phase 7**: No-auth cleanup → Auth disabled handling
8. **Phase 8**: LLM proxy routing → Apply patch
9. **Phase 2**: Remove tasks → Final cleanup
10. **Phase 9**: Variable cleanup → Final cleanup
11. **Phase 10**: Service/Route updates → Polish
12. **Phase 11**: Testing → Validation
13. **Phase 12**: Documentation → User-facing

### Validation Between Phases

After each phase:
- ✅ Operator builds successfully
- ✅ Fresh install works
- ✅ Upgrade from previous version works
- ✅ No regression in existing functionality

---

## Risk Mitigation

### High-Risk Changes

1. **Removing ~700 lines of tasks**: Risk of breaking existing deployments
   - Mitigation: Comment out first, test extensively, then delete
   
2. **IdpClient CR schema unknown**: Risk of incorrect CR creation
   - Mitigation: Copy actual CRDs from Hub first, validate schema

3. **Detection logic fragility**: Risk of false positives/negatives
   - Mitigation: Test with multiple deployment scenarios

4. **Upgrade breaking auth**: Risk of users losing access
   - Mitigation: IdentityProvider CR creation ensures continuity

### Rollback Plan

If issues discovered after deployment:
- Document issues in GitHub issue
- **No automated rollback** (per NON-REQ-6)
- Users must manually restore previous operator version
- Preserve all Keycloak resources to enable manual recovery

---

## Success Criteria

Implementation is complete when:

1. ✅ All phases executed successfully
2. ✅ Fresh install works (no Keycloak deployed)
3. ✅ Upgrade preserves Keycloak and creates IdentityProvider CR
4. ✅ No-auth mode deletes Keycloak resources
5. ✅ LLM proxy routing works through Hub
6. ✅ All tests pass (fresh, upgrade, no-auth, llm-proxy)
7. ✅ Documentation complete
8. ✅ Code review approved
9. ✅ No regressions in existing functionality

---

## Open Questions for Implementation

1. ~~**IdpClient CR schema**: What are the exact field names and types?~~
   - **RESOLVED**: Schema from `~/openshift/tackle/oidc/clients.yaml`
   
2. ~~**IdpClient redirectURIs**: How to derive external URL?~~
   - **RESOLVED**: Hub now supports wildcard `"*"` in redirectURIs
   - **ACTION**: Use `redirectURIs: ["*"]` in template
   
3. **IdentityProvider CR schema**: What fields are required?
   - **Action**: Check `~/openshift/tackle/oidc/` for IdentityProvider examples
   
4. **Keycloak client secret**: Does IdentityProvider CR need client secret? Where to get it?
   - **Action**: Check if secret exists, reference in CR
   
5. **Route `/auth` routing**: Does Route need updates like Ingress?
   - **Action**: Test Route behavior with `/auth` path
   
6. **RBAC for CRs**: Do we need ClusterRole updates for IdpClient/IdentityProvider?
   - **Action**: Check if operator ServiceAccount can create these CRs

7. **Error recovery**: If IdentityProvider creation fails on upgrade, how to recover?
   - **Action**: Add retry logic? Fail reconciliation?

These questions should be answered during Phase 1 (Preparation).

---

## Next Steps

1. Review this plan
2. Address open questions
3. Begin Phase 1: Copy CRDs from Hub
4. Implement phases incrementally
5. Test after each phase
6. Document as we go
