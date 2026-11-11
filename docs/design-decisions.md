# Design decisions

This note replaces an implementation journal. It records the choices a reader needs, not a timeline of one deployment.

## Tradeoff

**Cost over continuous availability.** The endpoint is associated with a subnet only while someone needs it, and by default that subnet is in a single Availability Zone. A hub that is off accepts no clients, and an AZ failure takes the only association down. High availability is a variable (`enable_high_availability`): it adds a second subnet and a second hourly association charge. Reliability was the pillar given up. Security of identity and of the VPC edge was not: no long-lived keys, no path from this VPC to the internet, no management ports open to `0.0.0.0/0`.

Sustainability follows the same choice. An idle association is paid compute and data-plane capacity that nobody is using. Turning it off removes that spend and that load together.

## Why Client VPN, not a site-to-site VPN

The clients move. A tablet on a cellular network and two LAN hosts behind a home ISP NAT do not have a stable public address or a port you can forward. Site-to-site VPN wants a device on the LAN that is always the endpoint. Client VPN makes every machine a client of a managed endpoint, which is the client-to-client scenario in the [Client VPN administrator guide](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/scenario-client-to-client.html).

The cost of that choice is the association-hour price. A site-to-site VPN is cheaper when it is up all month and the far end has a static address. This reference does not assume either.

## Why split tunnel

Only the VPC CIDR and the client CIDR go through the tunnel. Internet traffic stays on the device's own connection, so browsing does not depend on a NAT gateway and does not show up as AWS data transfer. The VPC therefore has no internet gateway.

Given up: you cannot inspect or filter the client's internet traffic, and a client on a hostile network still talks to the internet directly. Add a full tunnel only if that inspection is a requirement, and budget for NAT plus data transfer. AWS also restarts sessions when the route table changes, and does not recommend `0.0.0.0/0` together with split tunnel.

## Why the association is outside Terraform

Documented behavior:

- You pay for each subnet association for every hour it exists.
- Disassociating the last subnet ends every connection and returns the endpoint to `pending-associate`.
- The client-to-client route uses target `local`. It is not recreated automatically, and it does not survive disassociation. `CreateClientVpnRoute` is called again on each enable. `scripts/aws/vpn-hub.sh --enable` does both steps.
- If Terraform owned the association, an `apply` would undo an operator who had turned the hub off.

## Why Route 53 and not `/etc/hosts`

Tunnel addresses come from `10.81.0.0/22` and change every session. A private hosted zone associated with the VPC is visible to clients that use the VPC resolver (`cidrhost(vpc_cidr, 2)`, here `10.80.0.2`). Each LAN host upserts its own A record.

