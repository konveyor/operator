# Tackle2-Operator OIDC Refactoring Requirements

**Date**: 2026-05-28  
**Branch**: oidc2  
**Purpose**: Define requirements for refactoring authentication to use external OIDC providers

---

## 1. Objectives

### What We Want to Achieve

**Primary Objective:**
Remove operator responsibility for deploying and managing identity providers (Keycloak/RHBK/RHSSO) because **Hub is now an OIDC Identity Provider**.

**Key Architectural Change:**
- **Hub IS the OIDC provider** - it issues JWT tokens for authentication
- Users authenticate to Hub (not to a separate Keycloak instance)
- Operator-deployed Keycloak is **redundant** - Hub provides OIDC functionality directly

**Why Remove Operator-Managed Keycloak:**
- Hub now provides OIDC, making separate Keycloak deployment unnecessary
- Reduces operator complexity and maintenance burden
- Eliminates PostgreSQL database management for Keycloak
- Removes upgrade/migration concerns (PostgreSQL v12→v15 type issues)
- Reduces resource footprint (no Keycloak pods/databases in tackle namespace)
- Users who still want Keycloak can deploy it themselves (outside operator management)

**Secondary Objectives:**

1. **Enable Enterprise Identity Provider Federation**
   - Hub can federate authentication to external IdPs (Okta, Azure AD, Keycloak, etc.)
   - Users configure Hub to delegate authentication to their organization's IdP
   - Hub still issues the tokens, but validates users against external IdP
   - Enables SSO integration with existing organizational auth systems

2. **Simplify Authentication Architecture**
   - Remove OAuth proxy sidecar pattern (no longer needed)
   - Remove Keycloak-specific Ingress/Route routing
   - Unified authentication flow: UI → Hub (OIDC provider) → [optional] External IdP

3. **Maintain User Choice**
   - Users can run Hub as standalone OIDC provider (no external IdP)
   - Users can configure Hub to federate to external IdP
   - Users can keep operator-deployed Keycloak if desired (but manage it themselves)

### Authentication Flow (Target Architecture)

**Standalone Mode** (no external IdP):
```
User → UI → Hub (OIDC provider) → Hub issues token → User authenticated
```

**Federated Mode - OIDC** (with IdentityProvider CR):
```
User → UI → Hub (OIDC provider) → External OIDC IdP (validates user) → Hub issues token → User authenticated
```

**Federated Mode - LDAP** (with LdapProvider CR):
```
User → UI → Hub (OIDC provider) → LDAP server (validates user) → Hub issues token → User authenticated
```

**Key Point:** Hub is always the OIDC provider. External IdP (OIDC or LDAP) is optional for user validation.

### What We Want to Add

- **Hub as OIDC provider** - this is a core capability that makes Keycloak redundant
- Hub's ability to federate to external IdPs
- Hub's ability to issue and validate JWT tokens
- UI's ability to authenticate users (via Hub's OIDC)

### What We Want to Remove

- Operator deployment/management of Keycloak/RHBK/RHSSO
- All Keycloak PostgreSQL database resources
- OAuth proxy sidecar in UI deployment
- PostgreSQL migration logic
- Keycloak deprovisioning logic
- Hub's role as Keycloak admin (no more KEYCLOAK_ADMIN_USER/PASS)
- LLM proxy's need to validate tokens

---

---

## 2. Architecture Clarifications

### Current State (from CURRENT.md)

**What operator deploys:**
- Keycloak (konveyor profile) or RHBK (mta profile)
- Keycloak PostgreSQL database
- Hub with Keycloak admin credentials
- UI with Keycloak client configuration

**Authentication flow:**
```
User → UI → Keycloak (OIDC provider) → Keycloak issues token → User authenticated
                                     ↓
                            Hub validates token (Keycloak admin)
```

**Problem:** Keycloak is redundant because Hub has OIDC provider capability built-in.

### Target State

**What operator deploys:**
- Hub (with OIDC provider enabled)
- UI configured to authenticate via Hub's OIDC
- **No Keycloak** (unless user deploys it themselves outside operator)

