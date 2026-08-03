# Reliable RunPod workflow

Wan2GP stays private inside the pod on `127.0.0.1:7860`. Access it through an SSH local forward; do not add `--listen` or expose port 7860 publicly unless that is a deliberate change.

## Starting the pod

1. Start the RunPod pod and copy the current direct TCP SSH host and port from its dashboard. The external SSH port can change after a restart or reprovision.
2. Start or verify Wan2GP in the pod.
3. Start the Mac tunnel using that host and port.
4. Open <http://localhost:7860>.

### Pod commands

```bash
cd /workspace/Wan2GP
./scripts/start-wan2gp.sh
```

This foreground command streams `logs/wan2gp.log`. For unattended startup use `./scripts/start-wan2gp.sh --background`. It records only its own PID in `.run/wan2gp.pid`; `--status` and `--stop` will never broadly kill Python.

```bash
./scripts/start-wan2gp.sh --status
./scripts/check-wan2gp.sh
./scripts/start-wan2gp.sh --stop
```

### Clearing generated and uploaded media

The pod has no Jupyter recycle bin: this cleanup is permanent. First stop Wan2GP,
then inspect the cleanup targets (dry run):

```bash
./scripts/start-wan2gp.sh --stop
./scripts/clean-wan2gp-media.sh
```

When the displayed locations are correct, permanently remove all generated media
from `outputs/` and all Gradio upload/cache files from `/tmp/gradio`:

```bash
./scripts/clean-wan2gp-media.sh --delete
```

The script does not touch models, LoRAs, source code, settings, logs, or unrelated
files in `/tmp`.

`check-wan2gp.sh` exits `0` healthy, `1` missing process, `2` unavailable port, `3` failed HTTP health, and `4` configuration/check capability error. It reads cgroup v1 or v2 memory limits rather than trusting `free -h`, and warns at 90% by default (`WAN2GP_MEMORY_WARN_PERCENT` can override it). It does not change the selected lower-memory 32 GB RAM / 24 GB VRAM profile or kill processes for high memory.

### Automatic pod startup

In the RunPod pod/template startup-command field (the label varies by template), use:

```bash
/workspace/Wan2GP/scripts/start-wan2gp.sh --background
```

It is idempotent. Alternatively, for restart-on-crash behavior, use the lightweight supervisor:

```bash
/workspace/Wan2GP/scripts/run-wan2gp-service.sh
```

It waits between failures (10 seconds initially, then 60 seconds after repeated failures), logs to `logs/wan2gp-supervisor.log`, and stops on `SIGTERM`/`SIGINT`. Use this approach only when it is intended to own restarts; normal `--stop` is for the regular managed process.

## Mac tunnel

```bash
./tools/mac/wan2gp-tunnel.sh \
  --host HOST_FROM_RUNPOD \
  --port PORT_FROM_RUNPOD \
  --user root
```

The script uses your normal SSH agent/Keychain and configuration when `--identity` is omitted. If you know the correct key path, add `--identity /path/to/key`; it never assumes `~/.ssh/id_ed25519`. It prefers `autossh` and otherwise uses a small reconnect loop around `ssh`. Both bind only local port 7860.

If the RunPod dashboard displays an SSH command with `-i /path/to/key`, you may pass that same existing path as `--identity /path/to/key`; otherwise leave `--identity` out so SSH can use your agent and normal configuration. Do not commit a pod host, external port, or private-key path to this repository.

```bash
./tools/mac/wan2gp-tunnel.sh status
./tools/mac/wan2gp-tunnel.sh stop
```

It records only its own PID at `~/.wan2gp/tunnel.pid`, refuses an already occupied local port, and will not kill unrelated SSH sessions. `--replace` restarts only a tunnel already managed by this helper. Install the preferred reconnect utility with `brew install autossh`.

Optional `~/.ssh/config` entry (update `Port` after every relevant pod restart):

```sshconfig
Host wan2gp-runpod
    HostName HOST_FROM_RUNPOD
    User root
    Port PORT_FROM_RUNPOD
    ServerAliveInterval 15
    ServerAliveCountMax 3
    TCPKeepAlive yes
```

Do not add an `IdentityFile` line unless you have confirmed its actual private-key path.

## Troubleshooting

An SSH tunnel, Wan2GP process, local port, and HTTP response can all be healthy while one Gradio browser tab is stale. Recover in this order: open a new `http://localhost:7860` tab, hard refresh (`Command + Shift + R`), try Incognito, restart only Wan2GP if the backend is unresponsive, then restart the entire pod only as a last resort.

```bash
# Mac
lsof -i :7860
curl -I http://127.0.0.1:7860

# Pod
ss -ltnp | grep 7860
ps aux | grep '[w]gp.py'
curl -I http://127.0.0.1:7860
```

- Local `connection refused`: no tunnel is listening.
- `channel open failed: connect failed: Connection refused`: SSH connected but Wan2GP is not listening in the pod.
- `Broken pipe` or remote operation timeout: the SSH connection dropped.
- HTTP `200 OK`: the tunnel and web service are reachable.
- A new tab works while an old tab does not: stale Gradio browser session.

If SSH reports **host key verification failed** after a pod restart or a newly assigned direct-TCP endpoint, do not disable host-key checking. Confirm the new host fingerprint from a trusted RunPod source, then remove only the old entry for that exact host and reconnect so SSH can store the verified key.

`Value: 576x320 is not in the list of choices` is usually stale saved UI state after a model/workflow switch or a changed available-resolution list. Refresh/open a new tab and choose a resolution offered by the selected model. Wan2GP already resolves model-switch resolutions against the target model's supported choices; this workflow deliberately does not force `576x320` into unsupported models.
