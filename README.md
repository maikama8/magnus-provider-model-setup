# Magnus Provider Model Setup

This private repository contains the production setup guide and installer script for configuring MagnusBilling as a provider for external PBXs.

## Files

- `MAGNUS_PRODUCTION_SETUP.md` - step-by-step production guide.
- `setup.sh` - script that applies the required MagnusBilling and Asterisk changes.

## What The Script Applies

- Adds `MB_ACC` generation for Magnus SIP users.
- Adds the `SIP user: Create automatically` option after the password field on `Clients -> Users -> Add`, unchecked by default.
- Defaults manually-created SIP users' `Qualify` NAT setting to `yes`.
- Defaults the new-user `Group` field to `Client`.
- Keeps customer PBXs as SIP users in the `billing` context.
- Adds the public DID catch-all guard.
- Updates PJSIP anonymous inbound handling.
- Applies Magnus-side PJSIP/RTP audio settings when a public IP is provided.
- Optionally adds trusted admin/team IPs or CIDR ranges to fail2ban `ignoreip`.

## Usage

Run as `root` on the MagnusBilling server:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/setup.sh -o /root/setup.sh
chmod +x /root/setup.sh
bash /root/setup.sh
```

The script will prompt for:

```text
Public IP for Asterisk NAT/audio
Local/private network CIDR
Fail2Ban ignore IPs/CIDR ranges
```

Press `Enter` to accept detected values, or type `skip` when a setting should not be applied.

To pass values directly instead of using prompts:

```bash
bash /root/setup.sh --public-ip YOUR_PUBLIC_MAGNUS_IP --local-net YOUR_PRIVATE_NETWORK_CIDR --fail2ban-ignore "YOUR_OFFICE_IP YOUR_VPN_CIDR"
```

Preview actions without changing files:

```bash
bash /root/setup.sh --dry-run
```

## Important Model

```text
Customer PBXs = SIP Users in context billing
Provider carriers = Trunks in context billing
DID catch-all anonymous endpoint = public-did-inbound
```

Do not create one inbound trunk per DID. Inbound DIDs should use the separate catch-all DID context and only allow active DIDs configured in MagnusBilling.
Do not set outbound provider trunks to the DID catch-all context.
