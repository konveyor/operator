# Tackle2-Operator Authentication Implementation (konveyor/main)

**Analysis Date**: 2026-05-28  
**Branch**: konveyor/main  
**Purpose**: Baseline documentation of current auth implementation before OIDC refactoring

---

## 1. Authentication Features & Behavior

### High-Level Authentication Model

The tackle2-operator implements two distinct authentication modes controlled by two key variables:

**`feature_auth_required`** (Default: `true` for MTA profile, `false` for Konveyor profile)
- **Purpose**: Master switch that enables/disables authentication entirely
- **When enabled**: Forces all users to authenticate before accessing the system
- **When disabled**: System operates in single-user/no-auth mode (useful for development/testing)

**`feature_auth_type`** (Default: `"keycloak"`)
- **Current implementation**: Only `keycloak` is fully implemented and working
- **Code support for `oauth`**: OAuth proxy support exists in templates and tasks, but is not the default or recommended approach

### Authentication Flow (Keycloak-Based)

1. **Initial Access**: Users access the UI through an Ingress (Kubernetes) or Route (OpenShift)
2. **Keycloak Redirect**: If `feature_auth_required` is true, the UI redirects unauthenticated users to Keycloak
3. **Login**: User authenticates against Keycloak server with username/password
4. **Token Issuance**: Keycloak issues JWT tokens (with realm: `tackle` or `mta` depending on profile)
5. **API Access**: Both UI and backend Hub communicate with Keycloak to validate tokens
6. **Hub Authorization**: Hub validates tokens and enforces access control based on Keycloak realm roles

### Difference: `feature_auth_required` vs `feature_auth_type`

| Variable | Controls | Values |
|----------|----------|--------|
| `feature_auth_required` | **Whether** authentication is mandatory | `true` (enabled) or `false` (disabled) |
| `feature_auth_type` | **What type** of authentication mechanism | `"keycloak"` (default) or `"oauth"` (partial) |

---

## 2. Keycloak Deployment

### When Keycloak is Deployed

Keycloak is deployed when **BOTH** conditions are true:
```yaml
feature_auth_required: true
feature_auth_type: "keycloak"
```

### Profile-Specific Behavior

- **`app_profile: "konveyor"`**: Deploys standard Keycloak (standalone deployment)
- **`app_profile: "mta"`**: Deploys Red Hat Build of Keycloak (RHBK) via operator CR

### Keycloak Resources Created

**For `konveyor` Profile**:
1. **Service**: `{{ app_name }}-keycloak-sso`
2. **Deployment**: `{{ app_name }}-keycloak-sso`
3. **Secrets**:
   - `{{ app_name }}-keycloak-sso` - admin username/password
   - `{{ app_name }}-keycloak-postgresql` - database credentials

**For `mta` Profile**:
1. **Custom Resource (RHBK)**: `{{ app_name }}-rhbk`
   - API Version: `k8s.keycloak.org/v2alpha1`
   - Kind: `Keycloak`
2. **Service**: `{{ app_name }}-rhbk-service`
3. **TLS Secret**: Auto-created by OpenShift service certificate
4. **Secrets**: Same as konveyor profile

**Database Infrastructure** (PostgreSQL, both profiles):
1. **Service**: `{{ app_name }}-keycloak-postgresql`
2. **Deployment**: `{{ app_name }}-keycloak-postgresql-15`
3. **PersistentVolumeClaim**: `{{ app_name }}-keycloak-postgresql-15-volume-claim`
4. **Secret**: Database credentials

---

## 3. Key Variables (roles/tackle/defaults/main.yml)

### Authentication Feature Flags

- `feature_auth_required`: `false` (konveyor) / `true` (mta)
- `feature_auth_type`: `"keycloak"`
- `feature_isolate_namespace`: `true` - Controls network policy creation (namespace isolation)

### Keycloak API Versions

- `rhsso_api_version`: `"keycloak.org/v1alpha1"` (line 269) - Legacy Red Hat SSO operator
- `rhbk_api_version`: `"k8s.keycloak.org/v2alpha1"` (line 279) - Red Hat Build of Keycloak operator

### Keycloak Configuration

