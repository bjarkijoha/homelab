# homelab

Docker Compose configuration for my self-hosted home server: a media stack with
automated library management, a VPN-isolated download pipeline, photo backup,
network-wide ad blocking, and a Cloudflare Tunnel that lets friends request
media through Seerr.

The server runs headless Debian 13 with Docker. Every service is its own
Compose stack, secrets live in per-stack `.env` files that are never committed,
and a weekly cron job keeps the OS and all containers up to date.

## Services

| Stack | Service | Port | Purpose |
| --- | --- | --- | --- |
| `plex` | Plex | 32400 | Media server for movies and TV |
| `radarr` | Radarr | 7878 | Movie library management |
| `sonarr` | Sonarr | 8989 | TV library management |
| `overseerr` | Seerr | 5055 | Media requests for users |
| `gluetun` | Gluetun | — | WireGuard VPN gateway (NordVPN) |
| `gluetun` | Prowlarr | 9696 | Indexer manager, routed through the VPN |
| `gluetun` | Transmission | 9091 | Torrent client, routed through the VPN |
| `gluetun` | FlareSolverr | 8191 | Cloudflare challenge solver for indexers, routed through the VPN |
| `immich` | Immich | 2283 | Photo and video backup (with Postgres and Redis) |
| `workstation/immich-ml` | Immich ML | 3003 | Face recognition and smart search, run on the desktop workstation's GPU |
| `pihole` | Pi-hole | 80, 53 | Network-wide DNS ad blocking |
| `homepage` | Homepage | 3000 | Dashboard for all services |
| `cloudflared` | Cloudflare Tunnel | — | Exposes Seerr to friends without opening ports |
| `samba` | Samba | 445 | Network share for the workstation's video files (Linux and Windows) |

## Architecture

```mermaid
flowchart LR
    internet((Internet))
    cf[Cloudflare Edge]
    vpn[(NordVPN<br/>WireGuard)]

    subgraph server[Home server]
        cloudflared
        subgraph vpnns[Gluetun network namespace]
            gluetun[Gluetun]
            prowlarr[Prowlarr]
            transmission[Transmission]
            flaresolverr[FlareSolverr]
        end
        radarr[Radarr]
        sonarr[Sonarr]
        seerr[Seerr]
        plex[Plex]
        immich[Immich]
        pihole[Pi-hole]
        homepage[Homepage]
        samba[Samba]
    end

    subgraph storage[Storage]
        zfs[(ZFS mirror<br/>/storage)]
        media[(Media disk<br/>/home/plexy/Media)]
    end

    internet --> cf -->|outbound tunnel| cloudflared
    cloudflared --> seerr
    gluetun --> vpn --> internet
    seerr --> radarr & sonarr
    radarr & sonarr --> prowlarr
    radarr & sonarr --> transmission
    prowlarr --> flaresolverr
    radarr --> media & zfs
    sonarr --> zfs
    transmission --> media
    plex --> media & zfs
    immich --> zfs
    samba --> zfs
```

### Request and download flow

1. A user requests a movie or show in **Seerr**, which hands it to **Radarr**
   (movies) or **Sonarr** (TV).
2. Radarr/Sonarr search through **Prowlarr**, which queries the indexers and
   uses **FlareSolverr** for sites behind Cloudflare challenges.
3. The chosen release is sent to **Transmission**, which downloads it into
   `Pending`.
4. Radarr/Sonarr import the finished download into the library, and **Plex**
   picks it up.

### Network isolation

Prowlarr, Transmission and FlareSolverr use `network_mode: service:gluetun`.
They share Gluetun's network stack, so all of their traffic leaves through the
WireGuard tunnel. If the VPN drops, they have no route to the internet: there
is no fallback to the home connection. Their web UIs are published through
Gluetun's port mappings, and `FIREWALL_OUTBOUND_SUBNETS` allows them to reach
the LAN.

