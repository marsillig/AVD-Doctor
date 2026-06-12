#!/usr/bin/env bash
#
# AVD Doctor - read-only Azure Virtual Desktop diagnostic collector for Azure Cloud Shell.
#
# Required Azure permissions vary by enabled checks. At minimum, use Reader on the
# target resources. Guest diagnostics additionally require VM Run Command permission;
# Entra sign-in checks require AuditLog.Read.All or an equivalent directory role.

set -Eeuo pipefail
# Prevent inherited xtrace from logging UPNs or Azure resource identifiers and
# ensure reports and temporary files are private from the moment they are created.
set +x
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="0.1.4"
readonly API_VERSION="2024-04-03"
readonly GRAPH_URL="https://graph.microsoft.com/v1.0"
readonly LOOKBACK_HOURS=24
readonly AZURE_VIRTUAL_DESKTOP_APP_ID="9cdead84-a844-4324-93f2-b2e6bb768d07"
readonly WINDOWS_CLOUD_LOGIN_APP_ID="270efc09-cd0d-444b-a71f-39af4910ec45"
readonly MICROSOFT_REMOTE_DESKTOP_APP_ID="a4a365df-50f1-4397-bc59-1a1564b8bb9c"

SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
HOST_POOL=""
UPN=""
SESSION_HOST=""
GUEST_DIAGNOSTICS=false
NO_COLOR="${NO_COLOR:-}"

TMP_DIR=""
REPORT_FILE=""
HTML_REPORT_FILE=""
HOST_POOL_ID=""
RESOURCE_GROUP_ID=""
SELECTED_VM_ID=""
SELECTED_VM_NAME=""
SELECTED_VM_RG=""
WORKSPACE_RESOURCE_ID=""
WORKSPACE_CUSTOMER_ID=""

declare -a FINDINGS=()

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --resource-group <name> --host-pool <name> [options]

Required:
  -rg, --resource-group <name>    Resource group containing the AVD host pool
  -hp, --host-pool <name>        AVD host pool name

Optional:
  -s,  --subscription-id <id>    Subscription ID or name (defaults to active)
  -u,  --upn <user@domain>       Test user UPN for connection/sign-in tracing
  -sh, --session-host <name>     Session host FQDN or VM name
       --guest-diagnostics       Opt in to VM Run Command guest diagnostics
       --version                 Show version
  -h,  --help                    Show this help

Control-plane checks are read-only. The optional --guest-diagnostics flag uses
Azure VM Run Command to execute diagnostic PowerShell inside one session host.
No remediation or configuration changes are performed.
EOF
}

color() {
  local code="$1"
  if [[ -z "$NO_COLOR" && -t 1 ]]; then
    printf '\033[%sm' "$code"
  fi
}

reset_color() { color "0"; }

log() {
  local level="$1"
  shift
  local code="36"
  case "$level" in
    PASS) code="32" ;;
    WARN) code="33" ;;
    FAIL) code="31" ;;
    INFO) code="36" ;;
  esac
  color "$code"
  printf '[%s]' "$level"
  reset_color
  printf ' %s\n' "$*"
}

add_finding() {
  local phase="$1" status="$2" check="$3" message="$4"
  FINDINGS+=("$(jq -cn \
    --arg phase "$phase" \
    --arg status "$status" \
    --arg check "$check" \
    --arg message "$message" \
    '{phase:$phase,status:$status,check:$check,message:$message}')")
  log "$status" "$message"
}

die() {
  log FAIL "$*"
  exit 1
}

cleanup() {
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  return 0
}
trap cleanup EXIT

on_error() {
  local exit_code=$?
  log FAIL "Unexpected error at line ${BASH_LINENO[0]} (exit ${exit_code})."
  exit "$exit_code"
}
trap on_error ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

lowercase() {
  tr '[:upper:]' '[:lower:]' <<<"$1"
}

capture_az() {
  local output_file="$1"
  local error_file="$2"
  shift 2
  if az "$@" --only-show-errors --output json >"$output_file" 2>"$error_file"; then
    return 0
  fi
  return 1
}

safe_error() {
  local file="$1"
  # Avoid copying tokens, credentials, UPNs, GUIDs, or verbose client data into
  # terminal findings and reports.
  sed -E \
    -e 's/(Bearer|token|secret|password|sig|signature)[[:space:]]*[:=]?[[:space:]]*[^[:space:],;}]+/[REDACTED]/Ig' \
    -e 's/[[:alnum:]_+\/=-]{40,}/[REDACTED_VALUE]/g' \
    -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/[REDACTED_EMAIL]/g' \
    -e 's/[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}/[REDACTED_ID]/g' \
    -e 's/[[:space:]]+/ /g' \
    "$file" | cut -c1-500
}