- `keycloak_sso_image_fqin`: From `RELATED_IMAGE_KEYCLOAK_SSO`
- `keycloak_sso_name`: `"keycloak"`
- `keycloak_sso_component_name`: `"rhbk"` (mta) / `"sso"` (konveyor)
- `keycloak_sso_service_name`: `{{ app_name }}-keycloak-sso` (or `-rhbk`)
- `keycloak_sso_deployment_name`: Same as service name
- `keycloak_sso_deployment_strategy`: `"Recreate"`
- `keycloak_sso_deployment_replicas`: `1`
- `keycloak_sso_container_limits_cpu`: `1000m`
- `keycloak_sso_container_limits_memory`: `2Gi`
- `keycloak_sso_container_requests_cpu`: `300m`
- `keycloak_sso_container_requests_memory`: `600Mi`
- `keycloak_sso_liveness_init_delay`: `60` seconds
- `keycloak_sso_readiness_init_delay`: `60` seconds
- `keycloak_sso_java_opts`: `"-Dcom.redhat.fips=false"`
- `keycloak_sso_realm`: `{{ app_name }}`
- `keycloak_sso_client_id`: `{{ app_name }}-ui`
- `keycloak_sso_admin_username`: `"admin"`
- `keycloak_sso_admin_password`: **Auto-generated (16 chars, alphanumeric)**
- `keycloak_sso_req_passwd_update`: `true`
- `keycloak_sso_tls_enabled`: `true` (OpenShift) / `false` (K8s)
- `keycloak_sso_tls_secret_name`: `{{ keycloak_sso_service_name }}-serving-cert`
- `keycloak_sso_port`: `8443` (TLS) / `8080` (non-TLS)
- `keycloak_sso_proto`: `https` / `http`
- `keycloak_sso_url`: Internal service URL

### RHSSO Configuration (Legacy Red Hat SSO)

- `rhsso_name`: `"rhsso"`
- `rhsso_service_name`: `{{ app_name }}-rhsso`
- `rhsso_secret_name`: `credential-{{ rhsso_service_name }}`
- `rhsso_api_version`: `"keycloak.org/v1alpha1"`
- `rhsso_external_access`: `false`
- `rhsso_tls_enabled`: `true`
- `rhsso_port`: `8443` (TLS) / `8080` (non-TLS)
- `rhsso_proto`: `https` / `http`
- `rhsso_url`: Service URL for RHSSO

### RHBK Configuration (Red Hat Build of Keycloak - MTA Profile)

- `rhbk_name`: `"rhbk"`
- `rhbk_service_name`: `{{ app_name }}-rhbk`
- `rhbk_tls_secret_name`: `{{ rhbk_service_name }}-serving-cert`
- `rhbk_api_version`: `"k8s.keycloak.org/v2alpha1"`
- `rhbk_port`: `8443` (reuses `rhsso_tls_enabled`)
- `rhbk_proto`: `https` / `http`
- `rhbk_url`: `https://{{ rhbk_service_name }}-service.{{ app_namespace }}.svc:8443`

### OAuth Configuration

- `oauth_provider`: `"openshift"` (default)
- `oauth_default_openshift_sar`: OpenShift Subject Access Review for authorization
- `oauth_access_rule`: `{{ oauth_default_openshift_sar }}` if provider is OpenShift
- `oauth_ssl_port`: `8443` - OAuth proxy HTTPS port
- `oauth_image_fqin`: From `RELATED_IMAGE_OAUTH_PROXY`
- `cookie_secret_data`: **Auto-generated (32 chars)** - OAuth session cookie encryption key
- `oauth_client_secret`: Retrieved from existing secret if present

### Keycloak PostgreSQL

