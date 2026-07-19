# cloud-gaming-pc

Bootstrap script for CloudCompute **Cloud Gaming PC (Linux)** on Vast Ubuntu Desktop (VM).

Fetched at instance boot:

`https://raw.githubusercontent.com/cloudcompute-ru/cloud-gaming-pc/main/provision.sh`

## What it does

- Waits for Selkies on port 6100
- Sets per-instance Sunshine credentials (from `CC_SUNSHINE_*` env)
- Starts a bearer-auth HTTP helper on port 8765 for Moonlight PIN pairing
- Optionally enrolls Tailscale when `TAILSCALE_AUTH_KEY` is set on the app server
- Reports provisioning stages to CloudCompute

Steam/Proton are preinstalled in the Vast template — this script does not install games.