Plex, Seerr and Pi-hole use host networking. Plex needs it for local discovery,
and Pi-hole needs it to serve DNS on port 53 for the whole network.

### Immich machine learning

The server's CPU has no AVX, which Immich's machine learning needs, so face
recognition and smart search run on the desktop workstation instead
(`workstation/immich-ml`, ROCm on a Radeon RX 7700/7800 XT). The Immich server
sends it thumbnails over the LAN via `IMMICH_MACHINE_LEARNING_URL`; nothing
leaves the network. The stack sits under `workstation/` so `update.sh` on the
server skips it. When the workstation is off, ML jobs wait: run the Face
Detection and Smart Search jobs on "Missing" afterwards. After the server
updates Immich, pull the ML image on the workstation too so versions match.

### External access

Friends who have access to the Plex library request new movies and shows
through Seerr, so Seerr is the one service published to the internet.
`cloudflared` opens an outbound tunnel to Cloudflare, and a public hostname in
the Cloudflare Zero Trust dashboard routes to Seerr on port 5055. No inbound
port needs to be opened for it. Users sign in to Seerr with their Plex account.

Everything else, including the admin tools (Radarr, Sonarr, Prowlarr,
Transmission, Homepage, Pi-hole) and the Samba share, is only reachable on the
local network.

### Storage

| Path | Backing | Contents |
| --- | --- | --- |
| `/storage/shows` | ZFS mirror dataset | TV shows |
| `/storage/photos` | ZFS mirror dataset | Immich library |
| `/storage/movies` | ZFS mirror dataset | Movie overflow |
| `/storage/videos` | ZFS mirror dataset | Workstation videos, shared over SMB |
| `/home/plexy/Media` | Single ext4 disk | Movies, other libraries, `Pending` downloads |
| `/opt/docker/<service>` | OS SSD | Application config and databases |

The ZFS pool `storage` is a two-disk mirror, so the main libraries survive a
single drive failure. Application state lives in `/opt/docker` and is **not**
part of this repository. Back it up separately.

## Repository layout

```
.
├── <stack>/
│   ├── docker-compose.yml
│   └── .env.example        # required variables; copy to .env
├── scripts/
│   ├── update.sh                   # weekly OS + container update
│   ├── homelab-update.cron         # cron schedule (Tuesdays 03:00)
│   ├── homelab-update.logrotate    # log rotation for update.sh and backup.sh
│   ├── backup.sh                   # nightly app data backup
│   ├── homelab-backup.cron         # cron schedule (daily 04:30)
│   └── docker-zfs.conf             # systemd drop-in: Docker waits for ZFS
└── README.md
```

## Installation

### 1. Base system

Install Debian 13 and log in as a user with UID/GID 1000 (the stacks use
`PUID=1000`/`PGID=1000`). This repo assumes the user is `plexy`. If yours is
different, update the `/home/plexy` paths in the compose files and in
`scripts/homelab-update.cron`.