- `keycloak_database_image_fqin`: From `RELATED_IMAGE_TACKLE_POSTGRES` env var
- `keycloak_database_name`: `"keycloak"`
- `keycloak_database_component_name`: `"postgresql"`
- `keycloak_database_service_name`: `{{ app_name }}-keycloak-postgresql`
- `keycloak_database_service_k8s_resource_name`: `{{ app_name }}-kcpgsql` (shortened for migration service)
- `keycloak_database_secret_name`: Same as service name
- `keycloak_database_deployment_name`: Same as service name (v12) or `*-15` (v15)
- `keycloak_database_deployment_strategy`: `"Recreate"`
- `keycloak_database_deployment_replicas`: `1`
- `keycloak_database_container_name`: Same as service name
- `keycloak_database_container_limits_cpu`: `500m`
- `keycloak_database_container_limits_memory`: `800Mi`
- `keycloak_database_container_requests_cpu`: `100m`
- `keycloak_database_container_requests_memory`: `350Mi`
- `keycloak_database_db_name`: `"keycloak_db"`
- `keycloak_database_db_version`: `"15"`
- `keycloak_database_db_username`: **Auto-generated** `"user-XXXX"` (4 random chars)
- `keycloak_database_db_password`: **Auto-generated** (16 chars, alphanumeric)
- `keycloak_database_data_volume_name`: `{{ keycloak_database_service_name }}-database`
- `keycloak_database_data_volume_size`: `"1Gi"`
- `keycloak_database_data_volume_path`: `"/var/lib/pgsql"`
- `keycloak_database_data_volume_claim_name`: `*-{{ keycloak_database_db_version }}-volume-claim`

### Kai PostgreSQL (kai_solution_server_enabled)

- `kai_database_image_fqin`: `{{ keycloak_database_image_fqin }}` - **Reuses Keycloak PostgreSQL image**
- `kai_database_secret_name`: `kai-db-secret`
- `kai_database_volume_size`: `"5Gi"`
- `kai_database_address`: `kai-db.{{ app_namespace }}.svc`

**Note**: Kai and Keycloak use the **same PostgreSQL container image** but have **separate database deployments**, PVCs, and secrets. They are completely independent database instances.

---

## 4. Templates (roles/tackle/templates/)

### Deployment Templates

1. **`deployment-hub.yml.j2`**
   - Topology annotation (lines 11-21): Connects to Keycloak deployment when auth enabled
     - Konveyor: Connects to `{{ keycloak_sso_deployment_name }}` Deployment
     - MTA: Connects to `keycloak` StatefulSet (RHBK-managed)
   - Sets `AUTH_REQUIRED` env var
   - Injects Keycloak config: `KEYCLOAK_REALM`, `KEYCLOAK_CLIENT_ID`, `KEYCLOAK_HOST`
   - Injects admin credentials
   - Sets `KEYCLOAK_AUDIENCE` for JWT validation

2. **`deployment-ui.yml.j2`**
   - OAuth path: Deploys oauth-proxy sidecar
   - Keycloak path: Passes Keycloak realm/client/server URL
   - Sets `AUTH_REQUIRED: "true"`

3. **`deployment-keycloak-sso.yml.j2`** (konveyor profile)
   - Standalone Keycloak deployment
   - PostgreSQL connection details
   - HTTP relative path: `/auth`

4. **`deployment-keycloak-postgresql.yml.j2`**
   - PostgreSQL 15 deployment for Keycloak database
   - Uses `keycloak_database_image_fqin`

### Service Templates

- `service-keycloak-sso.yml.j2`: Keycloak SSO service (konveyor profile)
- `service-keycloak-rhbk.yml.j2`: RHBK service (mta profile)
- `service-keycloak-postgresql.yml.j2`: PostgreSQL database service
- `service-keycloak-postgresql-migration.yml.j2`: Temporary service for v12→v15 migration

### Secret Templates

- `secret-keycloak-sso.yml.j2`: Admin credentials
- `secret-keycloak-postgresql.yml.j2`: Database credentials
- `secret-keycloak-db.yml.j2`: RHBK database config (mta)
- `secret-cookie-secret.yml.j2`: OAuth cookie secret

### PersistentVolumeClaim Templates

- `persistentvolumeclaim-keycloak-postgresql.yml.j2`: Database storage (1Gi default)

### Custom Resource Templates

- `customresource-rhbk-keycloak.yml.j2`: RHBK operator CR (mta)
- `customresource-rhsso-keycloak.yml.j2`: Legacy RHSSO CR

---

## 5. Tasks (roles/tackle/tasks/main.yml)

