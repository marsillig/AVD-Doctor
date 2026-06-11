# AVD Doctor

AVD Doctor is an Azure Virtual Desktop diagnostic collector designed to run in
Azure Cloud Shell.

## Download in Azure Cloud Shell

This repository is private, so the download requires a GitHub token with
read-only access to the repository contents.

```bash
read -rsp "GitHub token: " GITHUB_TOKEN && echo

curl -fsSL \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.raw+json" \
  "https://api.github.com/repos/marsillig/AVD-Doctor/contents/avd-doctor.sh" \
  -o avd-doctor.sh

unset GITHUB_TOKEN
chmod +x avd-doctor.sh
```

## Run

```bash
./avd-doctor.sh \
  --resource-group "<host-pool-resource-group>" \
  --host-pool "<host-pool-name>" \
  --upn "<test-user-upn>"
```

Use `--session-host "<fqdn-or-vm-name>"` to select a specific host and
`--subscription-id "<subscription-id>"` to override the active Azure CLI context.

To include guest-side checks on a selected session host:

```bash
./avd-doctor.sh \
  --resource-group "<host-pool-resource-group>" \
  --host-pool "<host-pool-name>" \
  --guest-diagnostics
```

## Permissions

- **Reader** on the AVD and monitoring resources.
- A custom role containing `Microsoft.Compute/virtualMachines/runCommand/action`
  when guest diagnostics are enabled.
- `AuditLog.Read.All` or an equivalent Entra directory role only when sign-in
  diagnostics are requested with `--upn`.

## Report

The JSON report is saved under `$HOME` with file permissions set to `600`.
Reports contain sensitive Azure environment metadata and should be handled
securely.
