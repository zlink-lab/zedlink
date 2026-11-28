# Zed and the gateway as systemd --user services

The gateway can start and restart Zed (`zed.status`, `zed.start`, `zed.restart`) and pushes
"Zed не отвечает" when a running Zed stops answering for a minute. It only runs
`systemctl --user start|reset-failed|is-active <unit>` for the configured unit and signals the
process that owns the target's private bridge socket (same user, executable `zed*`).

## Install (laptop)

```sh
install -m 644 zed-zlink.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable zed-zlink.service      # start with the graphical session
systemctl --user edit zedlink-gateway.service  # add:
#   [Service]
#   Environment=ZEDLINK_ZED_UNIT=zed-zlink.service
systemctl --user restart zedlink-gateway.service
```

With `serve-targets`, the unit can instead be set per target in the targets file:
`{"id": "...", "label": "...", "probe": "...", "zed_unit": "zed-zlink.service"}`.

`instance.quit` (graceful quit, workspaces and unsaved buffers serialized) needs Zed
`zlink.6` or newer and `allow_workspace_control` in the `zedlink` settings; older bridges are
stopped with SIGTERM, then SIGKILL.

## Notes

- Zed started from the dock or a terminal runs outside the unit. Restart still works: the
  gateway quits that process and starts the unit. To keep everything under the unit, point the
  desktop launcher at `systemctl --user start zed-zlink.service`.
- A logged-out user has no graphical session: Zed cannot be started. A locked screen is fine.
- `Restart=no` is deliberate; the gateway only restarts on request from the phone.

## Gateway auto-update

Releases `gateway-v<n>` (workflow "Gateway release", never marked Latest) carry
`zedlink-gateway-linux-x86_64.tar.gz` (binary + this `systemd/` folder) and its `.sha256`.
`zedlink-gateway-update` installs the newest one into
`~/.local/share/zedlink/gateway/release/versions/<tag>`, points `current` at it, restarts
`zedlink-gateway.service`, and switches back if the unit is not active 10 s later (that release
is then skipped until `--tag` forces it). It keeps the last three versions.

First install (once):

```sh
python3 -I zedlink-gateway-update --no-restart        # from an unpacked release or the repo
systemctl --user edit --full zedlink-gateway.service  # ExecStart= → %h/.local/share/zedlink/gateway/release/current/zedlink-gateway <same arguments>
cp ~/.local/share/zedlink/gateway/release/current/systemd/zedlink-gateway-update.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user restart zedlink-gateway.service
systemctl --user enable --now zedlink-gateway-update.timer
```

Check: `zedlink-gateway-update --check`, `journalctl --user -u zedlink-gateway-update`,
`curl -sk https://<gateway>/v1/gateway` shows `build`. Updating the gateway drops phone
connections for a few seconds; the app reconnects.

## Zed auto-update (planned for idle)

`zed-zlink-update` (timer, every 10 minutes) stages the newest `zed-v<version>-zlink.<n>` release: it
downloads it, checks the sha256 and `zed --version`, unpacks it to
`~/.local/.zed.app.next-<tag>` and writes `~/.local/share/zedlink/zed/pending.json`. It never
touches the running Zed.

The gateway installs a staged release when Zed is idle: no thread Generating, none waiting for
an approval or an input, no autopilot job due within 5 minutes, and that for 3 minutes in a
row (a closed Zed is updated at once and not started). It then quits Zed like `zed.restart`,
renames `~/.local/zed.app` → `~/.local/.zed.app.prev` and the staged copy into place, starts
`zed-zlink.service` and waits 90 s for the bridge. If the bridge does not come up, it puts the
previous Zed back, starts it and marks the release `failed-<tag>` (not retried; `--tag` forces
it). Either way the phone gets a push. Running turns are never interrupted for an update.

A Zed already replaced on disk by other means (unpacked by hand, another updater) while the
old one keeps running is handled the same way: when the running process's executable is no
longer the file at `~/.local/zed.app/libexec/zed-editor`, the gateway restarts Zed into it once
all threads have stopped (no swap, so no rollback; it first checks that `bin/zed --version`
runs, and restarts into a given binary only once). Only a Zed started from that app directory
is considered.

`zed.status` → `update: {installed_tag, pending_tag, waiting, applying, last_result}`;
`zed.update {"now": true}` skips the 3-minute settle once.

Needs Zed control (`ZEDLINK_ZED_UNIT` above). Install (once):

```sh
cp ~/.local/share/zedlink/gateway/release/current/systemd/zed-zlink-update.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now zed-zlink-update.timer
```

A Zed unpacked by hand has no `~/.local/zed.app/.zlink-release`, so the first run stages the
newest release even if it is the one already installed (one extra restart, once). Env:
`ZEDLINK_ZED_APP` (default `~/.local/zed.app`), `ZEDLINK_ZED_UPDATE_DIR`.

## Second address: Yggdrasil mesh

The same gateway (same `gateway_id`, same pairing) can also listen on its Yggdrasil address
(`200::/7`). Add a second listener to `listeners.json` and give it a certificate whose SAN
covers that IP:

```json
{"version": 1, "listeners": [
  {"id": "lan",  "bind": "192.168.1.20:8443", "cert": "/…/lan.pem",  "key": "/…/lan-key.pem",
   "url": "https://192.168.1.20:8443"},
  {"id": "mesh", "bind": "[201:abcd:…:1]:8443", "cert": "/…/mesh.pem", "key": "/…/mesh-key.pem",
   "url": "https://[201:abcd:…:1]:8443"}]}
```

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 825 \
  -subj "/CN=zedlink-mesh" -addext "subjectAltName=IP:201:abcd:…:1" \
  -keyout mesh-key.pem -out mesh.pem && chmod 600 mesh-key.pem
```

A Yggdrasil address is reachable by every node of the mesh, not just your devices: bind only the
gateway port to it (no other services on that address), and keep pairing + TLS as the
authorization — reachability over the mesh grants nothing by itself. The phone stores it as
"Mesh-адрес" and uses whichever of the two addresses answers with the expected `gateway_id`.
`reload-tls` reloads both certificates.

## Autopilot, unread counters and history

The gateway polls every exposed thread every 2 s (whether or not a phone subscribed to pushes)
and the agents' subscription limits every 2 min (bridge `agent.limits`, and the newest
`$CODEX_HOME/sessions/**/rollout-*.jsonl` tail for Codex). Autopilot is on for every thread by
default (Settings → Автопилот on the phone, or `/auto off` in a thread): it continues threads
that stopped on a usage limit, `max_turn_requests` or a stall, holds automatic continues at
≥ 95 % with a reset more than an hour away, and cancels running turns at ≥ 98 %. It never
approves tools.

History lives in `<state>/zedlink.sqlite` (WAL, kept 400 days): per-turn token counts, limit
samples and the autopilot log — ids, numbers and short codes only, no message text or titles.
Deleting the file loses the history only; it is recreated on the next start.
