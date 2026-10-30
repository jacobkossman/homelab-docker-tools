# homelab-docker-tools

Manual container updates from Home Assistant, and nightly per-app backups to Proxmox
Backup Server, for Docker Compose hosts. Works across several hosts.

- **No automatic updates.** Every container shows up in Home Assistant's *Settings → Updates*
  as a normal update entity. Nothing changes until you press **Install**.
- **Per-app backups.** Each app folder (and any named volumes it uses) is backed up to PBS on
  its own, so an app is stopped only for the seconds its own backup takes, and you restore one
  app without touching the others.
- **You hear about failures.** Each host reports its backup status to Home Assistant, and an
  automation notifies you when a run fails or a host stops backing up.

It glues together two existing tools, [updates2mqtt](https://github.com/rhizomatics/updates2mqtt)
and `proxmox-backup-client`, with a few small scripts.

## What's in here

| Path | What it does |
|---|---|
| `scripts/pbs-docker-backup.sh` | Nightly backup of every app folder (+ its named volumes) to PBS, one app at a time |
| `scripts/deploy.sh` | Installs the backup script on all your hosts over SSH |
| `scripts/docker-audit.sh` | Read-only report of which app folders are running, stopped or unused |
| `home-assistant/docker-backup-alerts.yaml` | HA automation: notify on failed or overdue backups |
| `home-assistant/rename-update-entities.py` | Renames updates2mqtt entities in HA to `jellyfin (media)` |
| `examples/` | updates2mqtt compose file, backup settings, cron entry, exclusion example |

## Assumptions

- Each Docker host keeps **one folder per app**, holding its compose file and its data:
  ```
  ~/docker/
    jellyfin/   compose.yaml  config/
    sonarr/     compose.yaml  config/
  ```
  Any compose file name works. Data in named volumes is fine too (see [Backups](#2-backups-to-proxmox-backup-server)).
- Hosts run Debian or Ubuntu with the Docker Compose v2 plugin (`docker compose`, not `docker-compose`).
- You have a Proxmox Backup Server and Home Assistant with an MQTT broker (e.g. the Mosquitto add-on).

---

## 1. Manual updates in Home Assistant

updates2mqtt runs as one small container per host. It checks registries for newer images and
publishes an MQTT `update` entity per container. Pressing **Install** in HA makes it pull the new
image and run `docker compose up -d` for that app. It never updates on its own (its default mode
is *Passive*).

### Set up a host

1. Create an MQTT user for it. With the Mosquitto add-on, a Home Assistant user works
   (*Settings → People → Users*, admin off).
2. Copy `examples/updates2mqtt/` next to your app folders, then:
   ```bash
   cd ~/docker/updates2mqtt
   cp .env.example .env && chmod 600 .env    # fill in HOST_NAME, DOCKER_DIR, MQTT_*
   docker compose -f updates2mqtt.yml up -d
   docker logs -f updates2mqtt               # look for a scan of your containers
   ```
3. The host's containers appear under *Settings → Updates* as updates become available.
4. Test one **Install** on something low-risk before relying on it.

`DOCKER_DIR` must be mounted at the **same absolute path** inside the container. That's how it
finds each app's compose file when you press Install.

### Per-container options (compose labels)

```yaml
    labels:
      - updates2mqtt.ignore=True               # leave this container out entirely
      - updates2mqtt.relnotes=https://github.com/owner/repo/releases
      - updates2mqtt.picture=https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/sonarr.png
      - updates2mqtt.version_policy=Version    # show v1.2.3 instead of v1.2.3:abcdef
```

Labels apply when the container is next recreated (an update does that anyway). Use
`ignore` for anything that already has its own HA update entity (e.g. Frigate).

### Cleaner names in the Updates page (optional)

By default every row is titled `<host> updates2mqtt`, because all of a host's containers share
one HA device. To give each row its own title like `jellyfin (media)`:

1. Copy `examples/updates2mqtt/conf/config.yaml` into the host's `updates2mqtt/conf/`.
2. In HA, delete that host's updates2mqtt device (*Settings → Devices & services → MQTT → device → Delete*).
3. `docker restart updates2mqtt` and wait for its scan (about a minute).
4. Rename the entities from any machine with Python 3, using a long-lived token
   (*HA profile → Security → Long-lived access tokens*):
   ```bash
   python3 home-assistant/rename-update-entities.py            # dry run
   python3 home-assistant/rename-update-entities.py --apply
   ```
   Set `HA_URL` if HA isn't at `http://homeassistant.local:8123`, and `NAME_FORMAT` for a
   different pattern (default `{app} ({host})`). Run it again after adding containers.

The trade-off: the per-host device page goes away; entities are still searchable by name.

---

## 2. Backups to Proxmox Backup Server

`pbs-docker-backup.sh` walks every folder in `BASE` and, for each app:

1. stops it, if the folder has a `.stopforbackup` marker and it's running;
2. backs up the folder, plus every named volume its containers use, as one PBS snapshot;
3. starts it again (also if the script is interrupted), and moves on to the next app.

In PBS you get `docker/<host>/host/<app>`, one group per app with its own history. Repeat runs
upload only changed chunks, and with a recent client only changed files are even read.

### On PBS (once)

1. **User and token.** *Configuration → Access Control*:
   - add user `backup@pbs`;
   - on the *API Token* tab, add token `docker` for it and **copy the secret** (shown once).
2. **Namespaces.** *Datastore → yours → Content → Add Namespace*: `docker`, then one per host
   inside it (`docker/media`, `docker/cameras`, …).
3. **Permissions.** *Datastore → Permissions*, path `/datastore/<datastore>/docker`, role
   **DatastoreBackup**, propagate on, added **twice**: once as a *User Permission* for `backup@pbs`
   and once as an *API Token Permission* for `backup@pbs!docker`. A token with privilege
   separation never gets more rights than its user, so giving only the token the role fails with
   `missing Datastore.Audit|Datastore.Backup`.
   DatastoreBackup can create backups and read its own, but not delete or prune any.
4. **Fingerprint.** *Dashboard → Show Fingerprint*.
5. **Retention.** *Datastore → Prune & GC Jobs → Add prune job*: namespace `docker`,
   max depth empty (all sub-namespaces), e.g. keep 14 daily, 8 weekly, 6 monthly.

### On each host

1. **Install the client.** On Debian, use Proxmox's `pbs-client` repo for your release. On
   Ubuntu, the regular package needs a newer glibc, so install the static build instead:
   ```bash
   sudo wget -qO /usr/share/keyrings/proxmox-release-bookworm.gpg https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
   echo "deb [signed-by=/usr/share/keyrings/proxmox-release-bookworm.gpg] http://download.proxmox.com/debian/pbs-client bookworm main" | sudo tee /etc/apt/sources.list.d/pbs-client.list
   sudo apt update && sudo apt install -y proxmox-backup-client-static
   ```
2. **Settings.** Create `/etc/pbs-docker-backup.env` (root, mode 600) from
   `examples/pbs-docker-backup.env.example`. Test it:
   ```bash
   sudo bash -c 'set -a; . /etc/pbs-docker-backup.env; proxmox-backup-client list --ns docker/$(hostname -s)'
   ```
   An empty list with no error means login, permissions and namespace are all fine.
3. **Install the script.** Copy `scripts/deploy.hosts.example` to `scripts/deploy.hosts`, list
   your hosts, then run `scripts/deploy.sh`. It installs `/usr/local/bin/pbs-docker-backup.sh`
   as root-owned. (Or copy it there by hand.)
4. **Mark apps.** Empty marker files in an app folder:
   - `touch <app>/.stopforbackup` for anything with a database or SQLite file (most *arr apps,
     Jellyfin, Home Assistant, Vaultwarden, Postgres/MariaDB). Copying those live risks a corrupt backup.
     It stops every container using the folder, not just the folder's own compose project: if a
     database keeps its data in `db/` but is defined in another app's compose file, marking `db/`
     stops (and restarts) that whole app.
   - `touch <app>/.nobackup` to skip a folder.
   - `<app>/.pxarexclude` to skip paths in one app (see `examples/jellyfin.pxarexclude`).
     `recordings`, `clips`, `transcodes`, `cache`, `logs` and `MediaCover` are skipped
     everywhere by default (`EXCLUDES` changes that).
5. **First run, by hand.** This runs a real backup; the first one uploads everything.
   ```bash
   sudo /usr/local/bin/pbs-docker-backup.sh
   ```
   It ends with `summary: N ok, 0 failed, M skipped`.
6. **Schedule it.** Copy `examples/pbs-docker-backup.cron` to `/etc/cron.d/pbs-docker-backup`.
   Give each host a different time.

### Restoring

**A few files:** PBS web UI → *Datastore → Content*, namespace `docker/<host>` → `host/<app>` →
snapshot → `<app>.pxar` → **File Browser** → Download.

**A whole app**, on its host:

```bash
sudo -i
set -a; . /etc/pbs-docker-backup.env; set +a
proxmox-backup-client snapshot list --ns docker/$(hostname -s)
cd /home/alice/docker && (cd sonarr && docker compose stop) && mv sonarr sonarr.before-restore
proxmox-backup-client restore --ns docker/$(hostname -s) "host/sonarr/<timestamp>" sonarr.pxar /home/alice/docker/sonarr
cd sonarr && docker compose up -d
```

Owners and permissions are restored as they were. For individual files on the host,
`proxmox-backup-client catalog shell …` gives an interactive `ls`/`cd`/`restore-selected`.

**A named volume:** stop the app, find the path with
`docker volume inspect <volume> --format '{{.Mountpoint}}'`, and restore `vol-<volume>.pxar` into it.

---

## 3. Backup alerts in Home Assistant

With `MQTT_*` set in `/etc/pbs-docker-backup.env` (and `apt install mosquitto-clients`), each
host gets a device **Docker backup &lt;host&gt;** via MQTT discovery:

- `sensor.docker_backup_<host>_status`: `running`, `ok` or `failed`, with attributes for the last run
  (duration, apps ok, failed and skipped);
- `sensor.docker_backup_<host>_last_success`: timestamp.

A failed run also sends a one-off event on `pbs-docker-backup/<host>/event`.

Add `home-assistant/docker-backup-alerts.yaml` as an automation (*Edit in YAML*) and set your
notify service. It covers every host automatically:

- **failed:** a run reported failures (which apps, or the error);
- **overdue:** at 08:00, any host without a successful backup in 26 hours, which catches hosts
  that were down, a missing cron entry, or a script that hung.

---

## Housekeeping: finding unused app folders

```bash
sudo scripts/docker-audit.sh ~/docker
```

Lists each folder as RUNNING, STOPPED or UNUSED, with size and last activity, plus containers
whose folder no longer exists. It matches folders to containers by compose working directory,
compose file and mounts, so renamed projects and plain `docker run` containers are recognised.
It only knows about Docker: a folder used by a native service (systemd, cron) shows as UNUSED.
Move folders aside (`mv app ~/old-docker/`) rather than deleting them.

---

## Gotchas

- **Running the backup script by hand runs a full backup.** To see what the nightly run did,
  read `journalctl -t pbs-docker-backup`.
- **`COMPOSE_FILE` in updates2mqtt's `.env`.** Don't pass the `.env` into the container with
  `env_file:`; the variable follows into every `docker compose` it runs, which then looks for
  `<app>/updates2mqtt.yml` and the update fails. The example compose file avoids this.
- **`unknown shorthand flag: 'd' in -d`** means the host has only the old `docker-compose` v1.
  Install `docker-compose-plugin` (Docker's repo) or `docker-compose-v2` (Ubuntu's).
- **Bundled Watchtower.** Some projects (e.g. Scrypted's default compose file) ship a Watchtower
  service that auto-updates. Remove it if you want updates to be manual only.
- **zsh and `!`.** zsh expands `!` even inside double quotes, so PBS token names
  (`user@pbs!token`) need single quotes in commands.
- **Can't update updates2mqtt from HA.** It would stop itself mid-update. Update it by hand:
  `docker compose pull && docker compose up -d` in its folder.
- **No backup right before an update.** updates2mqtt has no pre-update hook and HA's Install
  button can't be intercepted; the most recent nightly backup is what you roll back to.

## License

MIT, see [LICENSE](LICENSE).
