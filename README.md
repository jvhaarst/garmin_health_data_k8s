# garmin_health_data_k8s

Helm chart that runs a **weekly Garmin Connect extract** on the home k3s cluster,
published as a Helm repository via GitHub Pages so it can be added as a chart
repository in Rancher.

- **Upstream tool:** [diegoscarabelli/garmin-health-data](https://github.com/diegoscarabelli/garmin-health-data)
  (`garmin-health-data` on PyPI)
- **Runtime image:** `ghcr.io/astral-sh/uv` — the job is `uvx --from
  garmin-health-data==<appVersion> garmin extract`

There is no image of our own to build. The upstream project publishes to PyPI,
not to a container registry, so the chart pins the *package* version in
`Chart.yaml` and lets Astral's uv image supply the Python runtime.

## What it does

Once a week it downloads new Garmin Connect data and loads it into a SQLite
database on a Longhorn volume. Nothing is exposed: no Service, no Ingress. The
database is pulled to a workstation on demand (see below).

## How updates flow

```
 upstream releases garmin-health-data N.N.N to PyPI
                                       │
                                       ▼
                 Renovate (this repo) bumps Chart.yaml appVersion
                                       │
                                       ▼
              helm-release workflow publishes a new chart version
                                       │
                                       ▼
                       Rancher sees the new chart version
```

- `renovate.json` watches the `garmin-health-data` PyPI release (via the chart
  `appVersion`) and the `ghcr.io/astral-sh/uv` image tag in `values.yaml`.
- Merging to `main` (or any change under `garmin-health-data/`) triggers
  `.github/workflows/helm-release.yaml`, which packages the chart (version
  auto-set to `<base>.<run_number>`) and publishes it + an updated `index.yaml`
  to GitHub Pages.

## Install

```bash
helm repo add garmin-health-data https://jvhaarst.github.io/garmin_health_data_k8s
helm repo update
helm upgrade --install garmin garmin-health-data/garmin-health-data \
  --namespace garmin --create-namespace
```

## Secrets and data are not in git

Two things live only on the volume, deliberately:

- `garmin_tokens.json` — full access to the Garmin Connect account.
- `garmin_data.db` — personal health data.

This repository is public and contains neither. The volume is seeded once, by
hand, from a machine that has run `garmin auth`.

### Seeding the volume

Flags are spelled out rather than held in shell variables: zsh does not
word-split an unquoted parameter, so `kubectl $CTX ...` is passed as one
argument and fails with `unknown flag: --context raspi5`.

```bash
USER_ID=<your garmin user id>

helm upgrade --install garmin garmin-health-data/garmin-health-data \
  --kube-context raspi5 -n garmin --create-namespace --set shell.enabled=true

POD=$(kubectl --context raspi5 -n garmin get pod \
  -l app.kubernetes.io/component=shell -o jsonpath='{.items[0].metadata.name}')
kubectl --context raspi5 -n garmin exec "$POD" -- mkdir -p "/data/.garminconnect/$USER_ID"
kubectl --context raspi5 -n garmin cp \
  "$HOME/.garminconnect/$USER_ID/garmin_tokens.json" \
  "garmin/$POD:/data/.garminconnect/$USER_ID/garmin_tokens.json"

# Optional: carry over an existing database so the first run resumes instead of
# starting 30 days back.
kubectl --context raspi5 -n garmin cp "$HOME/garmin/garmin_data.db" \
  "garmin/$POD:/data/garmin_data.db"

helm upgrade --install garmin garmin-health-data/garmin-health-data \
  --kube-context raspi5 -n garmin --set shell.enabled=false
```

### Pulling the database back

```bash
helm upgrade --install garmin garmin-health-data/garmin-health-data \
  --kube-context raspi5 -n garmin --set shell.enabled=true
POD=$(kubectl --context raspi5 -n garmin get pod \
  -l app.kubernetes.io/component=shell -o jsonpath='{.items[0].metadata.name}')
kubectl --context raspi5 -n garmin cp "garmin/$POD:/data/garmin_data.db" ~/garmin/garmin_data.db
helm upgrade --install garmin garmin-health-data/garmin-health-data \
  --kube-context raspi5 -n garmin --set shell.enabled=false
```

Disable the shell afterwards. It holds the ReadWriteOnce volume, so while it
runs a scheduled job can only start on the same node.

### When tokens expire

Tokens refresh themselves as long as a run happens at least every 30 days, which
the weekly schedule covers. If they do lapse, recovery is interactive and happens
on a workstation, not in the cluster: run `garmin auth` (or `garmin auth
--manual`, the browser-ticket flow, when Cloudflare blocks the automated login),
then re-seed the volume as above.

## Configuration

| Value | Default | Notes |
|-------|---------|-------|
| `image.repository` | `ghcr.io/astral-sh/uv` | Runtime only; the tool comes from PyPI. |
| `image.tag` | `python3.12-bookworm-slim` | Renovate-managed. |
| `packageVersion` | `""` | Empty → uses the chart `appVersion` (Renovate-managed). |
| `schedule` | `0 9 * * 0` | Sunday 09:00. |
| `timezone` | `Europe/Amsterdam` | |
| `extract.dbPath` | `/data/garmin_data.db` | `garmin_files/` is created next to it. |
| `extract.extraArgs` | `[]` | e.g. `{--start-date,2026-09-01}` for a one-off backfill. |
| `home` | `/data` | Must be on the volume: the token path is hardcoded to `~/.garminconnect`. |
| `persistence.storageClass` | `longhorn` | Set explicitly — the cluster has more than one class marked default. |
| `persistence.size` | `5Gi` | `activity_ts_metric` is ~93% of database growth. |
| `persistence.existingClaim` | `""` | Use a volume that already exists instead of creating one. |
| `shell.enabled` | `false` | Maintenance pod for `kubectl cp`. Enable, copy, disable. |
| `nodeSelector` | `memory-sufficient: "true"` | Keeps the job off node `ntp`. |
| `backoffLimit` | `2` | Low on purpose; Garmin rate-limits bursts. |

## Notes on shape

- **`HOME` is the token-store control.** The path `~/.garminconnect` is
  hardcoded upstream (`auth.py`), with no flag and no environment override, so
  pointing `HOME` at the volume is the only way to persist tokens.
- **The token store must be writable, not a Secret mount.** The client rewrites
  tokens on refresh and swallows write failures
  (`contextlib.suppress(Exception)`), so a read-only mount fails silently and
  then expires at the 30-day mark.
- **`concurrencyPolicy: Forbid`.** One SQLite writer, one ReadWriteOnce volume.
- **The PVC is annotated `helm.sh/resource-policy: keep`**, so uninstalling the
  release does not delete the database — or the tokens, whose replacement costs
  an interactive login.
- **`GARMIN_NO_VERSION_CHECK=1`.** The version is pinned by the chart, so the
  tool's own PyPI check on every run is dead weight.
- **No image build.** Adding one would mean a second repository and a registry
  for a package that upstream already publishes; `uvx` with the uv cache on the
  volume is cheaper and keeps the pinned version visible in git.

## Local development

```bash
helm lint garmin-health-data
helm template garmin garmin-health-data --namespace garmin
```
