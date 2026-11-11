# Terraform

Home: [../README.md](../README.md). Two stacks. Apply bootstrap first. Destroy the hub first.

| Path | Role |
|---|---|
| `bootstrap/` | Remote state: S3 plus a customer-managed KMS key. Local state. Writes `hub/backend.hcl`. |
| `hub/` | VPC, Client VPN, certificates, private DNS, Roles Anywhere, optional budget. Remote state. |
| `hub/templates/` | OpenVPN profile and the per-device `LEEME.md`. |
| `hub/tests/`, `bootstrap/tests/` | `terraform test` with mocked providers. Account ids `111111111111` and `999999999999` are fake. |

`backend.hcl`, `terraform.tfvars`, and `hub/out/` are gitignored. Copy each `terraform.tfvars.example` to `terraform.tfvars` and set `expected_account_id` to the member account (`<aws-account-id>`). The example file uses `000000000000` so the validation (exactly 12 digits) has a placeholder. Do not commit the copy that has the real id.

## Apply

```bash
export AWS_PROFILE=vpn-hub   # or whatever you named the member-account profile

terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply

terraform -chdir=terraform/hub init -backend-config=backend.hcl
terraform -chdir=terraform/hub apply
terraform -chdir=terraform/hub apply   # second apply: disconnect_on_session_timeout
```

The second apply matters on AWS provider 6.71.0, which is the version in `.terraform.lock.hcl`. On create, the provider does not send `disconnect_on_session_timeout = false`, so AWS leaves the default `true`. The next plan shows the drift and the second apply clears it.

`terraform output -raw ca_private_key_pem` prints the CA key. Use it only to sign a CRL, then delete the file.

## Day to day

The association is not a Terraform resource. Use `scripts/aws/vpn-hub.sh` or the console. See the README.

Add a device by adding an entry to `client_devices` and applying again. `os` is `linux`, `windows`, or `ios`. `dns_updater = true` is valid only for Linux and Windows. The name becomes the certificate CN and the DNS label, so it must be a lowercase DNS label. Re-copy that device's `out/<name>/` directory. A new LAN host is also added to the Roles Anywhere trust condition.

Changing `vpc_cidr`, `vpn_client_cidr`, or `private_zone_name` after the first apply recreates resources. `vpn_client_cidr` cannot be edited in place; the endpoint has to be replaced. A route or DNS-server change on the endpoint restarts every session.

Certificates last two years (`certificate_validity_hours`) and renew 30 days early. Reinstall profiles after that apply. If the **server** certificate is replaced, read the plan: the endpoint may be replaced too, which drops the association and needs the second apply again.

### Revoke a device

Removing the name from `client_devices` stops new files from being generated. The certificate is still signed by the CA until you publish a CRL. Keep a copy of the device certificate **before** the apply that deletes `out/<device>/`. The tablet's certificate exists only inside its `.ovpn` (`<cert>` block).

These commands are bash. In Windows PowerShell 5.1, `>` writes UTF-16 and OpenSSL will not read it. Use Git Bash or WSL.

```bash
cd terraform/hub
umask 077
terraform output -raw ca_private_key_pem > ca.key
terraform output -raw ca_certificate_pem > ca.crt
# Build crl.pem with openssl ca. AWS documents the import here:
# https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/cvpn-working-certificates.html
aws ec2 import-client-vpn-client-certificate-revocation-list \
  --client-vpn-endpoint-id "$(terraform output -raw client_vpn_endpoint_id)" \
  --certificate-revocation-list file://crl.pem \
  --region mx-central-1 --profile vpn-hub
# If the device was a LAN host, also import a CRL on the Roles Anywhere trust anchor:
# https://docs.aws.amazon.com/rolesanywhere/latest/userguide/trust-model.html
shred -u ca.key 2>/dev/null || rm -f ca.key
rm -f ca.crt crl.pem index.txt*
```

`hub/ca.*` and `hub/*.pem` are gitignored. Delete them anyway when you are done.

## Destroy

1. Uninstall clients ([../docs/client-setup.md](../docs/client-setup.md#remove-a-device)) while the association is still up, so they stop retrying.
2. `bash scripts/aws/vpn-hub.sh --disable`. Destroy fails on the endpoint if a subnet is still associated. ENIs can take a few minutes to release; Terraform retries.
3. `terraform -chdir=terraform/hub destroy`. The private zone has `force_destroy`, so A records the laptops created are deleted with it.
4. Delete anything you created by hand: a bucket you used to store `vpn-hub.sh` for CloudShell, and a Roles Anywhere CRL if you imported one. The Client VPN CRL goes away with the endpoint.
5. `terraform -chdir=terraform/bootstrap destroy`. This deletes the bucket, including versions (`force_destroy_state_bucket`) and `hub/backend.hcl`. The KMS key waits `kms_deletion_window_days` (minimum 7) before it is gone. `aws kms cancel-key-deletion` undoes that during the window.
6. Remove `terraform/bootstrap/terraform.tfstate` if you do not need the empty local state, and any `*.tfplan` files.

The member account, the OU, and the enabled region are not in these stacks.

## Checks

```bash
bash tests/static/check-terraform.sh     # fmt -check, init -backend=false, validate
terraform -chdir=terraform/bootstrap test
terraform -chdir=terraform/hub test
```

`init -backend=false` does not talk to the S3 backend. Do not use it to switch a stack that is already initialized against S3 if you still need that backend; it is the right flag for a syntax check on a fresh clone.
