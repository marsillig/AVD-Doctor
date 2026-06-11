# AVD Doctor

`avd-doctor.sh` is a read-only Azure Virtual Desktop diagnostic collector designed
for Azure Cloud Shell. It audits the AVD control plane, Azure Monitor diagnostics,
user sign-ins, and one selected session host.

## Run

```bash
chmod +x avd-doctor.sh
./avd-doctor.sh \
  --resource-group "<host-pool-resource-group>" \
  --host-pool "<host-pool-name>" \
  --upn "<test-user-upn>"
```

Use `--session-host "<fqdn-or-vm-name>"` to select a specific host and
`--subscription-id "<subscription-id>"` to override the active Azure CLI context.
Guest-side checks are disabled by default because VM Run Command can execute
arbitrary code. Explicitly add `--guest-diagnostics` when they are required.

## Permissions

Start with least privilege:

- **Reader** on the AVD and monitoring resources.
- A custom role containing `Microsoft.Compute/virtualMachines/runCommand/action`
  only when guest diagnostics are required. Assign it temporarily at the
  narrowest VM or resource-group scope and remove it after the diagnostic run.
- `AuditLog.Read.All` or an equivalent Entra directory role only when sign-in
  diagnostics are required. Prefer a temporary, reviewed assignment.

The JSON report is written with mode `600` under `$HOME`. Sign-in IP addresses,
tokens, and secrets are not collected.

The report still contains sensitive client-environment metadata, including Azure
resource identifiers, host names, health information, and diagnostic events.
Never commit or publicly share a generated report. The included `.gitignore`
blocks the default report filename.

## Validate locally

```bash
bash -n avd-doctor.sh
shellcheck avd-doctor.sh
./avd-doctor.sh --help
```

## Before publishing

```bash
# Confirm no diagnostic output or local credentials are tracked.
jj status
git check-ignore -v avd-diagnostics-example.json .env credentials.json

# Review the author email that a public commit would expose.
jj log -r @ --no-graph -T 'author.email() ++ "\n"'
```

Push only an intentional bookmark with `jj git push`. Do not use `git push
--mirror`, because local Jujutsu and Codex bookkeeping refs aren't intended for
publication.

## Microsoft references

- [Send AVD diagnostic data to Log Analytics](https://learn.microsoft.com/azure/virtual-desktop/diagnostics-log-analytics)
- [Check access to required AVD FQDNs and endpoints](https://learn.microsoft.com/azure/virtual-desktop/check-access-validate-required-fqdn-endpoint)
- [Interpret AVD session-host statuses and health checks](https://learn.microsoft.com/azure/virtual-desktop/session-host-status-health-checks)
- [Microsoft Entra joined AVD session hosts](https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts)