Rejected: a zone ending in `.local`. Route 53 would accept the name, but clients treat `.local` as multicast DNS ([RFC 6762](https://www.rfc-editor.org/rfc/rfc6762.html#section-3)) and often never query the VPN DNS server. `.internal` is the private-use suffix ICANN reserved in 2024. The default name `vpn.example.internal` is a placeholder. Use your own private suffix if you have one. Do not use a name that exists on the public internet.

## Why IAM Roles Anywhere, not an IAM user

The DNS updater needs `route53:ChangeResourceRecordSets`. An IAM user would leave an access key on the laptop. Roles Anywhere issues a one-hour session when the host presents the same client certificate the VPN already uses.

The trust policy allows `rolesanywhere.amazonaws.com` only from this trust anchor, and only when the certificate CN is one of the LAN hosts (the tablet is excluded). The permissions policy allows a single action, `UPSERT`, a single record type, `A`, and only the name `<CN>.<zone>`. There is no `Delete`, no `List`, and no wildcard resource. The host does not read the zone back; it compares the tunnel address with a local cache.

## Why these CIDRs

| Range | Reason |
|---|---|
| `192.168.1.0/24` | Documentation LAN (RFC 1918). Overlap check only. Replace it with the real LAN in `terraform.tfvars`. Example hosts in the docs are `.10` and `.20`. |
| `10.80.0.0/16` | Hub VPC. Does not overlap the example LAN or the client range. |
| `10.81.0.0/22` | Smallest client range AWS accepts, and large enough for a handful of devices. Immutable after create. AWS suggests sizing for twice the expected connections. |

Client VPN also requires the client's local network to sit inside `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, or `169.254.0.0/16`. A normal home or office LAN already does.

## Why a member account and a guard

The hub and its state bucket hold private keys. A dedicated member account limits the blast radius and makes the bill readable in Cost Explorer without cost-allocation tags. The management account is rejected by a postcondition on `aws_organizations_organization` (`return_organization_only = true`, so a member account is allowed to call it). `allowed_account_ids` stops a mistyped profile before any API call that changes resources.

A standalone account with no organization cannot apply this stack. Create the organization and a member account first. That is deliberate, not an oversight.

Tags `Project`, `Environment`, `Owner`, `CostCenter`, and `ManagedBy` are applied by the provider `default_tags` block. The budget filter needs `Project` activated as a cost-allocation tag in the payer account. Until then, the account boundary is the cost boundary.

## Certificates

Client VPN accepts only RSA 1024 or 2048. This stack uses 2048. The client certificate must have a CN. Server and clients share one CA, so the endpoint uses the server certificate ARN as the client trust chain as well. The server name `vpn-server.<zone>` does not have to resolve; it only identifies the certificate.

Keys are generated by the `tls` provider and stored in remote state. That is why the state bucket is the first stack, why it is KMS-encrypted, and why `*.tfstate`, `*.tfplan`, `out/`, and `*.ovpn` are gitignored.

Renewal is `early_renewal_hours = 720` (30 days) on a two-year certificate. After a renewing apply, reinstall the profiles. Replacing the server certificate can replace the endpoint (new id, new DNS name, association lost). Read that plan before you apply it.

## What is still missing for production

Call these out if you extend the reference. They are not hidden defaults.

| Gap | Why it is still open | How to close it |
|---|---|---|
| Broad operator permission set | A lab apply touches VPC, EC2, ACM, Route 53, IAM, Roles Anywhere, KMS, S3, CloudWatch Logs, and Budgets. `AdministratorAccess` is the short path. | A permission set limited to those APIs, and a separate read-only set for the verify scripts. |
| Manual CRL | Removing a device from `client_devices` does not invalidate its certificate. | Import a CRL on the endpoint and, for a LAN host, on the Roles Anywhere trust anchor. See `terraform/README.md`. |
| Keys in state | Terraform has to keep the CA key to sign new certificates. | Restrict `s3:GetObject` and `kms:Decrypt` on the state bucket to the operators who already may `apply`. |
| No VPC flow logs | Nothing in the VPC is a workload. | Add flow logs if you later place resources here. |
| No access logs on the state bucket | The bucket is private, versioned, and TLS-only. Access logs need a second bucket. | Add them if your log policy requires it. |
| Connection logs use the AWS-owned CloudWatch key | A customer key costs extra for a log that contains certificate names and client addresses. | Switch the log group to a CMK if those addresses are in scope for your key policy. |
| Host firewall not configured | SSH and RDP on the LAN hosts may stay open to the LAN as well as the VPN. | Limit ports 22 and 3389 to `vpn_client_cidr` and `vpc_cidr` when the LAN should not reach them. |
| Single AZ, association by hand | See the tradeoff above. | `enable_high_availability` and an alarm on the association if the hub must stay up. |
| Provider quirk | AWS provider 6.71.0 does not send `disconnect_on_session_timeout = false` on create. | Second `apply` after create. Recheck when you bump the provider. |
| Ghost sessions | After disassociate, the API can still list connections that are already dead until the next associate. | Do not trust `verify-connections.sh` in that state. |

## Sources

Checked against AWS documentation while this reference was prepared. Re-check before you depend on a quota or a price.

- [AWS Client VPN pricing](https://aws.amazon.com/vpn/pricing/) (Ohio worked example: $0.10 per association-hour, $0.05 per connection-hour)
- [Client VPN administrator guide, pricing and Elastic IP behavior](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/what-is.html) (public IPv4 on the ENI only when the VPC has an internet gateway)
- [Split-tunnel](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/split-tunnel-vpn.html)
- [Mutual authentication](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/mutual.html)
- [CreateClientVpnRoute](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_CreateClientVpnRoute.html)
- [IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html)
- [Opt-in regions](https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-regions.html)
- [RFC 6762 section 3](https://www.rfc-editor.org/rfc/rfc6762.html#section-3)
- [RFC 5737, documentation addresses](https://www.rfc-editor.org/rfc/rfc5737) (`203.0.113.0/24` when a public address has to appear in an example)