### Auth-Related Task Execution Order

1. **Phase 1**: Cluster Detection (lines 1-37)
2. **Phase 2**: OAuth Setup (lines 56-102) - if `feature_auth_type == "oauth"`
3. **Phase 3**: Keycloak PostgreSQL (lines 104-163) - if Keycloak enabled
4. **Phase 4**: Database Migration (lines 164-325) - if old v12 exists
5. **Phase 5**: Keycloak Setup (lines 332-413) - konveyor profile
6. **Phase 6**: RHBK Setup (lines 415-548) - mta profile only
7. **Phase 7**: Hub, UI, Addon Resources (lines 560-650)
8. **Phase 8**: Ingress/Route Setup (lines 716-731)
9. **Phase 9**: Cache and Network Policy (lines 733-782)
10. **Phase 10**: Auth Cleanup (lines 784-813) - when auth disabled
11. **Phase 11**: RHSSO Operator Cleanup (lines 932-946) - always runs

### OAuth Secret Generation (Phase 2: lines 56-102)

**Trigger**: When `feature_auth_required: true` AND `feature_auth_type: "oauth"`

**Tasks performed**:

1. **Cookie Secret Creation** (lines 60-89):
   ```yaml
   - Check if Secret "cookie-secret" exists
   - If not: Generate random 32-char secret
   - Create Secret from template: secret-cookie-secret.yml.j2
   - Retrieve and set fact: cookie_secret_data
   ```
   - **Purpose**: Encrypts OAuth proxy session cookies
   - **Generation**: Random alphanumeric, 32 characters
   - **Persistence**: Stored in Secret, reused on subsequent reconciliations

2. **OAuth Client Secret Retrieval** (lines 91-102):
   ```yaml
   - Check if Secret "oauth-client-secret" exists
   - If exists: Set fact oauth_client_secret from Secret data
   ```
   - **Purpose**: OAuth provider client secret (if using external OAuth)
   - **Not auto-generated**: Must be created externally by user
   - **Optional**: Only used if the Secret exists

**Secret Template**: `secret-cookie-secret.yml.j2`

### Network Policy Creation (Phase 9: line 781)

**Trigger**: When `feature_isolate_namespace: true`

**Template**: `networkpolicy.yml.j2`

**Resources Created**:

1. **Deny-All Policy**:
   - Name: `{{ app_name }}-deny-all`
   - Default deny all ingress traffic to namespace

2. **Namespace-Internal Policy**:
   - Name: `{{ app_name }}-namespace`
   - Allow ingress from same namespace only

3. **UI External Access Policy**:
   - Name: `{{ app_name }}-external`
   - Pod selector: `role: {{ ui_service_name }}`
   - Allow ingress on ports 8080, 8443

4. **Hub Metrics Policy**:
   - Name: `{{ app_name }}-metrics`
   - Pod selector: `role: {{ hub_service_name }}`
   - Allow ingress from OpenShift monitoring namespace on metrics port

**Note**: Network policies are for **namespace isolation**, not authentication. They control network traffic regardless of auth mode. However, the external access policy does affect how OAuth proxy and Keycloak are reachable.

### PostgreSQL v12 to v15 Migration (Phase 4: lines 164-325)

**Trigger**: When old `keycloak-postgresql` deployment (v12) exists

**Migration Process**:

1. **Detect Old Version** (lines 164-170):
   - Check for Deployment named `{{ keycloak_database_service_name }}` (without version suffix)
   - If exists, it's PostgreSQL v12 that needs migration

2. **Setup Migration Service** (line 177):
   - Create temporary service: `service-keycloak-postgresql-migration.yml.j2`
   - Service name: `{{ keycloak_database_service_k8s_resource_name }}-migration`
   - Points to old v12 deployment for data export

3. **Scale Down Keycloak** (lines 179-196):
   - **MTA profile**: Scale RHSSO CR to 0 instances
   - **Konveyor profile**: Scale keycloak-sso deployment to 0 replicas
   - Prevents data corruption during migration

4. **Dump Database** (lines 200-275):
   - Connect to old v12 database via migration service
   - Export `keycloak_db` to SQL dump
   - Store dump in temporary location