**Authentication flow (standalone):**
```
User → UI → Hub (OIDC provider) → Hub issues token → User authenticated
```

**Authentication flow (federated to external IdP):**
```
User → UI → Hub (OIDC provider) → External IdP validates user → Hub issues token → User authenticated
```

**Key Change:** Hub is the OIDC provider. External IdP is optional for user validation (federation).

### What Are IdpClient/IdentityProvider/LdapProvider CRs?

Based on the oidc branch work and federation concepts:

- **IdpClient CR**: Defines an OIDC client that can authenticate to Hub (e.g., UI, API clients, LLM proxy)
- **IdentityProvider CR**: Optional - defines an external OIDC IdP that Hub federates to (e.g., Okta, Azure AD, external Keycloak)
- **LdapProvider CR**: Optional - defines an LDAP server that Hub uses as authentication backend (federation to LDAP)

**Federation Options:**

Hub can run in three modes:

1. **Standalone** (no federation CRs):
   - Hub manages users directly (internal user database)
   - No IdentityProvider or LdapProvider CRs

2. **OIDC Federation** (IdentityProvider CR present):
   - Hub federates to external OIDC provider
   - Users authenticate via external IdP
   - Hub issues tokens after external IdP validates user

3. **LDAP Federation** (LdapProvider CR present):
   - Hub federates to LDAP server
   - Users authenticate via LDAP
   - Hub issues tokens after LDAP validates user

**Operator responsibility:**
- **Always**: Create IdpClient CR for UI (so UI can authenticate to Hub)
- **On fresh install**: User optionally creates IdentityProvider/LdapProvider CRs for federation
- **On upgrade from operator-deployed Keycloak**:
  - Operator MUST create IdentityProvider CR to federate Hub to existing Keycloak
  - IdentityProvider configuration derived from:
    - Variables defined/overridden in Tackle CR (for external Keycloak), OR
    - Auto-detected from existing operator-deployed Keycloak/RHSSO/RHBK in namespace
  - Ensures existing deployments continue working after upgrade (Hub federates to Keycloak)

### Existing User Deployments - Upgrade Path

**Users with operator-deployed Keycloak (most common case):**

When upgrading from previous operator version that deployed Keycloak:

1. **Operator detects existing Keycloak** (in namespace):
   - Deployment: `{{ app_name }}-keycloak-sso` (konveyor) or RHBK StatefulSet (mta)
   - Secret: `{{ app_name }}-keycloak-sso` with admin credentials

2. **Operator creates IdentityProvider CR**:
   - Configures Hub to federate to existing Keycloak
   - Uses Keycloak service URL, realm, client ID from existing deployment
   - Enables seamless transition: users continue authenticating via Keycloak
   - Hub becomes OIDC provider, Keycloak becomes federated IdP

3. **Operator stops managing Keycloak**:
   - Keycloak deployment remains running but is no longer reconciled
   - User takes full responsibility for Keycloak lifecycle
   - User can later remove Keycloak and switch to Hub standalone or different IdP

**Users with externally-configured Keycloak:**

When Tackle CR has variables pointing to external Keycloak (outside namespace):

1. **Operator reads Tackle CR configuration**:
   - Variables like `keycloak_host`, `keycloak_realm`, etc. (if defined)
   
2. **Operator creates IdentityProvider CR**:
   - Configures Hub to federate to external Keycloak
   - Uses values from Tackle CR

**Fresh installations:**
- No Keycloak deployed
- No IdentityProvider CR created by default
- Hub runs in standalone mode (internal user database)
- User optionally creates IdentityProvider/LdapProvider CR for federation

**Operator behavior on upgrade:**
- **Stops**: Deploying new Keycloak instances
- **Stops**: Managing existing Keycloak instances (no reconciliation of Keycloak resources)
- **Creates**: IdentityProvider CR if Keycloak detected (automatic federation setup)
- **Preserves**: Existing Keycloak resources (user cleanup when ready)
- **Provides**: Migration guide for switching away from Keycloak

