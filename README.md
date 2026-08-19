# omarchy-docker

Docker containers and compose stacks on the [Omarchy](https://omarchy.org) bar.

![Panel preview](preview.png)

A whale in the status bar, a control panel one click away:

- **Compose stacks** — containers grouped by `com.docker.compose.project`.
  Stack start runs `docker compose up -d` (recreates removed containers,
  picks up compose.yml changes); stack stop is a plain `docker stop`, never
  a destructive `down`.
- **Per-container controls** — start, stop, restart, unpause, and remove
  (stopped containers only, behind a confirm dialog).
- **Logs and shell** — one click opens a floating terminal with
  `docker logs -f` or an interactive `docker exec` shell.
- **CPU/memory per container** — sampled with `docker stats` while the
  panel is open; the closed widget costs nothing.
- **Clickable ports** — a published port opens `http://localhost:<port>`
  in the browser.
- **Live updates** — the panel follows `docker events`, so work done in a
  terminal (compose up, stops, health flips) shows up immediately.
- **Health at a glance** — unhealthy containers turn urgent in the panel,
  put a badge dot on the bar icon, and raise a desktop notification when
  they flip (can be turned off).
- **Port-conflict hints** — a stopped container whose published host port is
  held by a running one is told exactly who is squatting on it.
- **Clean up** — see how much space dangling images and build cache hold,
  and prune them behind a confirm dialog. Stopped containers and volumes
  are never touched.
- **Daemon switch and autostart** — start/stop `docker.service` and toggle
  enable-at-boot from the panel, authorized through the regular polkit
  prompt.

## Install

```bash
omarchy plugin add https://github.com/Erruviel/omarchy-docker.git --enable
```

That's it. The plugin runs entirely unprivileged: container data and actions
go through the docker CLI (your `docker` group membership), and the daemon
switch calls `systemctl` as your user, which authenticates through polkit.
Nothing is installed outside the plugin directory, and nothing runs as root.

## Requirements

- `docker` CLI and, to see any containers, membership in the `docker` group:

  ```bash
  sudo usermod -aG docker $USER
  ```

  (log out and back in afterwards). Without it the panel explains what to do.
- `jq` (ships with Omarchy).

If Docker is not installed at all, the widget hides itself.

## Settings

In `~/.config/omarchy/shell.json`, on the widget entry:

| Key | Default | Meaning |
|-----|---------|---------|
| `interval` | `10` | Background poll interval in seconds while the panel is closed. Events refresh the panel regardless; this is the safety net. |
| `showCount` | `false` | Show the number of running containers next to the whale on the bar. |
| `notifyUnhealthy` | `true` | Desktop notification when a container turns unhealthy. |

```json
{ "id": "erruviel.docker", "interval": 30, "showCount": true }
```

## Uninstall

```bash
omarchy plugin remove erruviel.docker
```

## License

MIT — see [LICENSE](LICENSE).