5. **Deploy New PostgreSQL v15** (lines 276-330):
   - Create new deployment: `{{ keycloak_database_service_name }}-15`
   - Create new PVC: `{{ keycloak_database_service_name }}-15-volume-claim`
   - Create new service pointing to v15 deployment
   - Wait for v15 to be ready

6. **Restore Database** (lines 276-310):
   - Import SQL dump into new v15 database
   - Verify data integrity

7. **Cleanup** (lines 312-325):
   - Remove temporary migration service
   - Delete old v12 deployment
   - **Preserve** old v12 PVC (manual cleanup by user)

**Template Used**: `service-keycloak-postgresql-migration.yml.j2`

**Note**: Old PVC is preserved to prevent data loss. Users must manually delete it after verifying migration success.

### RHSSO Operator Cleanup (Phase 11: lines 932-946)

**Trigger**: Always runs unconditionally (not in auth-disabled block)

**Purpose**: Remove legacy RHSSO operator subscriptions/CSVs

**Tasks**:

1. **Remove RHSSO Subscription** (lines 932-938):
   ```yaml
   api_version: operators.coreos.com/v1alpha1
   kind: Subscription
   label_selectors:
     - operators.coreos.com/rhsso-operator.openshift-mta =
   ```

2. **Remove RHSSO ClusterServiceVersion** (lines 940-946):
   ```yaml
   api_version: operators.coreos.com/v1alpha1
   kind: ClusterServiceVersion
   label_selectors:
     - operators.coreos.com/rhsso-operator.openshift-mta =
   ```

**Note**: This cleanup runs on every reconciliation to ensure legacy RHSSO operator artifacts are removed. The operator was deprecated in favor of RHBK (Red Hat Build of Keycloak).

---

## 6. Hub and UI Deployment Environment Variables

### Hub Deployment (deployment-hub.yml.j2)

#### Authentication Environment Variables

| Line | Variable Name | Value | Condition | Purpose |
|------|---------------|-------|-----------|---------|
| 122-126 | `AUTH_REQUIRED` | `"true"` or `"false"` | Always set | Master auth switch: `"true"` when `feature_auth_required && feature_auth_type == "keycloak"` |
| 129-130 | `KEYCLOAK_REALM` | `{{ keycloak_sso_realm }}` | Keycloak mode only | Keycloak realm name (default: `{{ app_name }}`) |
| 131-132 | `KEYCLOAK_CLIENT_ID` | `{{ keycloak_sso_client_id }}` | Keycloak mode only | OAuth client ID (default: `{{ app_name }}-ui`) |
| 134-139 | `KEYCLOAK_HOST` | `{{ rhbk_url }}` (mta) or `{{ keycloak_sso_url }}` (konveyor) | Keycloak mode only | Keycloak server URL |
| 140-144 | `KEYCLOAK_ADMIN_USER` | Secret: `{{ keycloak_sso_secret_name }}/username` | Keycloak mode only | Keycloak admin username |
| 145-149 | `KEYCLOAK_ADMIN_PASS` | Secret: `{{ keycloak_sso_secret_name }}/password` | Keycloak mode only | Keycloak admin password |
| 150-151 | `KEYCLOAK_REQ_PASS_UPDATE` | `{{ keycloak_sso_req_passwd_update\|lower }}` | Keycloak mode only | Require password change on first login |
| 152-153 | `KEYCLOAK_AUDIENCE` | `{{ keycloak_api_audience }}` (default: `"konveyor-api"`) | Keycloak mode only | JWT audience for token validation |

**Notes**:
- Hub does NOT support OAuth mode - only Keycloak authentication
- Admin credentials allow Hub to manage Keycloak realm/client configuration
- `KEYCLOAK_HOST` varies by profile: konveyor uses standard Keycloak, mta uses RHBK

### UI Deployment (deployment-ui.yml.j2)

#### Authentication Environment Variables