---

## 3. Requirements

### 3.1 CRD Requirements

**REQ-1**: The operator SHALL ship the following Custom Resource Definitions:
- **IdpClient CRD**: Defines OIDC clients that can authenticate to Hub
- **IdentityProvider CRD**: Defines external OIDC IdPs that Hub federates to
- **LdapProvider CRD**: Defines LDAP servers that Hub federates to

### 3.2 Authentication Architecture

**REQ-1**: The operator SHALL NOT deploy or manage Keycloak, RHBK, or RHSSO instances.

**REQ-2**: The system SHALL support authentication via external OIDC providers.

**REQ-3**: Hub SHALL act as OIDC provider for UI and other clients (existing behavior to preserve).

**REQ-4**: Authentication mode SHALL preserve no-auth option:
- `feature_auth_required` flag SHALL be preserved (default: `false`)
- `AUTH_REQUIRED` environment variable SHALL be preserved in Hub and UI
- Purpose: Support development/testing environments without authentication
- When `false`: Hub runs without authentication requirements

**REQ-5**: The operator SHALL auto-create IdpClient CR:
- IdpClient CR for UI SHALL always be created by operator
- Name: `web-ui` (matches `OIDC_CLIENT_ID` in REQ-11)
- Purpose: UI can authenticate to Hub's OIDC provider
- IdentityProvider/LdapProvider CRs: Created by operator on upgrade (see upgrade section), or manually by user

### 2.2 Component Changes

**REQ-6**: OAuth proxy sidecar pattern SHALL be removed from UI deployment.

**REQ-7**: The following templates SHALL be removed:
- All Keycloak deployment/service/secret templates (see CURRENT.md §4)
- OAuth proxy configuration templates
- ~~Keycloak-specific Ingress/Route path routing~~ **KEEP** (see REQ-12)

**REQ-8**: The following tasks SHALL be removed:
- Keycloak PostgreSQL deployment (CURRENT.md §5, Phase 3)
- PostgreSQL v12→v15 migration (CURRENT.md §5, Phase 4)
- Keycloak SSO setup (CURRENT.md §5, Phase 5)
- RHBK setup (CURRENT.md §5, Phase 6)
- OAuth secret generation (CURRENT.md §5, Phase 2)
- Keycloak deprovisioning (CURRENT.md §5, Phase 10)

**REQ-8a**: Existing Keycloak resources SHALL be preserved on upgrade:
- **Keycloak admin password Secret**: `{{ app_name }}-keycloak-sso`
  - Contains: Admin username and password for Keycloak
  - Purpose: Users need credentials to access Keycloak admin console at `/auth`
- **Keycloak Service**: `{{ app_name }}-keycloak-sso` (konveyor) or `{{ app_name }}-rhbk-service` (mta)
  - Purpose: Required for `/auth` path routing in Ingress/Route (REQ-12)
  - Purpose: Required for IdentityProvider CR federation endpoint
- **Keycloak Deployment/StatefulSet**: Preserved but no longer reconciled
- **Keycloak PostgreSQL resources**: Preserved (PVC, Deployment, Service)
- Operator SHALL NOT delete any existing Keycloak resources
- User performs cleanup when ready to remove Keycloak

**REQ-8b**: Keycloak detection on upgrade SHALL use resource discovery:
- Detection method: Query namespace for Keycloak resources
- Konveyor profile: Check for Deployment `{{ app_name }}-keycloak-sso`
- MTA profile: Check for StatefulSet `keycloak` (RHBK-managed)
- Alternative: Use label selectors on resources (e.g., `app.kubernetes.io/component=sso`)
- Detection triggers: IdentityProvider CR creation, KEYCLOAK_SERVER_URL env var, `/auth` routing

**REQ-9**: Hub deployment SHALL remove Keycloak admin credentials environment variables:
- `KEYCLOAK_ADMIN_USER`
- `KEYCLOAK_ADMIN_PASS`
- `KEYCLOAK_REQ_PASS_UPDATE`

