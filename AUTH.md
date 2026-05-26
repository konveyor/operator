# Authentication Configuration

This document describes the authentication architecture and configuration variables for the Tackle/Konveyor operator.

## Overview

Starting with this release, the Hub acts as the primary OIDC (OpenID Connect) provider. The UI authenticates against Hub's built-in OIDC endpoints at `/oidc`. Hub supports three authentication modes:

1. **Pure Hub OIDC** - Users managed directly in Hub (default)
2. **Federated OIDC** - Delegate to external identity providers (Keycloak, RHSSO, RHBK)
3. **LDAP/Active Directory** - Direct authentication against LDAP servers

### Architecture

**Pure Hub OIDC (default for new installations):**
```
Browser → UI Route (/oidc proxy) → Hub OIDC → Hub API
```

**Hub OIDC with Federated Authentication:**
```
Browser → UI Route (/oidc proxy) → Hub OIDC → [Federated IDP] → Hub API
                                       ↓
                                   IdentityProvider CR
```

**Hub OIDC with LDAP Authentication:**
```
Browser → UI Route (/oidc proxy) → Hub OIDC → [LDAP Server] → Hub API
                                       ↓
                                   LdapProvider CR
```

### Key Components

- **Hub OIDC Provider**: Built-in OAuth 2.0 / OIDC server in Hub
  - Endpoints: `/oidc/authorize`, `/oidc/token`, `/oidc/.well-known/openid-configuration`
  - Enabled when `feature_auth_required: true`
  - Issuer URL: `https://<ui-route-host>/oidc` (external route, proxied to Hub service)

- **UI Route/Ingress Proxy**: Existing UI route includes `/oidc` path that proxies to Hub service `/oidc`
  - No separate Hub route needed
  - Browser accesses: `https://<ui-route-host>/oidc`
  - Proxies to: `http://<hub-service>:8080/oidc`

- **IdpClient CR**: Defines OIDC client applications that can authenticate with Hub
  - CRD: `tackle.konveyor.io/v1alpha1/IdpClient`
  - Automatically created for web-ui, kantra, and kai-ide
  - Can be extended for custom client applications

- **IdentityProvider CR**: Configures Hub to federate authentication to external identity providers
  - CRD: `tackle.konveyor.io/v1alpha1/IdentityProvider`
  - Hub reads these CRs from its namespace at startup/runtime
  - Used for Keycloak, RHSSO, RHBK, or any OIDC-compatible provider

- **LdapProvider CR**: Configures LDAP/Active Directory authentication
  - CRD: `tackle.konveyor.io/v1alpha1/LdapProvider`
  - Provides direct LDAP authentication and authorization
  - Supports role mappings from LDAP groups to application roles

---

## Environment Variables

### UI Container Environment Variables

| Variable | Description | Example Value | Set By |
|----------|-------------|---------------|--------|
| `AUTH_REQUIRED` | Enable/disable authentication | `"true"` or `"false"` | `feature_auth_required` |
| `OIDC_ISSUER` | Hub's OIDC issuer URL (external route) | `"https://tackle.apps.example.com/oidc"` | Runtime (from UI Route/Ingress hostname) |
| `OIDC_CLIENT_ID` | UI's OIDC client identifier | `"web-ui"` | `ui_oidc_client_id` |

**Notes:**
- `OIDC_ISSUER` uses the **external** route URL (same URL the browser uses)
- This ensures strict issuer matching - JWT tokens issued by Hub contain the same issuer URL that UI validates against
- Both browser and UI backend use the same public route URL

### Hub Container Environment Variables

| Variable | Description | Example Value | Set By |
|----------|-------------|---------------|--------|
| `AUTH_REQUIRED` | Enable/disable authentication | `"true"` or `"false"` | `feature_auth_required` |
| `OIDC_ISSUER` | Hub's own OIDC issuer URL (external route) | `"https://tackle.apps.example.com/oidc"` | Runtime (from UI Route/Ingress hostname) |
| `APIKEY_SECRET` | Secret key for signing API keys and JWT tokens | `"<random-32-chars>"` | Generated once, stored in Hub secret |

