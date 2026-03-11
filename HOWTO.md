# Home Assistant + Tailscale Quick How-To

## What this does

This folder runs two containers:

- `homeassistant` (Home Assistant app)
- `tailscale` (Tailnet access for remote access)

It is built to start automatically when your VM starts (Docker is enabled at boot and both containers use `restart: unless-stopped`).

## One-time setup (new VM)

1. Open a terminal on the VM.
2. Go to the project folder:

```sh
cd /root/homeassistant-tailscale
```

3. Copy the environment file and add your values:

```sh
cp .env.example .env
```

Edit `.env` and set at least:

- `TZ` (time zone, e.g. `America/Chicago`)
- `TAILSCALE_HOSTNAME` (Tailnet node name)
- `TS_AUTHKEY` (your Tailscale auth key)

4. Update `tailscale/config/serve.json`:

- Replace `REPLACE_WITH_YOUR_TAILSCALE_DNS_NAME` with the DNS name from Tailscale
  (for example `homeassistant.tail3b7f0.ts.net`)

5. Run the bootstrap script:

```sh
./bootstrap-vm.sh
```

This will:

- update/install needed OS packages,
- enable/start Docker,
- pull and start the two containers.

## Daily use

- Check status:

```sh
docker compose ps
```

- Restart both containers:

```sh
docker compose up -d
```

- Run it again whenever you need a refresh:

```sh
./bootstrap-vm.sh
```

## Tailscale quick checks

- Check node status:

```sh
docker exec tailscale tailscale status
```

- If this machine is not logged in yet:

```sh
docker exec tailscale tailscale up
```

- Check logs:

```sh
docker logs tailscale --tail 100
```

## Remote access

Enable Tailscale SSH (if needed) with:

```sh
docker exec tailscale tailscale up --ssh --accept-dns=false
```

Then from another Tailnet device:

```sh
ssh root@100.113.182.82
```

Replace the IP with your current Home Assistant Tailnet IP if it changes.

## Notes

- If `tailscale/config/serve.json` still has the placeholder DNS name, external tailnet HTTPS proxying is not set correctly yet. Local access still works.
- The script is safe to run repeatedly.
- Use `install-and-run.sh` for the original installer flow, or `bootstrap-vm.sh` for full refresh/sync flow.
