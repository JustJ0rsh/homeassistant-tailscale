# Home Assistant + Tailscale

This compose project runs:

- `homeassistant` on the host network, matching Home Assistant's container guidance.
- `tailscale` as a separate container that joins your tailnet and serves Home Assistant from `http://127.0.0.1:8123`.

It is tuned conservatively for removable storage:

- Docker log rotation is capped to reduce uncontrolled log growth.
- Home Assistant starts with a small `recorder` retention window to reduce write volume.
- `/tmp` inside the Home Assistant container is in memory instead of on disk.

## Files

- `docker-compose.yml`: service definitions
- `.env.example`: environment template
- `tailscale/config/serve.json`: Tailscale Serve config
- `homeassistant/config/`: persistent Home Assistant config
- `tailscale/state/`: persistent Tailscale state

## Before first start

1. Install Docker and Docker Compose on the host.
2. Copy `.env.example` to `.env`.
3. Set `TZ` to your timezone.
4. Set `TAILSCALE_HOSTNAME` to the node name you want in Tailscale.
5. Create a Tailscale auth key and put it in `TS_AUTHKEY`.
6. Edit `tailscale/config/serve.json` and replace `REPLACE_WITH_YOUR_TAILSCALE_DNS_NAME` with the MagicDNS name assigned to this node, for example `homeassistant.your-tailnet.ts.net`.

For the auth key, Tailscale recommends using an environment variable rather than putting the key directly in shell history or commands.

## Start

```sh
cd /root/homeassistant-tailscale
./install-and-run.sh
```

For a one-shot bootstrap/rebuild (system packages + optional repo/image refresh + compose deploy), run:

```sh
cd /root/homeassistant-tailscale
./bootstrap-vm.sh
```

By default it runs with:

- `REPO_UPDATE=1`
- `IMAGE_REFRESH=1`
- `FORCE_RECREATE=1`
- `PRUNE_IMAGES=0`
- `TIMEZONE_NAME` from host (or `America/Chicago` if unset)

You can override these defaults by exporting environment variables before running the script.

The installer also sets the host timezone on Alpine. By default it uses `America/Chicago`; override that for another zone with `TIMEZONE_NAME=Region/City ./install-and-run.sh`.

If you want a beginner-friendly step-by-step setup guide, use [`HOWTO.md`](/root/homeassistant-tailscale/HOWTO.md).

## Access

- Local network: `http://HOST_IP:8123`
- Tailnet: `https://TAILSCALE_HOSTNAME.tailnet.ts.net`

The first Home Assistant login and onboarding happen in the web UI after the container starts.

## Notes

- If you use Zigbee/Z-Wave USB hardware later, add `devices:` mappings to `homeassistant`.
- If you prefer not to use an auth key, leave `TS_AUTHKEY` empty and run `docker exec -it tailscale tailscale up` after the container starts. That will print a login URL.
- The installer script currently targets Alpine Linux because this host uses Alpine and OpenRC.
- A USB SSD is much better than a flash drive for this workload. Flash drives are the highest-risk part of this deployment.