**Notes:**
- `OIDC_ISSUER` must match the UI's `OIDC_ISSUER` exactly for proper OIDC compliance
- `APIKEY_SECRET` is generated once and persisted in the Hub secret (same pattern as `ADDON_TOKEN`)

---

## Tackle CR Variables

### Authentication Control

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `feature_auth_required` | boolean | `false` (konveyor)<br>`true` (mta) | Enable/disable authentication globally |

### UI OIDC Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `ui_oidc_client_id` | string | `"web-ui"` | OIDC client identifier for the UI |

### Federated Identity Provider Configuration

Configure these variables to enable federated authentication to an external identity provider:

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `keycloak_sso_url` | string | `""` | External Keycloak server URL (e.g., `"https://keycloak.example.com"`) |
| `rhbk_url` | string | `""` | External RHBK server URL (e.g., `"https://rhbk.example.com"`) |
| `keycloak_sso_realm` | string | `"{{ app_name }}"` | Keycloak realm name |
| `keycloak_sso_client_id` | string | `"{{ app_name }}-ui"` | Client ID in the federated identity provider |

**Notes:**
- Set **either** `keycloak_sso_url` **or** `rhbk_url` to enable federated authentication
- If both are empty, pure Hub OIDC is used (no federation)
- The operator automatically detects existing operator-deployed Keycloak instances and constructs service URLs
- These variables are deprecated for deployment purposes but retained for federation configuration

### Runtime Variables (Set by Operator)

These variables are set at runtime by the operator and should not be configured in the Tackle CR:

| Variable | Description |
|----------|-------------|
| `hub_oidc_issuer` | Set from UI Route/Ingress hostname + `/oidc` |
| `federated_idp_issuer` | Constructed from detection or explicit config |
| `federated_idp_client_id` | Defaults to `keycloak_sso_client_id` |

---

## Configuration Scenarios

### Scenario 1: Pure Hub OIDC (No External Identity Provider)

**Default for fresh installations.**

```yaml
apiVersion: tackle.konveyor.io/v1alpha2
kind: Tackle
metadata:
  name: tackle
  namespace: konveyor-tackle
spec:
  feature_auth_required: true
```

**Result:**
- Hub OIDC provider enabled
- No IdentityProvider CR created
- Users authenticate directly against Hub
- User accounts managed in Hub

### Scenario 2: Federated Authentication to External Keycloak

**For users who manage their own Keycloak instance.**

```yaml
apiVersion: tackle.konveyor.io/v1alpha2
kind: Tackle
metadata:
  name: tackle
  namespace: konveyor-tackle
spec:
  feature_auth_required: true
  keycloak_sso_url: "https://keycloak.example.com"
  keycloak_sso_realm: "tackle"
  keycloak_sso_client_id: "tackle-ui"
```

**Result:**
- Hub OIDC provider enabled
- IdentityProvider CR created pointing to external Keycloak
- Hub federates authentication to Keycloak
- Users authenticate via Hub → Keycloak
- User accounts managed in Keycloak

**Requirements:**
1. Ensure the `tackle-ui` client exists in your Keycloak realm
2. Add redirect URI to the client: `https://<ui-route-host>/oidc/callback`
3. Client should use PKCE flow (public client, no secret required)

### Scenario 3: Existing Operator-Deployed Keycloak (Upgrade Path)

**For existing installations where the operator previously deployed Keycloak.**

The operator automatically detects existing operator-deployed Keycloak instances by checking for:
- Standalone Keycloak service (labels: `app.kubernetes.io/part-of={app_name}` AND `app.kubernetes.io/component=sso`)
- RHSSO Keycloak CR (label: `app={app_name}-rhsso`, MTA profile only)
- RHBK Keycloak CR (name: `{app_name}-keycloak`, MTA profile only)

**No Tackle CR changes needed.**