**REQ-10**: Hub deployment SHALL have the following OIDC environment variables:
- `OIDC_ISSUER`: Hub's OIDC issuer URL (ingress/route base URL + `/oidc`)
  - Example: `https://tackle-ui.apps.cluster.example.com/oidc`
  - Derived from: UI ingress hostname (Kubernetes) or route hostname (OpenShift)

**REQ-10a**: Hub deployment SHALL have API key secret environment variable:
- `APIKEY_SECRET`: Mounted from operator-generated secret
  - Purpose: Hub uses this for API key generation/validation
  - Similar to: Existing `ADDON_TOKEN` pattern
  - Secret name: `{{ hub_secret_name }}` (e.g., `tackle-hub`)
  - Secret generation: Auto-generated random value if secret doesn't exist
  - Secret persistence: Preserved across reconciliations (like hub AES passphrase)

**REQ-11**: UI deployment SHALL have the following OIDC environment variables:
- `OIDC_ISSUER`: Hub's OIDC issuer URL (same as Hub - ingress/route base URL + `/oidc`)
  - Example: `https://tackle-ui.apps.cluster.example.com/oidc`
  - Purpose: UI discovers Hub's OIDC endpoints (.well-known/openid-configuration)
- `OIDC_CLIENT_ID`: Must be `"web-ui"`
  - Purpose: UI identifies itself to Hub's OIDC provider
  - Value matches IdpClient CR name created by operator

**REQ-11a**: UI deployment SHALL have backward compatibility environment variable:
- `KEYCLOAK_SERVER_URL`: Service URL for operator-deployed Keycloak (when exists)
  - Example: `http://tackle-keycloak-sso.konveyor-tackle.svc:8080`
  - Condition: Only set when operator-deployed Keycloak detected in namespace
  - Purpose: UI can proxy `/auth` route to Keycloak service (see REQ-12)
  - Derived from: Existing Keycloak service discovery (konveyor: keycloak-sso, mta: rhbk-service)

**REQ-12**: UI Ingress/Route SHALL preserve `/auth` path routing to Keycloak when Keycloak exists in namespace.
- **Purpose**: Allow users to access Keycloak admin console through UI ingress/route
- **Use case**: Users managing Keycloak users/realms after upgrade
- **Condition**: Only when operator-deployed Keycloak deployment/StatefulSet exists
- **Behavior**: Ingress/Route proxies `/auth/*` → Keycloak service
- **Reference**: Current implementation in CURRENT.md §7 (ingress-ui.yml.j2 lines 26-32)

**REQ-13**: LLM Proxy authentication SHALL be handled via Hub routing:
- LLM Proxy will no longer validate tokens directly
- Authentication handled by routing through Hub (see `~/llm-proxy-routing.patch`)
- Details: To be clarified based on llm-proxy routing implementation

### 2.3 Variable Cleanup

**REQ-13**: The following variables SHALL be removed from `roles/tackle/defaults/main.yml`:
- All `keycloak_database_*` variables
- All `keycloak_sso_*` variables (except those needed for federation detection on upgrade)
- All `rhsso_*` variables (except those needed for federation detection on upgrade)
- All `rhbk_*` variables (except those needed for federation detection on upgrade)
- All `oauth_*` variables
- `cookie_secret_data`
- `keycloak_api_audience`
- **Retention criteria**: Keep only variables needed to detect/configure IdentityProvider CR on upgrade
- See CURRENT.md §3 for complete list of current auth variables

**REQ-14**: Feature flag cleanup:
- `feature_auth_required`: **KEEP** (default: `false`) - see REQ-4
- `feature_auth_type`: **REMOVE** (only OIDC mode exists, flag is obsolete)

**REQ-15**: The variable `kai_database_image_fqin` SHALL be updated to reference PostgreSQL image directly instead of `keycloak_database_image_fqin`.

### 2.4 Profile Differences

**REQ-16**: MTA vs Konveyor profile behavior:
- Both profiles support Hub as OIDC provider
- Both profiles support IdentityProvider/LdapProvider federation
- Profile differences preserved only for upgrade detection:
  - Konveyor: Detects `{{ app_name }}-keycloak-sso` Deployment
  - MTA: Detects `keycloak` StatefulSet (RHBK)
