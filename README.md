# Proxmox Backup Server on a Mini PC

A dedicated **Proxmox Backup Server 4** on a Lenovo ThinkCentre M700 Tiny with a USB hard drive as the datastore. It backs up every VM and container in the [Proxmox cluster](https://github.com/nashibbhattrai766-max/proxmox-cluster) nightly, plus the NAS photo library, and doubles as the cluster's **QDevice** tie-breaker and the **secondary DNS** server.

Before this, backups were full `vzdump` copies to a USB SSD over NFS. They took hours, loaded the hypervisor heavily, and contributed to a node crash. PBS backs up only changed blocks: **the whole nightly run now takes about 12 minutes.**

```
 pve1 / pve2 ── nightly 02:00 (changed blocks only) ──►  PBS  ──►  USB HDD datastore
 NAS photos ── nightly 03:30 (proxmox-backup-client) ──►   │        prune 05:00 · GC 06:00 · verify Sun 07:00
                                                           ├── corosync-qnetd (cluster tie-breaker vote)
                                                           └── Pi-hole 2 + Unbound (Docker)
```

## What's in here

| Path | What it does |
|---|---|
| [`scripts/setup-pbs-jobs.sh`](scripts/setup-pbs-jobs.sh) | Prune / garbage-collection / verify jobs, backup-only users and permissions |
| [`scripts/pbs-monitoring-setup.sh`](scripts/pbs-monitoring-setup.sh) | Installs Zabbix agent 2 + node-exporter and a collector that publishes PBS health as metrics every 5 minutes (last backup per group, failed verifications, failed tasks, QDevice/DNS/containers up) |

## Build notes

### 1. Hardware and install
- ThinkCentre M700 Tiny (i5-6500T, 16 GB RAM), 128 GB SATA SSD for the OS.
- Installed from the PBS 4 ISO using **Ventoy**. The boot menu didn't show the USB stick until **Boot Priority was set to UEFI** in the BIOS.
- Static IP and hostname set in the installer; everything else from the web UI on port 8007.

### 2. USB datastore drive
Some Seagate USB enclosures misbehave with the UAS driver (resets and I/O errors under load). Force the plain usb-storage driver for that one device:

```bash
lsusb                                  # find the ID, e.g. 0bc2:2036
echo "options usb-storage quirks=0bc2:2036:u" > /etc/modprobe.d/usb-hdd-no-uas.conf
update-initramfs -u && reboot
```

Then create the datastore: `Administration > Storage / Disks > Directory`, filesystem ext4, "Add as datastore".

### 3. Jobs, users, permissions
Run [`scripts/setup-pbs-jobs.sh`](scripts/setup-pbs-jobs.sh). It creates:

| Job | When | What |
|---|---|---|
| Prune | daily 05:00 | keep 7 daily, 4 weekly, 6 monthly |
| Garbage collection | daily 06:00 | actually frees the pruned space |
| Verify | Sun 07:00 | checks new backups; re-checks anything last verified > 30 days ago |

Two users, each with only **DatastoreBackup** rights: `pve@pbs` for the Proxmox nodes and `nas@pbs` for the NAS. A compromised client can add backups but can't delete or read anyone else's.

### 4. Connect Proxmox VE
`Datacenter > Storage > Add > Proxmox Backup Server`: server, datastore, `pve@pbs` + password, and the **fingerprint** printed by the setup script. Then create the backup jobs under `Datacenter > Backup` (mode *snapshot*).

### 5. Monitoring
`scripts/pbs-monitoring-setup.sh` writes `/var/lib/prometheus/node-exporter/pbs.prom`. Prometheus scrapes it through node-exporter, and Zabbix reads the same file with `vfs.file.contents` and dependent items. Alerts fire when a group hasn't backed up in 26 h, a verification fails, a task fails, or the QDevice/DNS stops.

> Debian's node-exporter excludes `/mnt` from filesystem metrics by default. To see the datastore's free space, override the mount-point exclude in `/etc/default/prometheus-node-exporter`.

### 6. Docker on PBS (for Pi-hole 2)
PBS is plain Debian underneath, so `apt install docker.io` works. On the Proxmox kernel, containers can fail with `setpriv: initgroups failed` because of AppArmor. Run them with `--security-opt apparmor=unconfined`.

## Lessons learned

- **The first backup after a VM is fully stopped and started reads the whole disk** (the change-tracking bitmap is lost). Expect one slow night after maintenance.
- **"Verify State: None" is normal** for new backups until the weekly verify job runs.
- **`Verify All` on a USB disk is slow** and triggers disk-latency alerts. Let the scheduled job do it.
- **Prune doesn't free space; garbage collection does.** Schedule GC after prune.

## License

MIT