**Result:**
- Hub OIDC provider enabled
- IdentityProvider CR created automatically pointing to existing Keycloak service
- Hub federates authentication to existing Keycloak
- Existing users continue to work
- Keycloak instance is no longer managed by the operator (remains in place)

**Post-Upgrade Steps:**
1. Ensure the existing `tackle-ui` (or `{app_name}-ui`) client in Keycloak has the redirect URI: `https://<ui-route-host>/oidc/callback`

### Scenario 4: LDAP/Active Directory Authentication

**For organizations using corporate LDAP or Active Directory.**

```yaml
apiVersion: tackle.konveyor.io/v1alpha2
kind: Tackle
metadata:
  name: tackle
  namespace: konveyor-tackle
spec:
  feature_auth_required: true
```

Then create an LdapProvider CR (see "LdapProvider Custom Resource" section for full examples).

**Result:**
- Hub OIDC provider enabled
- Users authenticate with LDAP credentials
- Groups are synced from LDAP and mapped to application roles
- No external Keycloak needed

### Scenario 5: Authentication Disabled

**For development or air-gapped environments.**

```yaml
apiVersion: tackle.konveyor.io/v1alpha2
kind: Tackle
metadata:
  name: tackle
  namespace: konveyor-tackle
spec:
  feature_auth_required: false
```

**Result:**
- No authentication required
- All API requests allowed
- Not recommended for production

---

## IdentityProvider Custom Resource

The `IdentityProvider` CR configures Hub to federate authentication to an external OIDC-compatible identity provider.

### Example

```yaml
apiVersion: tackle.konveyor.io/v1alpha1
kind: IdentityProvider
metadata:
  name: tackle-federated-idp
  namespace: konveyor-tackle
spec:
  name: federated-idp
  issuer: "https://keycloak.example.com/realms/tackle"
  clientId: "tackle-ui"
  redirectURI: "https://tackle.apps.example.com/oidc/callback"
  scopes:
    - openid
    - profile
    - email
  tls:
    insecure: true
```

### Fields

- `name`: Identifier for this provider (used in Hub logs)
- `issuer`: OIDC issuer URL of the external identity provider
- `clientId`: Client ID in the external identity provider
- `redirectURI`: Callback URL where the external IDP redirects after authentication (Hub OIDC callback endpoint)
- `scopes`: OIDC scopes to request from the external IDP

**Notes:**
- Hub reads all `IdentityProvider` CRs in its namespace
- Multiple providers can be configured (Hub will use the first one found)
- Client secret is **not required** - Hub uses PKCE flow with the existing public client
- The operator creates this CR automatically based on federated IDP configuration
- `tls.insecure: true` allows Hub to connect to identity providers using self-signed certificates

---

## IdpClient Custom Resource

The `IdpClient` CR defines OIDC client applications that can authenticate with Hub's OIDC provider. The operator automatically creates client configurations for built-in applications.

### Pre-configured Clients

The operator automatically creates these clients when `feature_auth_required: true`:

1. **web-ui** (ID: 1)
   - Application type: web
   - Grants: JWT bearer, authorization code, refresh token
   - Used by the web UI

2. **kantra** (ID: 2)
   - Application type: native
   - Grants: device code, authorization code, refresh token
   - Used by the kantra CLI tool

3. **kai-ide** (ID: 3)
   - Application type: native
   - Grants: JWT bearer, authorization code, refresh token
   - Redirect URIs: `vscode://konveyor.konveyor-core/auth`, `http://127.0.0.1/callback`
   - Used by IDE extensions

### Example: Custom Client

```yaml
apiVersion: tackle.konveyor.io/v1alpha1
kind: IdpClient
metadata:
  name: my-custom-app
  namespace: konveyor-tackle
spec:
  id: 100  # Must be >= 1000 for custom clients (< 1000 reserved for seeded clients)
  clientId: "my-app"
  applicationType: native
  grants:
    - authorization_code
    - refresh_token
  redirectURIs:
    - "http://localhost:8080/callback"
  scopes:
    - openid
    - profile
    - email
  clientSecret:  # Optional - for confidential clients only
    name: my-app-secret
    namespace: konveyor-tackle
```