| Line | Variable Name | Value | Condition | Purpose |
|------|---------------|-------|-----------|---------|
| 102-103 | `AUTH_REQUIRED` | `"true"` or `"false"` | Always set | Master auth switch: `"true"` when `feature_auth_required && feature_auth_type == "keycloak"` |
| 104-105 | `KEYCLOAK_REALM` | `{{ keycloak_sso_realm }}` | Keycloak mode only | Keycloak realm name |
| 106-107 | `KEYCLOAK_CLIENT_ID` | `{{ keycloak_sso_client_id }}` | Keycloak mode only | OAuth client ID |
| 109-113 | `KEYCLOAK_SERVER_URL` | `{{ rhbk_url }}` (mta) or `{{ keycloak_sso_url }}` (konveyor) | Keycloak mode only | Keycloak server URL |

**Notes**:
- UI uses `KEYCLOAK_SERVER_URL` while Hub uses `KEYCLOAK_HOST` (naming difference)
- UI does NOT receive admin credentials
- OAuth mode uses sidecar container (oauth-proxy) with command-line args, not env vars

#### OAuth Proxy Sidecar (lines 38-82)

When `feature_auth_required && feature_auth_type == "oauth"`:
- Deploys oauth-proxy container as sidecar
- Uses **command-line arguments** instead of environment variables:
  - `--https-address=:{{ oauth_ssl_port }}`
  - `--provider={{ oauth_provider }}`
  - `--upstream=http://localhost:{{ ui_port }}`
  - `--cookie-secret={{ cookie_secret_data }}`
  - Provider-specific args (OpenShift SAR or generic OAuth)

### Environment Variable Comparison by Scenario

#### Scenario 1: Auth Enabled with Keycloak (`feature_auth_required: true`, `feature_auth_type: "keycloak"`)

**Hub receives**:
```yaml
AUTH_REQUIRED: "true"
KEYCLOAK_REALM: "tackle"  # or "mta"
KEYCLOAK_CLIENT_ID: "tackle-ui"  # or "mta-ui"
KEYCLOAK_HOST: "http://tackle-keycloak-sso.konveyor-tackle.svc:8080"  # or rhbk_url
KEYCLOAK_ADMIN_USER: "admin"  # from secret
KEYCLOAK_ADMIN_PASS: "<auto-generated>"  # from secret
KEYCLOAK_REQ_PASS_UPDATE: "true"
KEYCLOAK_AUDIENCE: "konveyor-api"
```

**UI receives**:
```yaml
AUTH_REQUIRED: "true"
KEYCLOAK_REALM: "tackle"  # or "mta"
KEYCLOAK_CLIENT_ID: "tackle-ui"  # or "mta-ui"
KEYCLOAK_SERVER_URL: "http://tackle-keycloak-sso.konveyor-tackle.svc:8080"  # or rhbk_url
```

#### Scenario 2: Auth Disabled (`feature_auth_required: false`)

**Hub receives**:
```yaml
AUTH_REQUIRED: "false"
# No Keycloak variables
```

**UI receives**:
```yaml
AUTH_REQUIRED: "false"
# No Keycloak variables
```

#### Scenario 3: Auth Enabled with OAuth (`feature_auth_required: true`, `feature_auth_type: "oauth"`)

**Hub receives**:
```yaml
AUTH_REQUIRED: "false"  # Hub not OAuth-aware!
# No auth variables
```

**UI receives**:
```yaml
AUTH_REQUIRED: "false"  # OAuth handled by sidecar
# No env vars - OAuth proxy uses command-line args
```
Plus oauth-proxy sidecar container with command args

#### Scenario 4: Profile Differences (Keycloak URLs)

**Konveyor profile** (`app_profile: "konveyor"`):
- Hub: `KEYCLOAK_HOST: "http://tackle-keycloak-sso.konveyor-tackle.svc:8080"`
- UI: `KEYCLOAK_SERVER_URL: "http://tackle-keycloak-sso.konveyor-tackle.svc:8080"`

**MTA profile** (`app_profile: "mta"`):
- Hub: `KEYCLOAK_HOST: "https://tackle-rhbk-service.konveyor-tackle.svc:8443/auth"`
- UI: `KEYCLOAK_SERVER_URL: "https://tackle-rhbk-service.konveyor-tackle.svc:8443/auth"`

### Key Observations

