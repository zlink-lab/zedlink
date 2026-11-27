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