### Fields

- `id` (integer, required): Database ID for the client. IDs 1-999 are reserved for operator-seeded clients. Custom clients must use IDs >= 1000.
- `clientId` (string): OAuth client identifier (e.g., "my-app")
- `applicationType` (string): OAuth application type - "web" or "native"
- `grants` ([]string): OAuth grant types supported by this client
  - Common values: `authorization_code`, `refresh_token`, `urn:ietf:params:oauth:grant-type:jwt-bearer`, `urn:ietf:params:oauth:grant-type:device_code`
- `redirectURIs` ([]string): Valid redirect URIs for OAuth flows
- `scopes` ([]string): OAuth scopes requested by this client (e.g., `openid`, `profile`, `email`, `offline_access`)
- `clientSecret` (object, optional): Reference to a Kubernetes Secret containing the client secret
  - Only needed for confidential clients (typically server-side web applications)
  - Public clients (native apps, SPAs) should use PKCE instead

**Notes:**
- The operator creates IdpClient CRs automatically for built-in applications
- Custom clients can be created by users for additional integrations
- Public clients (native apps) don't require a client secret when using PKCE

---

## LdapProvider Custom Resource

The `LdapProvider` CR configures LDAP or Active Directory authentication and authorization. When configured, Hub authenticates users against the LDAP server and maps LDAP groups to application roles.

### Example: Standard LDAP

```yaml
apiVersion: tackle.konveyor.io/v1alpha1
kind: LdapProvider
metadata:
  name: tackle-ldap
  namespace: konveyor-tackle
spec:
  name: corporate-ldap
  url: "ldap://ldap.example.com:389"
  baseDN: "dc=example,dc=com"
  bindDN: "cn=service-account,dc=example,dc=com"
  password:
    name: ldap-bind-password
    namespace: konveyor-tackle
  userFilter: "(uid=%s)"
  groupFilter: "(memberUid=%s)"
  roleMappings:
    - any:
        - "cn=architects,ou=groups,dc=example,dc=com"
      roles:
        - architect
    - any:
        - "cn=admins,ou=groups,dc=example,dc=com"
      roles:
        - admin
  tls:
    insecure: false
    ca: |
      -----BEGIN CERTIFICATE-----
      ...
      -----END CERTIFICATE-----
```

### Example: Active Directory

```yaml
apiVersion: tackle.konveyor.io/v1alpha1
kind: LdapProvider
metadata:
  name: tackle-ad
  namespace: konveyor-tackle
spec:
  name: corporate-ad
  kind: ACTIVEDIRECTORY  # or "AD"
  url: "ldaps://ad.example.com:636"
  baseDN: "dc=corp,dc=example,dc=com"
  bindDN: "CN=Service Account,OU=ServiceAccounts,DC=corp,DC=example,DC=com"
  password:
    name: ad-bind-password
    namespace: konveyor-tackle
  hasMemberOf: true  # Use memberOf attribute for faster group lookups
  roleMappings:
    - any:
        - "CN=MTA-Architects,OU=Groups,DC=corp,DC=example,DC=com"
      roles:
        - architect
    - and:
        - "CN=MTA-Users,OU=Groups,DC=corp,DC=example,DC=com"
        - "CN=Engineering,OU=Groups,DC=corp,DC=example,DC=com"
      roles:
        - migrator
  tls:
    insecure: true  # For self-signed certificates (development only)
```

### Fields

- `name` (string): Provider identifier (used in Hub logs)
- `url` (string): LDAP server URL (e.g., `ldap://host:389` or `ldaps://host:636`)
- `baseDN` (string): Base DN for LDAP searches (e.g., `dc=example,dc=com`)
- `bindDN` (string): Service account bind DN for LDAP authentication
- `password` (object): Reference to a Kubernetes Secret containing the bind password
  - Secret must have a key with the password value