1. **Hub vs UI Variable Names Differ**:
   - Hub uses `KEYCLOAK_HOST`
   - UI uses `KEYCLOAK_SERVER_URL`
   - Both contain the same value, just different variable names

2. **Hub-Only Variables**:
   - `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASS` - Hub manages Keycloak
   - `KEYCLOAK_REQ_PASS_UPDATE` - password policy
   - `KEYCLOAK_AUDIENCE` - JWT validation

3. **OAuth Limitations**:
   - OAuth mode is UI-only (sidecar proxy pattern)
   - Hub has NO OAuth support (sets `AUTH_REQUIRED: "false"` in OAuth mode)
   - OAuth uses command-line args, not environment variables

4. **Profile-Based URLs**:
   - Konveyor: Standard Keycloak service URL (HTTP port 8080)
   - MTA: RHBK service URL (HTTPS port 8443 with `/auth` path)

---

## 7. Auth-Related Networking & Service Configuration

### UI Service (service-ui.yml.j2)

**OAuth Mode Service Changes** (`feature_auth_type == "oauth"`):

1. **Service Annotation** (lines 3-5):
   ```yaml
   annotations:
     service.beta.openshift.io/serving-cert-secret-name: {{ ui_tls_secret_name }}
   ```
   - Also added when `ui_tls_enabled` is true on OpenShift
   - Triggers OpenShift service-ca to generate TLS certificates

2. **Service Port Mapping** (lines 11-14):
   ```yaml
   ports:
     - name: ui
       port: {{ oauth_ssl_port }}  # 8081
       targetPort: {{ oauth_ssl_port }}
   ```
   - **OAuth mode**: Exposes OAuth proxy SSL port (8081)
   - **Non-OAuth mode**: Exposes UI port (8080)

### UI Route (route-ui.yml.j2)

**OAuth Mode Route Changes** (`feature_auth_type == "oauth"` on lines 23-27):

```yaml
tls:
  termination: reencrypt  # Fixed for OAuth mode
  # vs
  termination: {{ ui_route_tls_termination }}  # Configurable otherwise (default: edge)
```

- **OAuth mode**: Forces `reencrypt` termination (OAuth proxy terminates SSL, re-encrypts to route)
- **Non-OAuth mode**: Configurable via `ui_route_tls_termination` (default: `edge`)

### UI Ingress (ingress-ui.yml.j2)

**Keycloak Mode Ingress Changes** (`feature_auth_type == "keycloak"`):

1. **Nginx SSL Redirect** (lines 12-14):
   ```yaml
   annotations:
     nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
   ```
   - Only when ingress class is `nginx`
   - Forces HTTPS for Keycloak authentication flow

2. **Keycloak Path Routing** (lines 26-32):
   ```yaml
   paths:
     - path: /auth
       pathType: Prefix
       backend:
         service:
           name: {{ keycloak_sso_service_name }}
           port:
             number: 8080
   ```
   - Routes `/auth` path prefix to Keycloak service
   - Allows UI to proxy Keycloak login through the same Ingress hostname

### UI ServiceAccount (serviceaccount-ui.yml.j2)

**OAuth Mode ServiceAccount Annotation** (lines 6-7):

```yaml
annotations:
  serviceaccounts.openshift.io/oauth-redirectreference.primary: >-
    {"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"{{ ui_route_name }}"}}
```

- **Condition**: Uses `oauth` annotation check (OpenShift OAuth integration)
- **Purpose**: Tells OpenShift OAuth server where to redirect after login
- **Enables**: UI ServiceAccount to act as OAuth client

### LLM Proxy ConfigMap (kai/llm-proxy-configmap.yaml.j2)

**Auth-Conditional Configuration** (`feature_auth_required` on lines 24-29):

```yaml
server:
  port: 8321
{% if feature_auth_required|bool %}
  auth:
    provider_config:
      type: "oauth2_token"
      verify_tls: false
{% endif %}
```

- **When enabled**: LLM proxy validates OAuth2 bearer tokens
- **TLS verification**: Disabled (same as Hub) for self-signed certificates
- **Note**: This auth block was partially removed in commit 6cf0d71 (llm-proxy routing refactor)