parse_args() {
  while (($#)); do
    case "$1" in
      -s|--subscription-id)
        (($# >= 2)) || die "Missing value for $1"
        SUBSCRIPTION_ID="$2"
        shift 2
        ;;
      -rg|--resource-group)
        (($# >= 2)) || die "Missing value for $1"
        RESOURCE_GROUP="$2"
        shift 2
        ;;
      -hp|--host-pool)
        (($# >= 2)) || die "Missing value for $1"
        HOST_POOL="$2"
        shift 2
        ;;
      -u|--upn)
        (($# >= 2)) || die "Missing value for $1"
        UPN="$2"
        shift 2
        ;;
      -sh|--session-host)
        (($# >= 2)) || die "Missing value for $1"
        SESSION_HOST="$2"
        shift 2
        ;;
      --guest-diagnostics)
        GUEST_DIAGNOSTICS=true
        shift
        ;;
      --version)
        printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$RESOURCE_GROUP" ]] || die "--resource-group is required"
  [[ -n "$HOST_POOL" ]] || die "--host-pool is required"
}

initialize() {
  require_command az
  require_command jq

  TMP_DIR="$(mktemp -d)"
  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  REPORT_FILE="${HOME}/avd-diagnostics-${HOST_POOL//[^A-Za-z0-9_.-]/_}-${timestamp}.json"
  HTML_REPORT_FILE="${HOME}/avd-diagnostics-${HOST_POOL//[^A-Za-z0-9_.-]/_}-${timestamp}.html"

  if ! az account show --only-show-errors --output none 2>"$TMP_DIR/account.err"; then
    die "Azure CLI is not authenticated. Run 'az login' or use an authenticated Cloud Shell."
  fi

  if [[ -n "$SUBSCRIPTION_ID" ]]; then
    SUBSCRIPTION_ID="$(az account show \
      --subscription "$SUBSCRIPTION_ID" \
      --query id \
      --output tsv \
      --only-show-errors \
      2>"$TMP_DIR/subscription.err")" ||
      die "Unable to resolve subscription: $(safe_error "$TMP_DIR/subscription.err")"
  else
    SUBSCRIPTION_ID="$(az account show --query id --output tsv --only-show-errors)"
  fi

  RESOURCE_GROUP_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"

  add_finding "prerequisites" "PASS" "azure-auth" \
    "Authenticated to Azure and selected the requested subscription context."
}

control_plane_audit() {
  log INFO "Phase 1/4: Control-plane audit"

  HOST_POOL_ID="${RESOURCE_GROUP_ID}/providers/Microsoft.DesktopVirtualization/hostPools/${HOST_POOL}"
  if ! capture_az "$TMP_DIR/hostpool-raw.json" "$TMP_DIR/hostpool.err" \
    rest --method GET \
    --url "https://management.azure.com${HOST_POOL_ID}?api-version=${API_VERSION}"; then
    die "Host pool not found or inaccessible: $(safe_error "$TMP_DIR/hostpool.err")"
  fi

  jq '{id,name,location} + .properties' "$TMP_DIR/hostpool-raw.json" >"$TMP_DIR/hostpool.json"
  HOST_POOL_ID="$(jq -r '.id' "$TMP_DIR/hostpool.json")"
  add_finding "control-plane" "PASS" "host-pool" \
    "Resolved host pool ${HOST_POOL}."

  local rdp_properties
  rdp_properties="$(jq -r '.customRdpProperty // ""' "$TMP_DIR/hostpool.json")"
  if grep -Eqi '(^|;)enablerdsaadauth:i:1(;|$)' <<<"$rdp_properties"; then
    add_finding "control-plane" "PASS" "entra-rdp-auth" \
      "Host pool RDP properties enable Microsoft Entra authentication and single sign-on."
  elif grep -Eqi '(^|;)targetisaadjoined:i:1(;|$)' <<<"$rdp_properties"; then
    add_finding "control-plane" "WARN" "entra-rdp-auth" \
      "Host pool uses legacy targetisaadjoined:i:1; review migration to enablerdsaadauth:i:1."
  else
    add_finding "control-plane" "INFO" "entra-rdp-auth" \
      "Host pool RDP properties do not explicitly enable Microsoft Entra authentication; verify this matches the host-pool identity design."
  fi

  if capture_az "$TMP_DIR/sessionhosts-raw.json" "$TMP_DIR/sessionhosts.err" \
    rest --method GET \
    --url "https://management.azure.com${HOST_POOL_ID}/sessionHosts?api-version=${API_VERSION}"; then
    jq '[.value[]? | {id,name} + .properties]' \
      "$TMP_DIR/sessionhosts-raw.json" >"$TMP_DIR/sessionhosts.json"
    local host_count unhealthy_count
    host_count="$(jq 'length' "$TMP_DIR/sessionhosts.json")"
    unhealthy_count="$(jq '[.[] | select((.status // "") != "Available")] | length' "$TMP_DIR/sessionhosts.json")"
    if ((host_count == 0)); then
      add_finding "control-plane" "FAIL" "session-hosts" \
        "Host pool contains no session hosts."
    elif ((unhealthy_count > 0)); then
      add_finding "control-plane" "WARN" "session-hosts" \
        "${host_count} session host(s) found; ${unhealthy_count} are not Available."
    else
      add_finding "control-plane" "PASS" "session-hosts" \
        "${host_count} session host(s) found and all report Available."
    fi

    local failed_health_checks
    failed_health_checks="$(jq '[
      .[].sessionHostHealthCheckResults[]?
      | select((.healthCheckResult // "") != "HealthCheckSucceeded")
    ] | length' "$TMP_DIR/sessionhosts.json")"
    if ((failed_health_checks > 0)); then
      add_finding "control-plane" "WARN" "session-host-health-checks" \
        "Session hosts report ${failed_health_checks} non-successful health check(s)."
    else
      add_finding "control-plane" "PASS" "session-host-health-checks" \
        "No failed session-host health checks were returned."
    fi
  else
    printf '[]' >"$TMP_DIR/sessionhosts.json"
    add_finding "control-plane" "WARN" "session-hosts" \
      "Unable to list session hosts: $(safe_error "$TMP_DIR/sessionhosts.err")"
  fi

  audit_workspace_association
  select_session_host
  audit_rbac
}

audit_workspace_association() {
  if ! capture_az "$TMP_DIR/appgroups-raw.json" "$TMP_DIR/appgroups.err" \
    rest --method GET \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.DesktopVirtualization/applicationGroups?api-version=${API_VERSION}"; then
    printf '[]' >"$TMP_DIR/appgroups.json"
    add_finding "control-plane" "WARN" "workspace-association" \
      "Unable to list AVD application groups."
    return
  fi
  jq 'if type == "array" then . else (.value // []) end' \
    "$TMP_DIR/appgroups-raw.json" >"$TMP_DIR/appgroups.json"

  jq --arg hp "$(lowercase "$HOST_POOL_ID")" \
    '[.[] | select((.properties.hostPoolArmPath // "" | ascii_downcase) == $hp)]' \
    "$TMP_DIR/appgroups.json" >"$TMP_DIR/hostpool-appgroups.json"

  if capture_az "$TMP_DIR/workspaces-raw.json" "$TMP_DIR/workspaces.err" \
    rest --method GET \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.DesktopVirtualization/workspaces?api-version=${API_VERSION}"; then
    jq 'if type == "array" then . else (.value // []) end' \
      "$TMP_DIR/workspaces-raw.json" >"$TMP_DIR/workspaces.json"
  else
    printf '[]' >"$TMP_DIR/workspaces.json"
  fi

  local association_count
  association_count="$(jq -n \
    --slurpfile ag "$TMP_DIR/hostpool-appgroups.json" \
    --slurpfile ws "$TMP_DIR/workspaces.json" '
      [$ag[0][].id | ascii_downcase] as $ids
      | [$ws[0][] | select(
          [.properties.applicationGroupReferences[]? | ascii_downcase] as $refs
          | any($refs[]?; . as $r | $ids | index($r))
        )] | length
    ')"

  if ((association_count > 0)); then
    add_finding "control-plane" "PASS" "workspace-association" \
      "Host pool application group(s) are associated with ${association_count} workspace(s)."
  else
    add_finding "control-plane" "FAIL" "workspace-association" \
      "No workspace association was found for this host pool's application groups."
  fi
}

audit_rbac() {
  local rbac_scope="$RESOURCE_GROUP_ID"
  local scope_description="host pool resource group"
  if [[ -n "$SELECTED_VM_ID" ]]; then
    rbac_scope="$SELECTED_VM_ID"
    scope_description="selected session-host VM and inherited scopes"
  fi

  if ! capture_az "$TMP_DIR/roles.json" "$TMP_DIR/roles.err" \
    role assignment list \
    --subscription "$SUBSCRIPTION_ID" \
    --scope "$rbac_scope" \
    --include-inherited \
    --all; then
    printf '[]' >"$TMP_DIR/roles.json"
    add_finding "control-plane" "WARN" "vm-login-rbac" \
      "Unable to inspect VM login role assignments on the ${scope_description}."
    return
  fi

  local user_roles admin_roles
  user_roles="$(jq '[.[] | select(.roleDefinitionName == "Virtual Machine User Login")] | length' "$TMP_DIR/roles.json")"
  admin_roles="$(jq '[.[] | select(.roleDefinitionName == "Virtual Machine Administrator Login")] | length' "$TMP_DIR/roles.json")"

  if ((user_roles > 0)); then
    add_finding "control-plane" "PASS" "vm-user-login-rbac" \
      "Found ${user_roles} inherited Virtual Machine User Login assignment(s)."
  else
    add_finding "control-plane" "WARN" "vm-user-login-rbac" \
      "No Virtual Machine User Login assignment was found on the ${scope_description}."
  fi

  if ((admin_roles > 0)); then
    add_finding "control-plane" "PASS" "vm-admin-login-rbac" \
      "Found ${admin_roles} inherited Virtual Machine Administrator Login assignment(s)."
  else
    add_finding "control-plane" "INFO" "vm-admin-login-rbac" \
      "No inherited Virtual Machine Administrator Login assignment was found; this is normal if not required."
  fi
}

select_session_host() {
  local selected_host_json=""
  if [[ -n "$SESSION_HOST" ]]; then
    selected_host_json="$(jq -c --arg requested "$(lowercase "$SESSION_HOST")" '
      [.[] | select(
        ((.name // "" | split("/")[-1] | ascii_downcase) == $requested)
        or ((.name // "" | split("/")[-1] | split(".")[0] | ascii_downcase) == ($requested | split(".")[0]))
      )][0] // empty
    ' "$TMP_DIR/sessionhosts.json")"
  else
    selected_host_json="$(jq -c '
      ([.[] | select((.status // "") == "Available")][0] // .[0]) // empty
    ' "$TMP_DIR/sessionhosts.json")"
  fi

  if [[ -z "$selected_host_json" ]]; then
    add_finding "control-plane" "WARN" "session-host-selection" \
      "No session host could be selected for guest diagnostics."
    return
  fi

  local avd_host_name
  avd_host_name="$(jq -r '.name | split("/")[-1]' <<<"$selected_host_json")"
  SELECTED_VM_ID="$(jq -r '.resourceId // empty' <<<"$selected_host_json")"

  if [[ -z "$SELECTED_VM_ID" ]]; then
    local short_name
    short_name="${avd_host_name%%.*}"
    if capture_az "$TMP_DIR/vm-match.json" "$TMP_DIR/vm-match.err" \
      vm list --subscription "$SUBSCRIPTION_ID" \
      --query "[?tolower(name)=='$(lowercase "$short_name")'] | [0]"; then
      SELECTED_VM_ID="$(jq -r '.id // empty' "$TMP_DIR/vm-match.json")"
    fi
  fi

  if [[ -z "$SELECTED_VM_ID" ]]; then
    add_finding "control-plane" "WARN" "session-host-selection" \
      "Selected AVD host ${avd_host_name}, but its Azure VM resource could not be resolved."
    return
  fi

  SELECTED_VM_NAME="$(awk -F/ '{print $NF}' <<<"$SELECTED_VM_ID")"
  SELECTED_VM_RG="$(awk -F/ '{for (i=1;i<=NF;i++) if (tolower($i)=="resourcegroups") print $(i+1)}' <<<"$SELECTED_VM_ID")"
  add_finding "control-plane" "PASS" "session-host-selection" \
    "Selected session host VM ${SELECTED_VM_NAME} for optional guest diagnostics."
}

log_analytics_audit() {
  log INFO "Phase 2/4: Azure Monitor and Log Analytics"

  if ! capture_az "$TMP_DIR/diagnostic-settings.json" "$TMP_DIR/diagnostic-settings.err" \
    monitor diagnostic-settings list \
    --subscription "$SUBSCRIPTION_ID" \
    --resource "$HOST_POOL_ID"; then
    printf '[]' >"$TMP_DIR/diagnostic-settings.json"
    add_finding "monitoring" "WARN" "diagnostic-settings" \
      "Unable to inspect host pool diagnostic settings."
    return
  fi

  WORKSPACE_RESOURCE_ID="$(jq -r '
    (if type == "array" then . else (.value // []) end)
    | [.[]? | .workspaceId // empty][0] // empty
  ' "$TMP_DIR/diagnostic-settings.json")"

  if [[ -z "$WORKSPACE_RESOURCE_ID" ]]; then
    add_finding "monitoring" "WARN" "diagnostic-settings" \
      "No Log Analytics workspace is configured in the host pool diagnostic settings."
    return
  fi

  add_finding "monitoring" "PASS" "diagnostic-settings" \
    "A Log Analytics destination is configured for the host pool."

  if ! capture_az "$TMP_DIR/workspace.json" "$TMP_DIR/workspace.err" \
    monitor log-analytics workspace show --ids "$WORKSPACE_RESOURCE_ID"; then
    add_finding "monitoring" "WARN" "log-analytics-query" \
      "Unable to resolve the configured Log Analytics workspace."
    return
  fi
  WORKSPACE_CUSTOMER_ID="$(jq -r '.customerId // empty' "$TMP_DIR/workspace.json")"

  run_kql_query "connection-summary" '
WVDConnections
| where TimeGenerated > ago(24h)
| summarize Attempts=count(), Users=dcount(UserName), Hosts=dcount(SessionHostName) by State
| order by Attempts desc
'

  run_kql_query "error-summary" '
WVDErrors
| where TimeGenerated > ago(24h)
| summarize Count=count(), Users=dcount(UserName) by CodeSymbolic, ServiceError
| top 25 by Count desc
'

  if [[ -n "$UPN" ]]; then
    local escaped_upn="${UPN//\'/\'\'}"
    run_kql_query "user-connection-flow" "
WVDConnections
| where TimeGenerated > ago(24h)
| where UserName =~ '${escaped_upn}'
| project TimeGenerated, State, SessionHostName, CorrelationId
| order by TimeGenerated desc
| take 100
"
  fi
}

run_kql_query() {
  local name="$1" query="$2"
  if capture_az "$TMP_DIR/kql-${name}.json" "$TMP_DIR/kql-${name}.err" \
    monitor log-analytics query \
    --subscription "$SUBSCRIPTION_ID" \
    --workspace "$WORKSPACE_CUSTOMER_ID" \
    --timespan "P1D" \
    --analytics-query "$query"; then
    if jq -e . "$TMP_DIR/kql-${name}.json" >/dev/null 2>&1; then
      add_finding "monitoring" "PASS" "$name" \
        "Log Analytics query '${name}' completed."
    else
      printf '[]' >"$TMP_DIR/kql-${name}.json"
      add_finding "monitoring" "WARN" "$name" \
        "Log Analytics query '${name}' completed but returned non-JSON output; its results were omitted from the report."
    fi
  else
    printf '[]' >"$TMP_DIR/kql-${name}.json"
    add_finding "monitoring" "WARN" "$name" \
      "Log Analytics query '${name}' failed or its table is unavailable: $(safe_error "$TMP_DIR/kql-${name}.err")"
  fi
}

check_entra_application() {
  local name="$1" app_id="$2" check_rdp_protocol="$3"
  local slug="${name//[^A-Za-z0-9_.-]/_}"
  local sp_file="$TMP_DIR/entra-app-${slug}.json"
  local sp_error="$TMP_DIR/entra-app-${slug}.err"
  local rdp_enabled="null"

  if ! capture_az "$sp_file" "$sp_error" \
    rest --method GET \
    --url "${GRAPH_URL}/servicePrincipals(appId='${app_id}')?\$select=id,appId,displayName,accountEnabled"; then
    add_finding "identity" "WARN" "entra-app-${slug}" \
      "Unable to inspect the ${name} enterprise application; Application.Read.All or an equivalent role may be required."
    jq -n \
      --arg name "$name" \
      --arg appId "$app_id" \
      '{name:$name,appId:$appId,queryStatus:"unavailable"}' \
      >"$TMP_DIR/entra-app-result-${slug}.json"
    return
  fi

  local account_enabled sp_id
  account_enabled="$(jq -r '.accountEnabled // false' "$sp_file")"
  sp_id="$(jq -r '.id // empty' "$sp_file")"
  if [[ "$account_enabled" == "true" ]]; then
    add_finding "identity" "PASS" "entra-app-${slug}" \
      "${name} enterprise application is enabled."
  else
    add_finding "identity" "FAIL" "entra-app-${slug}" \
      "${name} enterprise application is disabled."
  fi

  if [[ "$check_rdp_protocol" == "true" && -n "$sp_id" ]]; then
    if capture_az "$TMP_DIR/entra-rdp-${slug}.json" "$TMP_DIR/entra-rdp-${slug}.err" \
      rest --method GET \
      --url "${GRAPH_URL}/servicePrincipals/${sp_id}/remoteDesktopSecurityConfiguration"; then
      rdp_enabled="$(jq -r '.isRemoteDesktopProtocolEnabled // false' "$TMP_DIR/entra-rdp-${slug}.json")"
      if [[ "$rdp_enabled" == "true" ]]; then
        add_finding "identity" "PASS" "entra-rdp-${slug}" \
          "Microsoft Entra authentication for RDP is enabled on ${name}."
      else
        add_finding "identity" "FAIL" "entra-rdp-${slug}" \
          "Microsoft Entra authentication for RDP is not enabled on ${name}."
      fi
    else
      add_finding "identity" "WARN" "entra-rdp-${slug}" \
        "Unable to inspect Microsoft Entra authentication for RDP on ${name}; Application.Read.All and a supported Entra role may be required."
    fi
  fi

  jq \
    --arg name "$name" \
    --arg appId "$app_id" \
    --argjson remoteDesktopProtocolEnabled "$rdp_enabled" \
    '{
      name: $name,
      appId: $appId,
      servicePrincipalId: .id,
      displayName,
      accountEnabled,
      remoteDesktopProtocolEnabled: $remoteDesktopProtocolEnabled,
      queryStatus: "completed"
    }' "$sp_file" >"$TMP_DIR/entra-app-result-${slug}.json"
}

entra_application_audit() {
  log INFO "Phase 3/4: Entra application and Conditional Access audit"

  check_entra_application "Azure Virtual Desktop" "$AZURE_VIRTUAL_DESKTOP_APP_ID" false
  check_entra_application "Windows Cloud Login" "$WINDOWS_CLOUD_LOGIN_APP_ID" true
  check_entra_application "Microsoft Remote Desktop" "$MICROSOFT_REMOTE_DESKTOP_APP_ID" false

  jq -s '.' "$TMP_DIR"/entra-app-result-*.json >"$TMP_DIR/entra-applications.json"

  if ! capture_az "$TMP_DIR/conditional-access-raw.json" "$TMP_DIR/conditional-access.err" \
    rest --method GET \
    --url "${GRAPH_URL}/identity/conditionalAccess/policies?\$select=id,displayName,state,conditions,grantControls,sessionControls"; then
    printf '{"queryStatus":"unavailable","policies":[],"applications":[],"applicationFilterPolicies":[]}' \
      >"$TMP_DIR/conditional-access.json"
    add_finding "identity" "WARN" "conditional-access-app-targeting" \
      "Unable to inspect Conditional Access app inclusions and exclusions; Policy.Read.All and a supported Entra role may be required."
    return
  fi

  jq \
    --arg avd "$AZURE_VIRTUAL_DESKTOP_APP_ID" \
    --arg wcl "$WINDOWS_CLOUD_LOGIN_APP_ID" \
    --arg msrd "$MICROSOFT_REMOTE_DESKTOP_APP_ID" '
    def policies:
      [.value[]? | {
        id,
        displayName,
        state,
        includeApplications: (.conditions.applications.includeApplications // []),
        excludeApplications: (.conditions.applications.excludeApplications // []),
        applicationFilter: (.conditions.applications.applicationFilter // null),
        hasSignInFrequency: (.sessionControls.signInFrequency.isEnabled // false),
        grantControls: (.grantControls.builtInControls // [])
      }];
    def targets($policies; $id):
      [$policies[] |
        select(.state != "disabled") |
        select(((.includeApplications | index("All")) != null or (.includeApplications | index($id)) != null)
          and (.excludeApplications | index($id)) == null) |
        {id,displayName,state,hasSignInFrequency,grantControls}
      ];
    def excludes($policies; $id):
      [$policies[] |
        select(.state != "disabled") |
        select((.excludeApplications | index($id)) != null) |
        {id,displayName,state}
      ];
    policies as $policies |
    {
      queryStatus: "completed",
      policies: $policies,
      applications: [
        {name:"Azure Virtual Desktop",appId:$avd,effectivePolicies:targets($policies;$avd),explicitExclusions:excludes($policies;$avd)},
        {name:"Windows Cloud Login",appId:$wcl,effectivePolicies:targets($policies;$wcl),explicitExclusions:excludes($policies;$wcl)},
        {name:"Microsoft Remote Desktop",appId:$msrd,effectivePolicies:targets($policies;$msrd),explicitExclusions:excludes($policies;$msrd)}
      ],
      applicationFilterPolicies: [$policies[] | select(.state != "disabled" and .applicationFilter != null) | {id,displayName,state,applicationFilter}]
    }' "$TMP_DIR/conditional-access-raw.json" >"$TMP_DIR/conditional-access.json"
  rm -f "$TMP_DIR/conditional-access-raw.json"

  local policy_count avd_enabled wcl_enabled msrd_enabled avd_excluded wcl_excluded filter_count alignment_gaps
  policy_count="$(jq '.policies | length' "$TMP_DIR/conditional-access.json")"
  avd_enabled="$(jq '[.applications[] | select(.appId == "'"$AZURE_VIRTUAL_DESKTOP_APP_ID"'") | .effectivePolicies[] | select(.state == "enabled")] | length' "$TMP_DIR/conditional-access.json")"
  wcl_enabled="$(jq '[.applications[] | select(.appId == "'"$WINDOWS_CLOUD_LOGIN_APP_ID"'") | .effectivePolicies[] | select(.state == "enabled")] | length' "$TMP_DIR/conditional-access.json")"
  msrd_enabled="$(jq '[.applications[] | select(.appId == "'"$MICROSOFT_REMOTE_DESKTOP_APP_ID"'") | .effectivePolicies[] | select(.state == "enabled")] | length' "$TMP_DIR/conditional-access.json")"
  avd_excluded="$(jq '[.applications[] | select(.appId == "'"$AZURE_VIRTUAL_DESKTOP_APP_ID"'") | .explicitExclusions[]] | length' "$TMP_DIR/conditional-access.json")"
  wcl_excluded="$(jq '[.applications[] | select(.appId == "'"$WINDOWS_CLOUD_LOGIN_APP_ID"'") | .explicitExclusions[]] | length' "$TMP_DIR/conditional-access.json")"
  filter_count="$(jq '.applicationFilterPolicies | length' "$TMP_DIR/conditional-access.json")"
  alignment_gaps="$(jq \
    --arg avd "$AZURE_VIRTUAL_DESKTOP_APP_ID" \
    --arg wcl "$WINDOWS_CLOUD_LOGIN_APP_ID" '
    ([.applications[] | select(.appId == $avd) | .effectivePolicies[] | select(.state == "enabled")] // []) as $avdPolicies |
    ([.applications[] | select(.appId == $wcl) | .effectivePolicies[] | select(.state == "enabled")] // []) as $wclPolicies |
    (
      [$avdPolicies[] | select(.id as $id | [$wclPolicies[].id] | index($id) == null)] +
      [$wclPolicies[] | select(.id as $id | [$avdPolicies[].id] | index($id) == null) | select(.hasSignInFrequency != true)]
    ) | unique_by(.id) | length
    ' "$TMP_DIR/conditional-access.json")"

  add_finding "identity" "INFO" "conditional-access-app-targeting" \
    "Reviewed ${policy_count} Conditional Access policies. Enabled policies targeting Azure Virtual Desktop: ${avd_enabled}; Windows Cloud Login: ${wcl_enabled}; Microsoft Remote Desktop: ${msrd_enabled}. Explicit exclusions for Azure Virtual Desktop: ${avd_excluded}; Windows Cloud Login: ${wcl_excluded}."

  if ((avd_enabled == 0)); then
    add_finding "identity" "WARN" "conditional-access-avd-coverage" \
      "No enabled Conditional Access policy targets Azure Virtual Desktop."
  else
    add_finding "identity" "PASS" "conditional-access-avd-coverage" \
      "At least one enabled Conditional Access policy targets Azure Virtual Desktop."
  fi

  if ((wcl_enabled == 0)); then
    add_finding "identity" "WARN" "conditional-access-wcl-coverage" \
      "No enabled Conditional Access policy targets Windows Cloud Login; review SSO authentication policy coverage."
  else
    add_finding "identity" "PASS" "conditional-access-wcl-coverage" \
      "At least one enabled Conditional Access policy targets Windows Cloud Login."
  fi

  if ((alignment_gaps > 0)); then
    add_finding "identity" "WARN" "conditional-access-avd-wcl-alignment" \
      "${alignment_gaps} enabled Conditional Access policy or policies target Azure Virtual Desktop and Windows Cloud Login inconsistently; Windows Cloud Login-only sign-in-frequency policies were excluded from this comparison."
  else
    add_finding "identity" "PASS" "conditional-access-avd-wcl-alignment" \
      "Enabled Conditional Access app targeting is aligned between Azure Virtual Desktop and Windows Cloud Login, excluding Windows Cloud Login-only sign-in-frequency policies."
  fi

  if ((filter_count > 0)); then
    add_finding "identity" "WARN" "conditional-access-app-filters" \
      "${filter_count} active Conditional Access policy or policies use application filters; their dynamic app targeting requires manual review."
  fi
}

entra_signin_audit() {
  if [[ -z "$UPN" ]]; then
    add_finding "identity" "INFO" "entra-signins" \
      "UPN not supplied; skipped user-specific Entra sign-in audit."
    printf '[]' >"$TMP_DIR/entra-signins.json"
    return
  fi

  local since filter encoded_filter url
  since="$(date -u -v-"${LOOKBACK_HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)"
  filter="userPrincipalName eq '${UPN//\'/\'\'}' and createdDateTime ge ${since}"
  encoded_filter="$(jq -rn --arg value "$filter" '$value | @uri')"
  url="${GRAPH_URL}/auditLogs/signIns?\$filter=${encoded_filter}&\$top=100&\$select=createdDateTime,appId,appDisplayName,resourceDisplayName,status,conditionalAccessStatus,isInteractive"

  if capture_az "$TMP_DIR/entra-signins-raw.json" "$TMP_DIR/entra-signins.err" \
    rest --method GET --url "$url"; then
    jq '[
      .value[]? | {
        createdDateTime,
        appId,
        appDisplayName,
        resourceDisplayName,
        conditionalAccessStatus,
        isInteractive,
        status: {
          errorCode: (.status.errorCode // 0),
          failureReason: (.status.failureReason // null),
          additionalDetails: (.status.additionalDetails // null)
        }
      }
    ]' "$TMP_DIR/entra-signins-raw.json" >"$TMP_DIR/entra-signins.json"
    rm -f "$TMP_DIR/entra-signins-raw.json"

    local signin_count failure_count ca_failures
    signin_count="$(jq 'length' "$TMP_DIR/entra-signins.json")"
    failure_count="$(jq '[.[] | select((.status.errorCode // 0) != 0)] | length' "$TMP_DIR/entra-signins.json")"
    ca_failures="$(jq '[.[] | select(.conditionalAccessStatus == "failure")] | length' "$TMP_DIR/entra-signins.json")"
    if ((signin_count == 0)); then
      add_finding "identity" "WARN" "entra-signins" \
        "No Entra sign-ins were returned for the supplied UPN in the last ${LOOKBACK_HOURS} hours."
    elif ((failure_count > 0 || ca_failures > 0)); then
      add_finding "identity" "WARN" "entra-signins" \
        "Found ${signin_count} sign-in(s), including ${failure_count} failure(s) and ${ca_failures} Conditional Access failure(s)."
    else
      add_finding "identity" "PASS" "entra-signins" \
        "Found ${signin_count} sign-in(s) with no returned failures."
    fi
  else
    printf '[]' >"$TMP_DIR/entra-signins.json"
    add_finding "identity" "WARN" "entra-signins" \
      "Unable to query Entra sign-in logs; AuditLog.Read.All or an equivalent role may be required."
  fi
}

guest_diagnostics() {
  log INFO "Phase 4/4: Session host guest diagnostics"
  if [[ "$GUEST_DIAGNOSTICS" != true ]]; then
    add_finding "guest" "INFO" "run-command" \
      "Guest diagnostics were not requested; skipped VM Run Command."
    printf '{}' >"$TMP_DIR/run-command.json"
    return
  fi

  if [[ -z "$SELECTED_VM_ID" ]]; then
    add_finding "guest" "WARN" "run-command" \
      "Skipped guest diagnostics because no session host VM was resolved."
    printf '{}' >"$TMP_DIR/run-command.json"
    return
  fi

  local guest_script
  guest_script="$(cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$result = [ordered]@{
    ComputerName = $env:COMPUTERNAME
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    Checks = @()
}

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Message, [object]$Data = $null)
    $result.Checks += [ordered]@{ Name = $Name; Status = $Status; Message = $Message; Data = $Data }
}

try {
    $services = Get-Service -Name RDAgentBootLoader, frxsvc, frxccd -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType
    $rdAgent = $services | Where-Object Name -eq 'RDAgentBootLoader'
    Add-Check 'AVD agent service' $(if ($rdAgent.Status -eq 'Running') {'PASS'} else {'FAIL'}) "RDAgentBootLoader status: $($rdAgent.Status)" $services
} catch { Add-Check 'AVD agent service' 'WARN' $_.Exception.Message }

try {
    $agentUrlTool = Get-ChildItem 'C:\Program Files\Microsoft RDInfra' -Filter 'WVDAgentUrlTool.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($agentUrlTool) {
        $urlToolOutput = & $agentUrlTool.FullName 2>&1 | Out-String
        $urlToolExitCode = $LASTEXITCODE
        Add-Check 'AVD required endpoints' $(if ($urlToolExitCode -eq 0) {'PASS'} else {'FAIL'}) "WVDAgentUrlTool exited with code $urlToolExitCode." ([ordered]@{ ToolFound = $true; ExitCode = $urlToolExitCode })
    } else {
        $endpoints = @('rdbroker.wvd.microsoft.com', 'mrsglobalsteptomwsprod.blob.core.windows.net')
        $tests = foreach ($endpoint in $endpoints) {
            $test = Test-NetConnection -ComputerName $endpoint -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
            [ordered]@{ Port = 443; Reachable = [bool]$test }
        }
        $failed = @($tests | Where-Object Reachable -eq $false).Count
        Add-Check 'AVD required endpoints' $(if ($failed -eq 0) {'WARN'} else {'FAIL'}) "WVDAgentUrlTool was not found; fallback endpoint tests failed: $failed of $($tests.Count)." ([ordered]@{ ToolFound = $false; Tests = $tests })
    }
} catch { Add-Check 'AVD required endpoints' 'WARN' $_.Exception.Message }

try {
    $profileKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
    $profile = if (Test-Path $profileKey) { Get-ItemProperty $profileKey } else { $null }
    $locations = @($profile.VHDLocations) + @($profile.CCDLocations) | Where-Object { $_ }
    $targets = foreach ($location in $locations) {
        if ($location -match '^\\\\([^\\]+)\\') {
            [ordered]@{
                Smb445Reachable = [bool](Test-NetConnection -ComputerName $Matches[1] -Port 445 -InformationLevel Quiet -WarningAction SilentlyContinue)
            }
        }
    }
    $fslogixServices = Get-Service -Name frxsvc, frxccd -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType
    $enabled = $profile -and $profile.Enabled -eq 1
    $unreachable = @($targets | Where-Object Smb445Reachable -eq $false).Count
    Add-Check 'FSLogix configuration' $(if ($enabled -and $unreachable -eq 0) {'PASS'} elseif ($profile) {'WARN'} else {'INFO'}) "Enabled=$enabled; configured locations=$($locations.Count); unreachable SMB targets=$unreachable." ([ordered]@{ Enabled = $enabled; Locations = $targets; Services = $fslogixServices })
} catch { Add-Check 'FSLogix configuration' 'WARN' $_.Exception.Message }

try {
    $logRoot = 'C:\ProgramData\FSLogix\Logs\Profiles'
    $matches = if (Test-Path $logRoot) {
        Get-ChildItem $logRoot -Filter '*.log' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 3 |
            ForEach-Object { Select-String -Path $_.FullName -Pattern 'error|warn|failed|denied' | Select-Object -Last 10 }
    }
    Add-Check 'FSLogix recent logs' $(if (@($matches).Count -gt 0) {'WARN'} else {'PASS'}) "Found $(@($matches).Count) recent error/warning line(s)." ([ordered]@{ MatchCount = @($matches).Count })
} catch { Add-Check 'FSLogix recent logs' 'WARN' $_.Exception.Message }

try {
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freePercent = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 2)
    Add-Check 'System disk free space' $(if ($freePercent -gt 10) {'PASS'} else {'FAIL'}) "C: has $freePercent% free space." ([ordered]@{ FreePercent = $freePercent })
} catch { Add-Check 'System disk free space' 'WARN' $_.Exception.Message }

try {
    $license = Get-CimInstance SoftwareLicensingProduct |
        Where-Object { $_.PartialProductKey -and $_.Name -like 'Windows*' } |
        Select-Object -First 1 Name, LicenseStatus, Description
    Add-Check 'Windows activation' $(if ($license.LicenseStatus -eq 1) {'PASS'} else {'FAIL'}) "Windows LicenseStatus=$($license.LicenseStatus)." $license
} catch { Add-Check 'Windows activation' 'WARN' $_.Exception.Message }

try {
    $headers = @{ Metadata = 'true' }
    $imdsResponse = Invoke-WebRequest -UseBasicParsing -Headers $headers -Method Get -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01'
    $imds = $imdsResponse.Content | ConvertFrom-Json
    $localUtc = (Get-Date).ToUniversalTime()
    $azureUtc = [datetime]::Parse($imdsResponse.Headers.Date).ToUniversalTime()
    $skewSeconds = [math]::Abs(($localUtc - $azureUtc).TotalSeconds)
    $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $timeSource = (w32tm /query /source 2>$null | Out-String).Trim()
    $timeStatus = (w32tm /query /status 2>$null | Out-String).Trim()
    Add-Check 'Clock synchronization' $(if ($skewSeconds -le 300) {'PASS'} else {'FAIL'}) "Clock skew versus the Azure IMDS HTTP date is $([math]::Round($skewSeconds, 1)) seconds." ([ordered]@{ TimeSourceConfigured = [bool]$timeSource; LastBootUtc = $bootTime.ToString('o'); SkewSeconds = $skewSeconds; W32TimeStatusAvailable = [bool]$timeStatus })
} catch { Add-Check 'Clock synchronization' 'WARN' $_.Exception.Message }

$json = $result | ConvertTo-Json -Depth 8 -Compress
Write-Output "AVD_DOCTOR_JSON=$json"
POWERSHELL
)"

  if capture_az "$TMP_DIR/run-command.json" "$TMP_DIR/run-command.err" \
    vm run-command invoke \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$SELECTED_VM_RG" \
    --name "$SELECTED_VM_NAME" \
    --command-id RunPowerShellScript \
    --scripts "$guest_script"; then
    local guest_json
    guest_json="$(jq -r '
      [.value[]?.message // empty]
      | join("\n")
      | split("AVD_DOCTOR_JSON=")[1] // empty
      | split("\n")[0]
    ' "$TMP_DIR/run-command.json")"
    if jq -e . >/dev/null 2>&1 <<<"$guest_json"; then
      jq . <<<"$guest_json" >"$TMP_DIR/guest-diagnostics.json"
      add_finding "guest" "PASS" "run-command" \
        "Guest diagnostics completed on ${SELECTED_VM_NAME}."
    else
      printf '{}' >"$TMP_DIR/guest-diagnostics.json"
      add_finding "guest" "WARN" "run-command" \
        "Run Command completed, but its structured diagnostic output could not be parsed."
    fi
  else
    printf '{}' >"$TMP_DIR/run-command.json"
    printf '{}' >"$TMP_DIR/guest-diagnostics.json"
    add_finding "guest" "WARN" "run-command" \
      "Unable to run guest diagnostics: $(safe_error "$TMP_DIR/run-command.err")"
  fi
}

write_report() {
  local findings_file="$TMP_DIR/findings.jsonl"
  printf '%s\n' "${FINDINGS[@]}" >"$findings_file"

  local sanitized_hosts="$TMP_DIR/sessionhosts-sanitized.json"
  jq '[.[] | {
    name: (.name | split("/")[-1]),
    status,
    allowNewSession,
    agentVersion,
    lastHeartBeat,
    updateState,
    sessions,
    healthCheckResults: [.sessionHostHealthCheckResults[]? | {
      healthCheckName,
      healthCheckResult,
      additionalFailureDetails
    }]
  }]' "$TMP_DIR/sessionhosts.json" >"$sanitized_hosts"

  jq -n \
    --arg version "$VERSION" \
    --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg subscriptionId "$SUBSCRIPTION_ID" \
    --arg resourceGroup "$RESOURCE_GROUP" \
    --arg hostPool "$HOST_POOL" \
    --arg selectedVm "$SELECTED_VM_NAME" \
    --arg workspaceId "$WORKSPACE_RESOURCE_ID" \
    --slurpfile findings "$findings_file" \
    --slurpfile hostPoolData "$TMP_DIR/hostpool.json" \
    --slurpfile sessionHosts "$sanitized_hosts" \
    --slurpfile connectionSummary "${TMP_DIR}/kql-connection-summary.json" \
    --slurpfile errorSummary "${TMP_DIR}/kql-error-summary.json" \
    --slurpfile userFlow "${TMP_DIR}/kql-user-connection-flow.json" \
    --slurpfile signIns "$TMP_DIR/entra-signins.json" \
    --slurpfile enterpriseApplications "$TMP_DIR/entra-applications.json" \
    --slurpfile conditionalAccess "$TMP_DIR/conditional-access.json" \
    --slurpfile guest "$TMP_DIR/guest-diagnostics.json" '
      {
        schemaVersion: "1.0",
        toolVersion: $version,
        generatedAtUtc: $generatedAt,
        scope: {
          subscriptionId: $subscriptionId,
          resourceGroup: $resourceGroup,
          hostPool: $hostPool,
          selectedVm: (if ($selectedVm | length) > 0 then $selectedVm else null end),
          logAnalyticsWorkspaceResourceId: (if ($workspaceId | length) > 0 then $workspaceId else null end)
        },
        findings: $findings,
        controlPlane: {
          hostPool: ($hostPoolData[0] | {
            name, location, hostPoolType, loadBalancerType, maxSessionLimit,
            preferredAppGroupType, startVMOnConnect, validationEnvironment,
            rdpPropertyChecks: {
              targetIsAadJoined: ((.customRdpProperty // "") | test("(^|;)targetisaadjoined:i:1(;|$)"; "i")),
              enableRdsAadAuth: ((.customRdpProperty // "") | test("(^|;)enablerdsaadauth:i:1(;|$)"; "i"))
            }
          }),
          sessionHosts: $sessionHosts[0]
        },
        monitoring: {
          connectionSummary: ($connectionSummary[0] // []),
          errorSummary: ($errorSummary[0] // []),
          userConnectionFlow: ($userFlow[0] // [])
        },
        identity: {
          signIns: ($signIns[0] // []),
          enterpriseApplications: ($enterpriseApplications[0] // []),
          conditionalAccess: ($conditionalAccess[0] // {})
        },
        guest: ($guest[0] // {})
      }
    ' >"$REPORT_FILE"

  chmod 600 "$REPORT_FILE"
  jq -e 'type == "object"' "$REPORT_FILE" >/dev/null
  log PASS "Diagnostic JSON report written to ${REPORT_FILE}"
}

write_html_report() {
  jq -r '
    def h: tostring | @html;
    def status_class:
      if . == "PASS" then "pass"
      elif . == "WARN" then "warn"
      elif . == "FAIL" then "fail"
      else "info"
      end;
    def finding_lines:
      .findings
      | map("<div class=\"line\"><span class=\"code \(.status | status_class)\">[\(.status | h)]</span><span>\(.message | h)</span></div>")
      | join("\n");
    def health_lines:
      .controlPlane.sessionHosts
      | map(
          . as $host
          | ($host.healthCheckResults // [])
          | map(
              "<div class=\"line\"><span class=\"code \((if .healthCheckResult == "HealthCheckSucceeded" then "pass" else "warn" end))\">[\((if .healthCheckResult == "HealthCheckSucceeded" then "PASS" else "WARN" end))]</span><span>\($host.name | h) / \(.healthCheckName | h): \(.healthCheckResult | h)\((if (.additionalFailureDetails.message // "") != "" then " — " + (.additionalFailureDetails.message | h) else "" end))</span></div>"
            )
          | join("\n")
        )
      | join("\n");
    def monitoring_lines:
      (.monitoring.errorSummary // [])
      | if length == 0 then
          "<div class=\"line\"><span class=\"code pass\">[PASS]</span><span>No aggregated service errors returned.</span></div>"
        else
          map("<div class=\"line\"><span class=\"code warn\">[WARN]</span><span>\((.CodeSymbolic // "Unknown") | h): \((.Count // "0") | h) event(s), \((.Users // "0") | h) user(s), service_error=\((.ServiceError // "unknown") | h)</span></div>")
          | join("\n")
        end;
    def enterprise_application_lines:
      (.identity.enterpriseApplications // [])
      | if length == 0 then
          "<div class=\"line\"><span class=\"code info\">[INFO]</span><span>Enterprise application verification was not available.</span></div>"
        else
          map(
            "<div class=\"line\"><span class=\"code \((if .accountEnabled == true then "pass" elif .accountEnabled == false then "fail" else "warn" end))\">[\((if .accountEnabled == true then "PASS" elif .accountEnabled == false then "FAIL" else "WARN" end))]</span><span>\(.name | h) (\(.appId | h)): account_enabled=\((.accountEnabled // "unknown") | h), rdp_protocol_enabled=\((.remoteDesktopProtocolEnabled // "not checked") | h)</span></div>"
          )
          | join("\n")
        end;
    def conditional_access_lines:
      (.identity.conditionalAccess.applications // [])
      | if length == 0 then
          "<div class=\"line\"><span class=\"code info\">[INFO]</span><span>Conditional Access app targeting verification was not available.</span></div>"
        else
          map(
            "<div class=\"line\"><span class=\"code info\">[INFO]</span><span>\(.name | h): effective_policies=\(.effectivePolicies | length), explicit_exclusions=\(.explicitExclusions | length)</span></div>"
          )
          | join("\n")
        end;
    def count_status($status): [.findings[] | select(.status == $status)] | length;
    def first_host: (.controlPlane.sessionHosts[0] // {});
    "<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>AVD Doctor — \(.scope.hostPool | h)</title>
  <style>
    :root{color-scheme:dark;--bg:#0b0f14;--surface:#10161d;--line:#2a3440;--text:#d9e2ec;--muted:#8492a2;--green:#56d364;--amber:#e3b341;--red:#f47067;--blue:#58a6ff}
    *{box-sizing:border-box}body{margin:0;color:var(--text);background:var(--bg);font:14px/1.6 ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,\"Liberation Mono\",monospace}
    .shell{width:min(1080px,calc(100% - 32px));margin:24px auto 48px;border:1px solid var(--line);background:var(--surface)}
    header{display:flex;justify-content:space-between;gap:20px;padding:12px 16px;border-bottom:1px solid var(--line);color:var(--muted)}header strong{color:var(--text)}
    main{padding:18px 20px 24px}.command{margin:0 0 20px;color:var(--text)}.prompt,.pass{color:var(--green)}.flag,.info,h2{color:var(--blue)}.warn,.state{color:var(--amber)}.fail{color:var(--red)}
    h1,h2,p{margin-top:0}h1{margin-bottom:7px;font-size:20px}h2{margin-bottom:13px;font-size:14px;text-transform:uppercase}.muted{color:var(--muted)}
    section{margin-top:24px;border-top:1px solid var(--line);padding-top:18px}.summary{display:grid;grid-template-columns:180px 1fr;gap:5px 16px;margin-top:18px}.summary dt{color:var(--muted)}.summary dd{margin:0;overflow-wrap:anywhere}
    .data{display:grid;grid-template-columns:repeat(4,1fr);border:1px solid var(--line)}.datum{padding:11px 13px;border-right:1px solid var(--line)}.datum:last-child{border-right:0}.datum b{display:block;font-size:17px}.datum span{color:var(--muted);font-size:12px}
    .line{display:grid;grid-template-columns:76px 1fr;gap:13px;padding:6px 0}.code{font-weight:700}.notice{padding:12px 14px;border-left:3px solid var(--amber);background:#171710}
    footer{padding:13px 16px;border-top:1px solid var(--line);color:var(--muted);font-size:12px}
    @media(max-width:700px){.shell{width:calc(100% - 16px);margin-top:8px}header{display:block}header span{display:block;margin-top:3px}main{padding:15px 13px 20px}.summary{grid-template-columns:125px 1fr}.data{grid-template-columns:repeat(2,1fr)}.datum:nth-child(2){border-right:0}.datum:nth-child(-n+2){border-bottom:1px solid var(--line)}.line{grid-template-columns:68px 1fr}}
  </style>
</head>
<body>
  <div class=\"shell\">
    <header><strong>AVD Doctor / diagnostic-report</strong><span>tenant-local report · contains customer data</span></header>
    <main>
      <p class=\"command\"><span class=\"prompt\">$</span> avd-doctor report <span class=\"flag\">--format html</span></p>
      <h1>AVD diagnostic report: \(.scope.hostPool | h)</h1>
      <p class=\"muted\">Read-only assessment generated by AVD Doctor \(.toolVersion | h).</p>
      <dl class=\"summary\">
        <dt>generated_utc</dt><dd>\(.generatedAtUtc | h)</dd>
        <dt>subscription_id</dt><dd>\(.scope.subscriptionId | h)</dd>
        <dt>resource_group</dt><dd>\(.scope.resourceGroup | h)</dd>
        <dt>host_pool</dt><dd>\(.scope.hostPool | h)</dd>
        <dt>selected_vm</dt><dd>\((.scope.selectedVm // "not selected") | h)</dd>
        <dt>location</dt><dd>\(.controlPlane.hostPool.location | h)</dd>
        <dt>host_pool_type</dt><dd>\(.controlPlane.hostPool.hostPoolType | h)</dd>
        <dt>load_balancer</dt><dd>\(.controlPlane.hostPool.loadBalancerType | h)</dd>
        <dt>workspace_resource_id</dt><dd>\((.scope.logAnalyticsWorkspaceResourceId // "not resolved") | h)</dd>
      </dl>
      <section><h2>Check summary</h2><div class=\"data\">
        <div class=\"datum\"><b class=\"pass\">\(count_status("PASS")) PASS</b><span>checks succeeded</span></div>
        <div class=\"datum\"><b class=\"warn\">\(count_status("WARN")) WARN</b><span>review required</span></div>
        <div class=\"datum\"><b class=\"fail\">\(count_status("FAIL")) FAIL</b><span>critical findings</span></div>
        <div class=\"datum\"><b class=\"info\">\(count_status("INFO")) INFO</b><span>informational</span></div>
      </div></section>
      <section><h2>Findings</h2>\(finding_lines)</section>
      <section><h2>Enterprise applications</h2>\(enterprise_application_lines)</section>
      <section><h2>Conditional Access app targeting</h2>\(conditional_access_lines)</section>
      <section><h2>Session-host health checks</h2>\(health_lines)</section>
      <section><h2>Aggregated monitoring evidence</h2>\(monitoring_lines)</section>
      <section><h2>Handling notice</h2><div class=\"notice\">This report contains customer environment identifiers and diagnostic details. Keep it inside the customer tenant and do not commit it to source control.</div></section>
    </main>
    <footer>[CUSTOMER DATA] Generated locally from the JSON diagnostic report. No information was uploaded by AVD Doctor.</footer>
  </div>
</body>
</html>"
  ' "$REPORT_FILE" >"$HTML_REPORT_FILE"

  chmod 600 "$HTML_REPORT_FILE"
  log PASS "Diagnostic HTML report written to ${HTML_REPORT_FILE}"
}

main() {
  parse_args "$@"
  initialize

  # Ensure optional report fragments always exist.
  printf '[]' >"$TMP_DIR/kql-connection-summary.json"
  printf '[]' >"$TMP_DIR/kql-error-summary.json"
  printf '[]' >"$TMP_DIR/kql-user-connection-flow.json"
  printf '[]' >"$TMP_DIR/entra-signins.json"
  printf '[]' >"$TMP_DIR/entra-applications.json"
  printf '{"queryStatus":"not-run","policies":[],"applications":[],"applicationFilterPolicies":[]}' >"$TMP_DIR/conditional-access.json"
  printf '{}' >"$TMP_DIR/guest-diagnostics.json"

  control_plane_audit
  log_analytics_audit
  entra_application_audit
  entra_signin_audit
  guest_diagnostics
  write_report
  write_html_report
}

main "$@"
