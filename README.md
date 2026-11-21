# Proxmox Backup Server on a Mini PC

A dedicated **Proxmox Backup Server (PBS) 4** built on a second-hand Lenovo ThinkCentre M700 Tiny with a USB hard drive as the datastore. It backs up every VM and container in my [Proxmox cluster](https://github.com/nashibbhattrai766-max/proxmox-cluster) every night, plus the NAS photo library, and it also runs the cluster's **QDevice** tie-breaker and the **secondary DNS server**.

**Result:** the nightly backup of all 8 guests went from long full-copy runs that loaded the hypervisor heavily to **about 12 minutes**, every backup is verified weekly, and old backups are cleaned up automatically.

---

## Contents
1. [Why I built it](#1-why-i-built-it)
2. [Design](#2-design)
3. [What you need](#3-what-you-need)
4. [Build: install PBS](#4-build-install-pbs)
5. [Build: the USB datastore](#5-build-the-usb-datastore)
6. [Build: users and permissions](#6-build-users-and-permissions)
7. [Build: connect Proxmox VE and schedule backups](#7-build-connect-proxmox-ve-and-schedule-backups)
8. [Build: retention, cleanup and verification](#8-build-retention-cleanup-and-verification)
9. [Build: extra roles (QDevice, DNS)](#9-build-extra-roles-qdevice-dns)
10. [Build: monitoring and alerts](#10-build-monitoring-and-alerts)
11. [Verify it works](#11-verify-it-works)
12. [Running it day to day](#12-running-it-day-to-day)
13. [Troubleshooting and lessons learned](#13-troubleshooting-and-lessons-learned)
14. [What I'd add next](#14-what-id-add-next)

---

## 1. Why I built it

**Before**, each Proxmox node ran `vzdump` jobs that wrote **full compressed copies** of every VM to a USB SSD, shared between the nodes over NFS.

Problems with that:
- **Every backup was a full copy.** A 120 GB NAS VM was read and written in full every night.
- **Heavy load on the hypervisor.** One node crashed during a backup window (a kernel general-protection fault), and the backup load was the main suspect.
- **One USB disk on one node, shared over NFS.** If that node was down, the other node couldn't back up, and the NFS share became another thing to break.
- **No verification.** Nothing checked that a backup could actually be restored.
- **No retention policy** beyond "delete old files by hand".

**What I wanted:** incremental, deduplicated backups on a separate machine, automatic retention, scheduled verification, alerts when something is wrong, and no extra money spent (reuse a spare mini PC and the existing USB drive).

## 2. Design

```
 ┌──────────── Proxmox VE cluster ────────────┐
 │ pve1  (NAS VM, Zabbix, Pi-hole 1, apps)     │──┐  nightly 02:00
 │ pve2  (Home Assistant, Grafana, PDM, apps)  │──┤  changed blocks only
 └─────────────────────────────────────────────┘  │
 NAS (ZimaOS) photo library ── nightly 03:30 ─────┤  proxmox-backup-client
                                                  ▼
                        ┌──────── PBS (ThinkCentre M700 Tiny) ────────┐
                        │ datastore "backups" on USB HDD (ext4)        │
                        │   prune 05:00 → GC 06:00 → verify Sun 07:00  │
                        │ corosync-qnetd  (3rd cluster vote)           │
                        │ Pi-hole 2 + Unbound (Docker)                 │
                        │ node-exporter + Zabbix agent → monitoring    │
                        └──────────────────────────────────────────────┘
```

Key decisions:

| Decision | Why |
|---|---|
| **Separate physical box** (not a VM on the cluster) | Backups must survive the cluster failing. Restoring a dead cluster from a VM that lived on it doesn't work. |
| **PBS instead of vzdump files** | Block-level incremental backups using dirty bitmaps, deduplication across all guests, built-in verify/prune/GC, single-file restore. |
| **USB HDD as the datastore** | Already owned, no spending. Fine for a homelab at this scale; the trade-off is speed (see lessons learned). |
| **Use the same box as QDevice** | A two-node cluster needs a third vote to survive a node failure. PBS is always on and outside the cluster, which makes it ideal. |
| **One backup user per client** | `pve@pbs` for the cluster and `nas@pbs` for the NAS, each only allowed to *add* backups. A compromised client can't delete the backups. |

## 3. What you need

| Item | Used here |
|---|---|
| Mini PC | Lenovo ThinkCentre M700 Tiny, i5-6500T, **16 GB RAM** (8 GB + an extra 8 GB stick) |
| OS disk | 128 GB 2.5" SATA SSD |
| Datastore | Seagate USB 3 external HDD |
| Software | Proxmox Backup Server 4.x ISO, a USB stick with [Ventoy](https://www.ventoy.net) |
| Network | Static IP in the LAN (here `10.0.0.20`), same network as the Proxmox nodes |

> **Sizing tip:** PBS deduplicates, so the datastore only needs to be a bit bigger than the *used* space of your guests plus growth. My 8 guests and a 77 GB photo library use about 100 GB.

## 4. Build: install PBS

1. **Prepare the USB stick.** Copy the PBS ISO onto a Ventoy stick.
2. **BIOS.** Press F1 at boot. Under *Startup*, set **Boot Priority = UEFI First** (or UEFI only).
   > The F12 boot menu didn't show the USB stick at all until this was changed from legacy mode.
3. **Boot the installer** (F12 → USB → PBS ISO) and choose the graphical install.
4. **Target disk:** the SATA SSD (ext4 is fine).
5. **Network:** management interface, a **static IP** (`10.0.0.20/24`), gateway, DNS, and an FQDN such as `pbs.home.arpa`.
6. Reboot, remove the stick, and browse to `https://10.0.0.20:8007`. Log in as `root` (realm *Linux PAM*).
7. **Repositories:** *Administration → Repositories*. Without a subscription, disable `pbs-enterprise`, add **No-Subscription**, then *Updates → Refresh → Upgrade*.

## 5. Build: the USB datastore

1. **Plug in the USB drive** and check that it's detected:
   ```bash
   lsblk -o NAME,SIZE,MODEL
   lsusb                       # note the drive's ID, e.g. 0bc2:2036
   ```
2. **UAS fix (only if you see resets or I/O errors).** Some Seagate enclosures are unstable with the fast UAS driver under sustained load. Forcing the plain `usb-storage` driver for that device fixes it:
   ```bash
   echo "options usb-storage quirks=0bc2:2036:u" > /etc/modprobe.d/usb-hdd-no-uas.conf
   update-initramfs -u && reboot
   lsusb -t                    # the drive should now show Driver=usb-storage, not uas
   ```
3. **Create the datastore:** *Administration → Storage / Disks*. Select the USB disk → **Wipe Disk**, then *Directory → Create: Directory*: filesystem **ext4**, name `backups`, tick **Add as Datastore**.
   This formats the disk, mounts it at `/mnt/datastore/backups` and adds a systemd mount unit, so it comes back after reboots.

## 6. Build: users and permissions

Run [`scripts/setup-pbs-jobs.sh`](scripts/setup-pbs-jobs.sh), or by hand:

```bash
proxmox-backup-manager user create pve@pbs --password '<strong password>'
proxmox-backup-manager user create nas@pbs --password '<strong password>'
proxmox-backup-manager acl update /datastore/backups DatastoreBackup --auth-id pve@pbs
proxmox-backup-manager acl update /datastore/backups DatastoreBackup --auth-id nas@pbs
proxmox-backup-manager cert info | grep -i fingerprint      # needed in the next step
```

**DatastoreBackup** lets a user create backups and read *its own* backups, and nothing else. It can't prune, delete or see the other user's backups.

## 7. Build: connect Proxmox VE and schedule backups

**Add PBS as storage** (on any cluster node, it applies cluster-wide): *Datacenter → Storage → Add → Proxmox Backup Server*:

| Field | Value |
|---|---|
| ID | `pbs` |
| Server | `10.0.0.20` |
| Username | `pve@pbs` |
| Password | the one from step 6 |
| Datastore | `backups` |
| Fingerprint | from `cert info` |

It should show as *active* on both nodes, and its usage appears in the tree.

**Backup jobs:** *Datacenter → Backup → Add*:

| Job | Schedule | Selection | Mode |
|---|---|---|---|
| Nightly | `02:00` | **All**, *exclude* the lab VMs | Snapshot |
| Weekly (lab) | `sun 03:00` | only the lab VMs | Snapshot |

Leave retention **empty** in the job. Retention is handled centrally by the PBS prune job (step 8), so there's only one policy to maintain.

**Run the first backup by hand** (*Backup → select job → Run now*). The first run is a full copy and takes a while; every run after that only sends changed blocks.

## 8. Build: retention, cleanup and verification

These three jobs keep the datastore healthy without anyone touching it. The script in step 6 creates them:

| Job | Schedule | Setting | What it does |
|---|---|---|---|
| **Prune** | daily 05:00 | keep-daily 7, keep-weekly 4, keep-monthly 6 | Decides which backups to keep: one per day for a week, one per week for a month, one per month for half a year. Marks the rest for removal. |
| **Garbage collection** | daily 06:00 | — | Actually frees the disk space of chunks no longer used by any remaining backup. **Prune alone frees nothing.** |
| **Verify** | Sun 07:00 | skip verified, re-verify after 30 days | Reads every chunk and checks its checksum. New backups are checked within a week, and older ones are re-checked monthly to catch bit rot on the disk. |

In the GUI these are under *Datastore → backups → Prune & GC Jobs* and *Verify Jobs*.

## 9. Build: extra roles (QDevice, DNS)

PBS is always on and outside the cluster, which makes it a good home for two small extra jobs.

**QDevice (cluster tie-breaker):**
```bash
# on PBS
apt install corosync-qnetd
# on both Proxmox nodes
apt install corosync-qdevice
# on one Proxmox node
pvecm qdevice setup 10.0.0.20
pvecm status          # Expected votes: 3, Total votes: 3, "Qdevice" listed
```
Now either Proxmox node can go down and the other keeps quorum.

**Docker for the secondary Pi-hole:** `apt install docker.io`. On the Proxmox kernel, containers need `--security-opt apparmor=unconfined`. The full DNS setup is in [pihole-ha-dns](https://github.com/nashibbhattrai766-max/pihole-ha-dns).

**Photo library backups from the NAS** use `proxmox-backup-client` in a small container on the NAS, with the `nas@pbs` user. See [immich-pbs-backup](https://github.com/nashibbhattrai766-max/immich-pbs-backup).

## 10. Build: monitoring and alerts

Run [`scripts/pbs-monitoring-setup.sh`](scripts/pbs-monitoring-setup.sh) on PBS. It:
1. installs **node-exporter** (CPU, RAM, disk metrics for Prometheus/Grafana) and **Zabbix agent 2**;
2. installs `/usr/local/bin/pbs-status.sh`, run from cron every 5 minutes, which asks the PBS API for:
   - the last backup time of every backup group (`pbs_group_last_backup_seconds`)
   - the number of failed and OK verifications
   - failed tasks in the last 24 h
   - whether `corosync-qnetd`, Unbound, the Pi-hole container and the sync container are running

   and writes them to `/var/lib/prometheus/node-exporter/pbs.prom`.

**Prometheus** scrapes that file through node-exporter. **Zabbix** reads the same file with one `vfs.file.contents` item and splits it into separate values using dependent items with JavaScript preprocessing ([zabbix-pbs.sh](https://github.com/nashibbhattrai766-max/zabbix-monitoring)).

Alerts sent to my phone:
| Alert | Condition |
|---|---|
| Photo library not backed up | last backup > 26 h ago |
| Backup failed verification | any failed verify (High) |
| A PBS task failed | in the last 24 h |
| QDevice down | qnetd not running (High) |
| Status collector stopped | metrics file older than 20 min |

The Grafana **Backups** screen shows "✓ ALL BACKED UP · VERIFIED", or a warning, plus the age of every guest's last backup ([grafana-rack-dashboards](https://github.com/nashibbhattrai766-max/grafana-rack-dashboards)).

> Debian's node-exporter excludes `/mnt` from filesystem metrics by default. Override `--collector.filesystem.mount-points-exclude` in `/etc/default/prometheus-node-exporter` to see the datastore's free space.

## 11. Verify it works

| Check | How | Expected |
|---|---|---|
| Backups ran | *Datastore → Content* | one new snapshot per guest each night |
| Speed | PVE task log of the nightly job | minutes, not hours (after the first run) |
| Verification | *Datastore → Content → Verify State* | ✓ ok after Sunday's job |
| Retention | snapshot count per guest | grows to 7 dailies, then stays steady |
| QDevice | `pvecm status` | 3 of 3 votes |
| **Restore** | *Datastore → Content → snapshot → File Restore*, or restore a VM to a **new VMID** on a node | files open, VM boots |

> **Test a restore.** A backup you've never restored is a hope, not a backup. Restoring a small container to a new ID every few months takes five minutes.

## 12. Running it day to day

- **Nothing to do** in normal operation: backups, prune, GC and verify all run on schedule, and alerts arrive if something fails.
- **Updates:** *Administration → Updates* monthly (or from [Proxmox Datacenter Manager](https://github.com/nashibbhattrai766-max/proxmox-datacenter-manager)).
- **Space:** keep the datastore under ~80 %. GC needs headroom.
- **After maintenance** that fully stops and starts a VM, expect that VM's next backup to take longer (see below).

## 13. Troubleshooting and lessons learned

- **The first backup after a VM is fully stopped and started reads the whole disk.** PBS's speed comes from QEMU *dirty bitmaps* that track changed blocks. They live in memory and are lost when the VM process stops (a reboot inside the guest keeps them). After changing a VM's RAM or enabling its guest agent, its next backup was a full read, and the node's load alerts fired at 2 am for that one night.
- **"Verify State: None" is normal** for new backups until the weekly verify job runs.
- **`Verify All` on a USB disk is slow.** Clicking it reads every backup and triggered PBS disk-latency alerts (> 20 ms for 15 min). Let the scheduled job do it.
- **Prune doesn't free space; garbage collection does.** Always schedule GC after prune.
- **Retire old backup targets completely.** When I moved off the old NFS backup share, the share stayed mounted on both nodes. The NFS client hung for days and pushed the load average to 10–12 with an idle CPU. Remove the storage entry, unmount with `umount -l -c`, and clear `/etc/fstab`.
- **Docker on the PBS host** needed `apparmor=unconfined`, and Unbound's AppArmor profile had to be disabled on this kernel.
- **USB stick not in the boot menu** → switch the BIOS boot priority to UEFI.

## 14. What I'd add next

- **An off-site copy** (3-2-1 rule): a PBS *sync job* to a second PBS at another location, or a cloud S3 datastore. At the moment everything is in one house.
- **Client-side encryption** for any off-site copy.
- **A UPS**, so a power cut doesn't interrupt a backup or garbage collection mid-run.
- **Scheduled restore tests.**

## Files in this repo

| File | Purpose |
|---|---|
| [`scripts/setup-pbs-jobs.sh`](scripts/setup-pbs-jobs.sh) | Prune/GC/verify jobs, backup users, permissions, fingerprint |
| [`scripts/pbs-monitoring-setup.sh`](scripts/pbs-monitoring-setup.sh) | node-exporter, Zabbix agent 2 and the PBS status collector |

## License

MIT
