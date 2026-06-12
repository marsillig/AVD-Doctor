# AVD Doctor

AVD Doctor is a portable Azure Virtual Desktop diagnostic collector designed to
run in Azure Cloud Shell. It performs control-plane, monitoring, identity, and
optional session-host checks without applying remediation changes.

Identity checks also verify:

- Azure Virtual Desktop, Windows Cloud Login, and Microsoft Remote Desktop
  enterprise applications are enabled.
- Microsoft Entra authentication for RDP is enabled on Windows Cloud Login.
- Conditional Access app-ID inclusions, exclusions, effective policy coverage,
  and Azure Virtual Desktop/Windows Cloud Login targeting alignment.

## Requirements

- Azure Cloud Shell using Bash
- An authenticated Azure CLI session
- `jq`
- Azure and Microsoft Entra permissions for the selected checks

## Download in Azure Cloud Shell

```bash
curl -fsSLO https://raw.githubusercontent.com/marsillig/AVD-Doctor/v0.1.4/avd-doctor.sh
chmod +x avd-doctor.sh
```

Review scripts before executing them in a privileged environment.

Check the downloaded version:

```bash
./avd-doctor.sh --version
```

## Run

```bash
./avd-doctor.sh \
  --resource-group "<avd-management-resource-group>" \
  --host-pool "<host-pool-name>" \
  --upn "<test-user-upn>"
```

`--resource-group` must be the management resource group containing the Azure
Virtual Desktop **host pool resource**. It does not need to be the resource group
containing the session-host VMs. AVD Doctor resolves each session-host VM and its
resource group automatically from the host pool.

Use `--session-host "<fqdn-or-vm-name>"` to select a specific host and
`--subscription-id "<subscription-id>"` to override the active Azure CLI context.

To include guest-side checks on a selected session host:

```bash
./avd-doctor.sh \
  --resource-group "<avd-management-resource-group>" \
  --host-pool "<host-pool-name>" \
  --session-host "<session-host-name>" \
  --guest-diagnostics
```

View all options:

```bash
./avd-doctor.sh --help
```

## Permissions

- **Reader** on the AVD and monitoring resources.
- A custom role containing `Microsoft.Compute/virtualMachines/runCommand/action`
  when guest diagnostics are enabled. Scope it to the narrowest required VM or
  session-host resource group.
- `AuditLog.Read.All` or an equivalent Entra directory role only when sign-in
  diagnostics are requested with `--upn`.
- `Application.Read.All` and a supported Entra role to verify the Azure Virtual
  Desktop, Windows Cloud Login, and Microsoft Remote Desktop enterprise
  applications and the Windows Cloud Login RDP authentication configuration.
- `Policy.Read.All` and a supported Entra role, such as Security Reader or
  Global Reader, to verify Conditional Access app inclusions and exclusions.

## Reports

The script saves a JSON report and a readable TUI-style HTML report under
`$HOME`. Both files are created with permissions set to `600`.

Reports contain customer Azure environment identifiers and diagnostic details.
Keep them inside the customer tenant, handle them securely, and do not commit
them to source control.

## Support

Open a GitHub issue for bugs and feature requests. For security vulnerabilities,
follow [SECURITY.md](SECURITY.md).

## License

Licensed under the [MIT License](LICENSE).