Install Docker Engine with the Compose plugin
([docs](https://docs.docker.com/engine/install/debian/)), then:

```bash
sudo usermod -aG docker $USER
```

### 2. Storage

Install ZFS (needs the `contrib` component enabled in APT sources) and create
the mirrored pool and datasets:

```bash
sudo apt install linux-headers-amd64 zfs-dkms zfsutils-linux

# Use stable /dev/disk/by-id paths, not /dev/sdX
sudo zpool create -o ashift=12 storage mirror \
    /dev/disk/by-id/<disk-1> /dev/disk/by-id/<disk-2>
sudo zfs create storage/shows
sudo zfs create storage/photos
sudo zfs create storage/movies
sudo zfs create storage/videos
sudo chown -R 1000:1000 /storage/shows /storage/photos /storage/movies /storage/videos
```

Make Docker wait for the ZFS datasets at boot so containers never start
against empty mount points. Run this from the cloned repo (step 3), or come
back to it after cloning:

```bash
sudo install -Dm644 scripts/docker-zfs.conf \
    /etc/systemd/system/docker.service.d/override.conf
sudo systemctl daemon-reload
```

The drop-in checks that each dataset is really mounted
(`AssertPathIsMountPoint=`) when Docker is about to start. Depending on
`zfs-mount.service` isn't enough, because it reports success even when the
pool failed to import. `RequiresMountsFor=` doesn't work either: ZFS mounts
have no fstab entry, so systemd only orders after them and silently drops the
dependency when they don't exist. After a power cut the HBA once failed to
initialise, the pool didn't import, and Docker started every container against
empty `/storage` folders on the OS SSD. Now a missing dataset makes Docker
fail to start (`systemctl status docker` shows the failed assertion). Fix the
pool (`sudo zpool import storage && sudo zfs mount -a`), then run
`sudo systemctl start docker`.

Create the media folders on the media disk:

```bash
mkdir -p ~/Media/{Movies,Pending,Skrípó,Teiknimyndir,Skripo}
sudo mkdir -p /opt/docker && sudo chown 1000:1000 /opt/docker
```

### 3. Clone and configure

```bash
git clone https://github.com/bjarkijoha/homelab.git ~/docker
cd ~/docker

# Create a .env for every stack that needs one, then fill in real values
for f in */.env.example; do cp -n "$f" "${f%.example}"; done
chmod 600 */.env
```

| Stack | Variables |
| --- | --- |
| `gluetun` | `WIREGUARD_PRIVATE_KEY` (from your NordVPN WireGuard credentials), `TRANSMISSION_USER`, `TRANSMISSION_PASS` |
| `cloudflared` | `TUNNEL_TOKEN` (Zero Trust → Networks → Tunnels → create tunnel) |
| `immich` | `DB_PASSWORD` and the other database settings |
| `pihole` | `PIHOLE_PASSWORD` (admin password; Pi-hole won't start if it's empty) |
| `samba` | `SAMBA_PASSWORD` (password for the `plexy` share user) |

If you are restoring an existing server, restore `/opt/docker` from backup
**before** starting the stacks so every service comes back with its settings
(see [Restoring from a backup](#restoring-from-a-backup)).

### 4. Start the stacks

Start Pi-hole first (DNS), then the VPN stack, then everything else:

```bash
cd ~/docker
for stack in pihole gluetun plex radarr sonarr overseerr immich homepage cloudflared; do
    docker compose -f "$stack/docker-compose.yml" up -d
done
```

Check that the VPN is up and download traffic leaves through it:

```bash
docker logs gluetun | grep -i "public ip"
```

### 5. Connect the services

On a fresh install, wire the apps together in their web UIs:

- **Prowlarr**: add indexers and FlareSolverr (`http://localhost:8191`, since it
  shares Prowlarr's network namespace), then add Radarr and Sonarr as apps.
- **Radarr / Sonarr**: add Transmission as the download client (host
  `192.168.1.110`, port `9091`). Set root folders (`/movies`, `/movies-overflow`,
  `/shows`).
- **Seerr**: sign in with Plex and connect Radarr and Sonarr.
- **Plex**: add the libraries from `/Movies`, `/Shows` and the other mounted folders.
- **Cloudflare**: in the tunnel's settings, add a public hostname that points to
  Seerr (`http://192.168.1.110:5055`).

### Video share

The `samba` stack shares `/storage/videos` as `\\192.168.1.110\videos`, with
the user `plexy` and `SAMBA_PASSWORD` from `samba/.env`. The workstation dual
boots, and both installs use the same share. Files are owned by `plexy`
(UID 1000) on the server, whichever client wrote them.

**Linux** (needs `cifs-utils`). Store the credentials where only root can read
them, then add an automount to `/etc/fstab`:

```bash
sudo install -d -m 700 /etc/samba/credentials
printf 'username=plexy\npassword=<SAMBA_PASSWORD>\n' | sudo tee /etc/samba/credentials/plexy >/dev/null
sudo chmod 600 /etc/samba/credentials/plexy
sudo mkdir -p /mnt/videos
```

```
//192.168.1.110/videos  /mnt/videos  cifs  credentials=/etc/samba/credentials/plexy,uid=1000,gid=1000,file_mode=0664,dir_mode=0775,vers=3.1.1,_netdev,nofail,noauto,x-systemd.automount,x-systemd.mount-timeout=10  0  0
```

```bash
sudo systemctl daemon-reload && sudo systemctl restart remote-fs.target
```

The share mounts the first time something opens `/mnt/videos`, so boot
doesn't wait for the server, and a server that's down doesn't hang the
desktop.

**Windows**: File Explorer → This PC → **Map network drive**, folder
`\\192.168.1.110\videos`, tick **Reconnect at sign-in** and **Connect using
different credentials**, then sign in as `plexy` and tick **Remember my
credentials**. Or from a terminal:

```powershell
net use V: \\192.168.1.110\videos /user:plexy /persistent:yes
```

Record and edit locally, then move finished files to the share: over gigabit
it tops out around 110 MB/s, and a network drop mid-recording can corrupt the
file.

### 6. Automatic updates

`scripts/update.sh` upgrades OS packages, installs matching kernel headers,
and checks that the ZFS kernel module is built for the newest kernel, so the
pool will import after a reboot. It then
pulls new images for every stack, recreates changed containers, prunes old
images, and reboots if the update requires it. The reboot is skipped if the ZFS
module is missing.

```bash
sudo cp scripts/homelab-update.cron /etc/cron.d/homelab-update
sudo cp scripts/homelab-update.logrotate /etc/logrotate.d/homelab-update
```

It runs every Tuesday at 03:00 and logs to `/var/log/homelab-update.log`. To
run it by hand without rebooting:

```bash
sudo ~/docker/scripts/update.sh --no-reboot
```

### 7. Backups

`scripts/backup.sh` backs up everything the apps can't rebuild on their own:
settings and databases from `/opt/docker`, plus each stack's `.env` file.
Caches, logs, artwork and thumbnails are skipped. Each backup is a single
`homelab-YYYY-MM-DD.tar.zst` archive of about 400 MB in `/storage/backups`.

- The Immich database is exported with `pg_dumpall`, and Pi-hole's settings with
  its Teleporter export, so neither service stops.
- Plex, Radarr, Sonarr, Prowlarr and Seerr keep their data in SQLite. They are
  stopped for the minute it takes to archive them, so the databases are
  consistent, and then started again.
- The script keeps 7 daily backups and 4 weekly ones (from Sundays).
- If the ZFS pool isn't mounted, it aborts rather than writing to the OS disk.

```bash
sudo zfs create storage/backups
sudo cp scripts/homelab-backup.cron /etc/cron.d/homelab-backup
```

It runs every day at 04:30 and logs to `/var/log/homelab-backup.log`. The
archives contain secrets, so they're readable by root only.

The backups sit on the same server as the data, so they protect against the OS
disk failing or a bad change, not against losing the whole machine. Copy them
off the server for that.

#### Restoring from a backup

```bash
cd /tmp && sudo tar --zstd -xf /storage/backups/daily/homelab-<date>.tar.zst

# App data and secrets
sudo cp -a opt/docker /opt/
sudo cp -r env/. ~/docker/ && sudo chown -R "$USER": ~/docker

# Immich database: start only the database, then load the export
docker compose -f ~/docker/immich/docker-compose.yml up -d database
zstd -dc immich-db.sql.zst | docker exec -i immich-postgres sh -c 'psql -U "$POSTGRES_USER" -d postgres'
```

Then start the stacks as in step 4. Import `pihole-teleporter.zip` in Pi-hole's
web UI under **Settings → Teleporter**.