---

## 8. Other Auth-Related Dependencies

### Kai Database Image

**File**: `roles/tackle/defaults/main.yml:341`

```yaml
kai_database_image_fqin: "{{ keycloak_database_image_fqin }}"
```

- Kai's PostgreSQL database reuses the same image variable as Keycloak's database
- Both use PostgreSQL 15 (`RELATED_IMAGE_TACKLE_POSTGRES` environment variable)
- This is a shared infrastructure dependency, not a functional auth dependency

---

## 9. Current Limitations & Issues

### Deprecated Features

- `experimental_deploy_kai` → replaced by `kai_solution_server_enabled`

### Known Limitations

1. **OAuth Implementation Incomplete**
   - No hub-side OAuth token validation
   - Mainly for OpenShift OAuth proxy pattern

2. **Static Keycloak Configuration**
   - Realm, client, audience hardcoded
   - No way to pre-populate users

3. **TLS Handling**
   - Auto-enabled only on OpenShift
   - Kubernetes requires manual setup

4. **No OIDC Client Auto-Registration**
   - External integrations require manual Keycloak setup

### Keycloak Deprovisioning (When Auth is Disabled)

**Trigger**: When `feature_auth_required: false` OR `feature_auth_type != "keycloak"`  
**Task Location**: `roles/tackle/tasks/main.yml` lines 784-813

#### Resources That Are Deleted

1. **RHSSO Keycloak CR** (if exists):
   - API Version: `keycloak.org/v1alpha1`
   - Kind: `Keycloak`
   - Name: `{{ rhsso_service_name }}` (e.g., `tackle-rhsso`)
   - Condition: Only if RHSSO operator API exists in cluster

2. **Keycloak PostgreSQL Deployment**:
   - Kind: `Deployment`
   - Name: `{{ keycloak_database_deployment_name }}` (e.g., `tackle-keycloak-postgresql`)
   - Namespace: `{{ app_namespace }}`

3. **Keycloak SSO Deployment**:
   - Kind: `Deployment`  
   - Name: `{{ keycloak_sso_deployment_name }}` (e.g., `tackle-keycloak-sso`)
   - Namespace: `{{ app_namespace }}`

#### Resources That Are PRESERVED

1. **Secrets** (all preserved):
   - `{{ app_name }}-keycloak-sso` - admin credentials
   - `{{ app_name }}-keycloak-postgresql` - database credentials
   - `keycloak-db-secret` - RHBK database config (if exists)

2. **PersistentVolumeClaims** (all preserved):
   - `{{ app_name }}-keycloak-postgresql-15-volume-claim` - database data

3. **Services** (not explicitly deleted):
   - `{{ app_name }}-keycloak-sso`
   - `{{ app_name }}-keycloak-postgresql`

**Rationale**: Secrets and PVCs are preserved to prevent data loss. If a user temporarily disables auth and later re-enables it, the admin credentials and database data remain intact.

#### Behavior Summary When Auth is Disabled

1. **Deployments removed** - Keycloak pods deleted
2. **Hub/UI receive** `AUTH_REQUIRED: "false"`
3. **Data preserved** - Secrets and PVCs retained
4. **Single-user access mode** - No authentication required
5. **On re-enable** - Existing credentials/data reused

---

## 10. Summary: Key File Locations

| Aspect | File Path | Key Lines |
|--------|-----------|-----------|
| **Feature Flags** | `roles/tackle/defaults/main.yml` | 11-12 |
| **Keycloak Vars** | `roles/tackle/defaults/main.yml` | 86-137 |
| **Auth Tasks** | `roles/tackle/tasks/main.yml` | 104-413, 784-813 |
| **Hub Auth Env** | `roles/tackle/templates/deployment-hub.yml.j2` | 121-154 |
| **UI Auth Env** | `roles/tackle/templates/deployment-ui.yml.j2` | 38-118 |
| **Keycloak Deploy** | `roles/tackle/templates/deployment-keycloak-sso.yml.j2` | All |
| **RHBK CR** | `roles/tackle/templates/customresource-rhbk-keycloak.yml.j2` | All |