- `kind` (string, optional): LDAP kind - `ACTIVEDIRECTORY`, `AD`, or blank for standard LDAP
  - Affects default filters and search behavior
- `userFilter` (string, optional): Custom user search filter
  - Default for LDAP: `(uid=%s)`
  - Default for AD: `(sAMAccountName=%s)`
  - `%s` is replaced with the username
- `groupFilter` (string, optional): Custom group search filter
  - Default for LDAP: `(memberUid=%s)`
  - Default for AD: `(member=%s)`
  - `%s` is replaced with the user DN
- `hasMemberOf` (boolean, optional): Use `memberOf` attribute for group membership
  - Faster if available (common in Active Directory)
  - Falls back to group filter if false or not available
- `roleMappings` ([]object): Map LDAP groups to application roles
  - `any` ([]string): Match if user is in ANY of these groups (OR condition)
  - `and` ([]string): Match if user is in ALL of these groups (AND condition)
  - `roles` ([]string): Roles to assign when matched
- `tls` (object): TLS connection settings
  - `insecure` (boolean): Skip certificate verification (development only)
  - `ca` (string): PEM-encoded CA certificate for custom CAs

**Notes:**
- LDAP provider works alongside Hub's OIDC provider
- Users authenticate with their LDAP credentials
- Group memberships are synced and mapped to application roles
- Multiple role mappings can be configured with different group patterns
- Active Directory users should set `kind: ACTIVEDIRECTORY` and `hasMemberOf: true` for best performance

---

## Migration from Previous Versions

### For Existing Deployments with Operator-Deployed Keycloak

**Automatic upgrade - no action required.**

The operator will:
1. Detect your existing Keycloak deployment
2. Stop managing/updating the Keycloak deployment (leaves it in place)
3. Create an IdentityProvider CR pointing to your existing Keycloak service
4. Configure Hub as OIDC provider with federation to your Keycloak
5. Update UI to use Hub OIDC

**Post-upgrade:**
1. Verify the redirect URI in your Keycloak client includes: `https://<ui-route-host>/oidc/callback`
2. Test authentication with an existing user
3. (Optional) If you want to remove Keycloak:
   - Migrate users: export/import, configure LdapProvider CR (see "LdapProvider Custom Resource" section), or recreate in Hub
   - Delete the IdentityProvider CR
   - Delete the Keycloak deployment manually
   - System transitions to pure Hub OIDC or LDAP authentication

### For Existing Deployments with External Keycloak

If you were previously using an external Keycloak (not deployed by the operator), update your Tackle CR to set the federated IDP variables:

```yaml
spec:
  feature_auth_required: true
  keycloak_sso_url: "https://your-keycloak.example.com"
  keycloak_sso_realm: "your-realm"
  keycloak_sso_client_id: "your-client-id"
```

Then ensure your Keycloak client has the redirect URI: `https://<ui-route-host>/oidc/callback`

---

## Troubleshooting

### Authentication fails with "Invalid issuer"

**Cause:** The issuer in JWT tokens doesn't match the OIDC issuer URL.

**Solution:** Verify both Hub and UI have the same `OIDC_ISSUER` environment variable value, and it matches the external route URL.

```bash
kubectl get route tackle -n konveyor-tackle -o jsonpath='{.spec.host}'
# Should match: https://<route-host>/oidc

kubectl get deployment tackle-hub -n konveyor-tackle -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OIDC_ISSUER")].value}'
kubectl get deployment tackle-ui -n konveyor-tackle -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OIDC_ISSUER")].value}'
```

### Federated authentication not working

**Check IdentityProvider CR exists:**
```bash
kubectl get identityprovider -n konveyor-tackle
```

**Check Hub logs for federation errors:**
```bash
kubectl logs deployment/tackle-hub -n konveyor-tackle | grep -i oidc
```

**Verify redirect URI in external identity provider:**
- The client must have redirect URI: `https://<ui-route-host>/oidc/callback`
- The client should be configured as a public client (PKCE flow)

