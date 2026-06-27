# Magnus Provider Model Setup

This private repository contains the production setup guide and installer script for configuring MagnusBilling as a provider for external PBXs.

## Files

- `MAGNUS_PRODUCTION_SETUP.md` - step-by-step production guide.
- `apply-magnus-provider-model.sh` - script that applies the required MagnusBilling and Asterisk changes.

## What The Script Applies

- Adds `MB_ACC` generation for Magnus SIP users.
- Adds the `SIP user: Create automatically` option on `Clients -> Users -> Add`.
- Keeps customer PBXs as SIP users in the `billing` context.
- Adds the public DID catch-all guard.
- Updates PJSIP anonymous inbound handling.
- Applies Magnus-side PJSIP/RTP audio settings when a public IP is provided.

## Usage

Run as `root` on the MagnusBilling server:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/apply-magnus-provider-model.sh -o /root/apply-magnus-provider-model.sh
chmod +x /root/apply-magnus-provider-model.sh
bash /root/apply-magnus-provider-model.sh --public-ip YOUR_PUBLIC_MAGNUS_IP --local-net YOUR_PRIVATE_NETWORK_CIDR
```

If the server does not use a private/local network, omit `--local-net`:

```bash
bash /root/apply-magnus-provider-model.sh --public-ip YOUR_PUBLIC_MAGNUS_IP
```

Preview actions without changing files:

```bash
bash /root/apply-magnus-provider-model.sh --dry-run --public-ip YOUR_PUBLIC_MAGNUS_IP --local-net YOUR_PRIVATE_NETWORK_CIDR
```

## Important Model

```text
Customer PBXs = SIP Users in context billing
Provider carriers = Trunks
DID catch-all = public-did-inbound
```

Do not create one inbound trunk per DID. Inbound DIDs should use the separate catch-all DID context and only allow active DIDs configured in MagnusBilling.
