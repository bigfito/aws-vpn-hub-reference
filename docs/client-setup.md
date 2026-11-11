# Client setup

Home: [README](../README.md). Turn the AWS association on before a client can connect. `bash scripts/aws/vpn-hub.sh --enable` associates the subnet and creates the route `10.81.0.0/22` → `local`. The route is deleted on every disable, so enable does both steps.

Terraform writes one directory per device in `terraform/hub/out/<device>/` after `terraform apply` in `terraform/hub`. Copy the whole directory to the device. It contains a private key. Do not commit it, and do not send it through email or a shared drive you do not control.

| File | Who gets it |
|---|---|
| `vpn-hub-<device>.ovpn` | Every device. OpenVPN profile with the CA, the client certificate, and the client key. |
| `LEEME.md` | Every device. Short install notes generated for that device. |
| `install.sh` or `Install-VpnHub.ps1`, plus `vpn-hub-service*` | Linux and Windows. |
| `<device>.crt`, `<device>.key`, `aws-config`, DNS updater files | LAN hosts only (`dns_updater = true`). |

The service is installed **stopped**. Nothing dials AWS until you turn it on.

## 1. On demand

1. `bash scripts/aws/vpn-hub.sh --enable` (or the same two steps in the console: associate the subnet from `terraform output vpn_subnets`, then add route `10.81.0.0/22` target `local`).
2. On each LAN host you want to reach: `vpn-hub-service on` (Linux) or `& 'C:\Program Files\vpn-hub\vpn-hub-service.cmd' on` (Windows).
3. On the tablet, connect the profile in OpenVPN Connect.
4. When you are done: `off` on each host, disconnect the tablet, then `bash scripts/aws/vpn-hub.sh --disable`.