### OIDC discovery endpoint not found

**Test the OIDC discovery endpoint:**
```bash
curl https://<ui-route-host>/oidc/.well-known/openid-configuration
```

If this fails, check:
1. UI Route/Ingress exists and is accessible
2. Route includes path `/oidc` proxied to Hub service
3. Hub deployment is running and has `AUTH_REQUIRED=true`

---

## Security Considerations

1. **OIDC Issuer URL**: Must use HTTPS in production (external route URL)
2. **APIKEY_SECRET**: Generated once and stored securely in Kubernetes secret
3. **Client Secret**: Not required - Hub uses PKCE flow for federated authentication
4. **Token Validation**: Strict issuer matching ensures tokens from other sources are rejected
5. **External IDP**: Ensure your external identity provider (Keycloak/RHSSO/RHBK) is properly secured

---

## API Reference

### Hub OIDC Endpoints

All endpoints are relative to the UI route (proxied to Hub service):

| Endpoint | Description |
|----------|-------------|
| `GET /oidc/.well-known/openid-configuration` | OIDC discovery document |
| `GET /oidc/authorize` | OAuth 2.0 authorization endpoint |
| `POST /oidc/token` | OAuth 2.0 token endpoint |
| `GET /oidc/callback` | Callback endpoint for federated authentication |

### Custom Resource Definitions

#### IdentityProvider CRD

**API Group:** `tackle.konveyor.io/v1alpha1`

**Kind:** `IdentityProvider`

**Short Name:** `idp`

**Scope:** Namespaced

**Spec Fields:**
- `name` (string): Provider identifier
- `issuer` (string): OIDC issuer URL of the external identity provider
- `clientId` (string): Client ID in the external IDP
- `clientSecret` (object, optional): Reference to Kubernetes Secret containing client secret
- `redirectURI` (string): Callback URL where external IDP redirects after authentication
- `scopes` ([]string): OIDC scopes to request from the external IDP
- `tls` (object): TLS connection settings
  - `insecure` (boolean): Skip certificate verification (for self-signed certs)
  - `ca` (string): PEM-encoded CA certificate for custom CAs

#### IdpClient CRD

**API Group:** `tackle.konveyor.io/v1alpha1`

**Kind:** `IdpClient`

**Short Name:** `client`

**Scope:** Namespaced

**Spec Fields:**
- `id` (integer, required): Database ID (1-999 reserved, >= 1000 for custom clients)
- `clientId` (string): OAuth client identifier
- `applicationType` (string): OAuth application type ("web" or "native")
- `grants` ([]string): OAuth grant types supported by this client
- `redirectURIs` ([]string): Valid redirect URIs for OAuth flows
- `scopes` ([]string): OAuth scopes requested by this client
- `clientSecret` (object, optional): Reference to Kubernetes Secret containing client secret

#### LdapProvider CRD

**API Group:** `tackle.konveyor.io/v1alpha1`

**Kind:** `LdapProvider`

**Short Name:** `ldap`

**Scope:** Namespaced

**Spec Fields:**
- `name` (string): Provider identifier
- `url` (string): LDAP server URL
- `baseDN` (string): Base DN for LDAP searches
- `bindDN` (string): Service account bind DN
- `password` (object): Reference to Kubernetes Secret containing bind password
- `kind` (string, optional): LDAP kind ("ACTIVEDIRECTORY", "AD", or blank)
- `userFilter` (string, optional): Custom user search filter
- `groupFilter` (string, optional): Custom group search filter
- `hasMemberOf` (boolean, optional): Use memberOf attribute for group membership
- `roleMappings` ([]object): Map LDAP groups to application roles
  - `any` ([]string): Match if user is in ANY of these groups
  - `and` ([]string): Match if user is in ALL of these groups
  - `roles` ([]string): Roles to assign when matched
- `tls` (object): TLS connection settings
  - `insecure` (boolean): Skip certificate verification
  - `ca` (string): PEM-encoded CA certificate for custom CAs