- No profile-specific authentication behavior differences in new code

### 2.5 Migration & Compatibility

**REQ-17**: [DECISION NEEDED] Existing deployments with operator-managed Keycloak:
- Option A: Operator stops managing Keycloak but preserves deployments (manual cleanup required)
- Option B: Operator actively removes Keycloak on upgrade
- Option C: Migration guide provided, operator behavior unchanged for existing CRs
- **Decision**: _[To be determined]_

**REQ-18**: [DECISION NEEDED] Secrets and data preservation:
- Preserve existing Keycloak secrets/PVCs?
- Provide migration tooling?
- **Decision**: _[To be determined]_

**REQ-19**: Documentation SHALL be provided for:
- Configuring external OIDC providers
- Migrating from operator-managed Keycloak
- Manual cleanup of legacy resources

---

## 3. Non-Requirements

### What We Are NOT Doing

**NON-REQ-1**: The operator will NOT support deploying or managing any identity provider (Keycloak, Dex, etc.).

**NON-REQ-2**: The operator will NOT support OAuth proxy sidecar pattern.

**NON-REQ-3**: The operator will NOT provide automatic migration tooling for Keycloak data.

**NON-REQ-4**: The operator will NOT support RHSSO or legacy Keycloak operator CRs.

**NON-REQ-5**: The operator will NOT maintain backward compatibility for removed feature flags (`feature_auth_type`).

---

## 4. Constraints

### Technical Constraints

**CONSTRAINT-1**: Hub must continue to function as OIDC provider for UI (existing architecture).

**CONSTRAINT-2**: Changes must work on both Kubernetes and OpenShift.

**CONSTRAINT-3**: Changes must work for both konveyor and mta profiles (unless profiles are unified).

### Compatibility Constraints

**CONSTRAINT-4**: [DECISION NEEDED] OLM upgrade path:
- Breaking change requiring new major version?
- Non-breaking with deprecation warnings?
- **Decision**: _[To be determined]_

**CONSTRAINT-5**: Existing Tackle CR instances must not fail reconciliation after operator upgrade.

---

## 5. Open Questions

These require decisions before planning can be finalized:

1. **Auth required flag**: Keep `feature_auth_required` or always require auth?

2. **No-auth mode**: Support no-auth mode for development, or auth always required?

3. **IdP/Client CRs**: Auto-create or user-managed?

4. **Environment variable naming**: Keep `KEYCLOAK_*` names or rename to generic `OIDC_*`?

5. **Profile unification**: Merge konveyor/mta auth behavior or keep separate?

6. **Migration strategy**: How do existing operator-managed Keycloak deployments transition?

7. **Breaking changes**: Is this a breaking change requiring major version bump?

8. **LLM proxy auth**: How does llm-proxy validate tokens from external OIDC? Does it need JWKS endpoint? Token introspection?

9. **Keycloak route/ingress**: When operator deployed Keycloak, UI Ingress routed `/auth` to Keycloak. Do we need similar routing for external OIDC providers, or does UI handle redirects?

10. **UI OIDC config**: How does UI discover OIDC endpoints? Environment variables? Discovery endpoint?

---

## 6. Success Criteria

The refactoring is successful when:

1. ✅ Operator no longer deploys or manages Keycloak/RHBK/RHSSO
2. ✅ Hub functions as OIDC provider for UI using external OIDC for user authentication
3. ✅ LLM proxy validates tokens from external OIDC provider
4. ✅ UI authenticates users via external OIDC provider
5. ✅ All removed code/templates/variables are cleanly eliminated
6. ✅ Documentation exists for external OIDC provider configuration
7. ✅ Migration guide exists for users with operator-managed Keycloak
8. ✅ Tests validate OIDC integration

---

## Next Steps

1. Review and answer open questions above
2. Get stakeholder approval on requirements
3. Create PLAN.md with implementation strategy
4. Begin implementation