Leaving the association up is what costs about $0.10 per hour in the US East (Ohio) list price, plus $0.05 per hour for each connected client. Confirm your region on the [pricing page](https://aws.amazon.com/vpn/pricing/).

## 2. DNS updater tools

Install these before the host installer if that host should publish its name. The installer skips the updater and tells you what is missing.

- AWS CLI v2: [install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).
- `aws_signing_helper` from [IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html).
  - Linux: `/usr/local/bin/aws_signing_helper` (executable).
  - Windows: `C:\Program Files\vpn-hub\aws_signing_helper.exe`. Create that directory first if you install the helper before the script.
- Linux also needs `python3`, which Ubuntu already has.

The helper uses the client certificate. It does not use an access key.

## 3. Linux (`workstation-1`)

Tested shape: Ubuntu with systemd. From the copied bundle, as your own user (sudo, not a root shell):

```bash
cd ~/vpn-hub-workstation-1
sudo bash ./install.sh
```

`bash` matters: a copy from Windows can drop the executable bit.

The script installs `openvpn` and `openvpn-systemd-resolved`, copies the profile to `/etc/openvpn/client/vpn-hub.conf`, leaves `openvpn-client@vpn-hub` disabled, and installs `/usr/local/bin/vpn-hub-service`. The sudoers file `/etc/sudoers.d/vpn-hub` allows only `systemctl enable --now` and `systemctl disable --now` for that unit.

```bash
vpn-hub-service on
vpn-hub-service status
resolvectl query workstation-1.vpn.example.internal
vpn-hub-service off
```

SSH for other clients:

```bash
sudo apt install -y openssh-server
systemctl is-active ssh
```

This repository does not enable `ufw`. If you use a host firewall, allow TCP 22 from `10.81.0.0/22` and `10.80.0.0/16`. Allowing the whole LAN as well is a choice; do it only if other LAN machines must reach SSH without the VPN.

## 4. Windows (`workstation-2`)

Install [OpenVPN Community](https://openvpn.net/community-downloads/) 2.6 or newer, 64-bit. In the installer choose **Customize** and set **OpenVPN Service** to install on the local drive. The default install omits the service, and this stack needs it. Confirm with `Get-Service OpenVPNService`.

In an elevated PowerShell, from the copied bundle:

```powershell
cd C:\vpn-hub-workstation-2
powershell -ExecutionPolicy Bypass -File .\Install-VpnHub.ps1
```

The profile lands in `C:\Program Files\OpenVPN\config-auto\vpn-hub.ovpn`. The service stays stopped and Manual. `vpn-hub-service.cmd` is copied to `C:\Program Files\vpn-hub\`.

The script grants your user start, stop, and change-config rights on `OpenVPNService` so the on/off command does not need a second elevation. The service runs as `SYSTEM`. Change-config on that service is effectively administrator. The previous SDDL is saved under `C:\ProgramData\vpn-hub\` so you can restore it. Do not grant this to an account you do not already trust as an administrator of the PC.

```powershell
& 'C:\Program Files\vpn-hub\vpn-hub-service.cmd' on
& 'C:\Program Files\vpn-hub\vpn-hub-service.cmd' status
Resolve-DnsName workstation-2.vpn.example.internal
& 'C:\Program Files\vpn-hub\vpn-hub-service.cmd' off
```

Remote Desktop, if you want it:

1. Settings → System → Remote Desktop → On.
2. Optional, elevated PowerShell, to allow RDP from the VPN even when the adapter is on the Public profile:

```powershell
New-NetFirewallRule -DisplayName 'RDP desde vpn-hub' -Direction Inbound -Protocol TCP -LocalPort 3389 `
  -RemoteAddress 10.81.0.0/22,10.80.0.0/16 -Profile Any -Action Allow
```

If the LAN must not reach RDP, do not add a wider rule. The optional rule above is the tighter one.

## 5. Tablet (`tablet-1`)

1. Install **OpenVPN Connect** from the vendor's app store.
2. Copy `vpn-hub-tablet-1.ovpn` to the tablet (USB, or a cable import into the app). Do not leave a second copy in a cloud drive.
3. Import the profile and accept the VPN configuration prompt.
4. Connect when the association is up. Disconnect when you are done.
5. Delete the loose copy of the `.ovpn` from Files and from the USB stick. The app keeps the imported profile.

Reach the LAN hosts by the names in `LEEME.md`, for example `workstation-1.vpn.example.internal` (SSH) and `workstation-2.vpn.example.internal` (Remote Desktop). Short names work only where the client applies the `dhcp-option DOMAIN` search suffix.

| Symptom | Check |
|---|---|
| Does not connect | Association is on, and the tablet has internet. In the app log, look for `TLS` or `AUTH_FAILED`. |
| Connects, cannot reach hosts | The `10.81.0.0/22` → `local` route is missing. Run `--enable` again. |
| Connects, names do not resolve | The LAN host is connected and has had about two minutes to publish. Use the full name. |
| Name resolves, port does not answer | SSH is running on the Linux host, or Remote Desktop is on and allowed on the Windows network profile. |

## Remove a device

Do this while you can still reach the machine, and before `terraform destroy`.

Linux:

```bash
vpn-hub-service off
sudo systemctl disable --now vpn-hub-dns.timer vpn-hub-dns.service 2>/dev/null || true
sudo rm -f /etc/openvpn/client/vpn-hub.conf /etc/sudoers.d/vpn-hub \
  /usr/local/bin/vpn-hub-service /usr/local/sbin/vpn-hub-dns-update.sh \
  /etc/systemd/system/vpn-hub-dns.service /etc/systemd/system/vpn-hub-dns.timer
sudo rm -rf /etc/vpn-hub /var/lib/vpn-hub
sudo systemctl daemon-reload
```

Windows, elevated:

```powershell
& 'C:\Program Files\vpn-hub\vpn-hub-service.cmd' off
Unregister-ScheduledTask -TaskName vpn-hub-dns -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Force "$env:ProgramFiles\OpenVPN\config-auto\vpn-hub.ovpn" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:ProgramFiles\vpn-hub", "$env:ProgramData\vpn-hub" -ErrorAction SilentlyContinue
```

Restoring the original service SDDL is optional; the backup file is `C:\ProgramData\vpn-hub\OpenVPNService.sddl.bak` and is deleted with that folder. Copy it aside first if you still want it.

Tablet: delete the profile inside OpenVPN Connect, then delete any leftover `.ovpn`.

Revocation is separate. Deleting the profile on the device does not stop a copy of the certificate from connecting. See the revocation steps in [terraform/README.md](../terraform/README.md#revoke-a-device).
