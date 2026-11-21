#!/bin/bash
# Creates the datastore maintenance jobs, backup users and permissions on Proxmox Backup Server.
# Run as root on PBS after the datastore exists. Safe to re-run (existing items are skipped).
set -u
DS=${DS:-backups}                 # datastore name

echo "== maintenance jobs =="
# keep 7 daily, 4 weekly, 6 monthly backups of every guest
proxmox-backup-manager prune-job create daily-prune --store "$DS" --schedule '05:00' \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 2>/dev/null && echo "+ prune 05:00" || echo "= prune job exists"
# free the space pruned backups used (runs after prune)
proxmox-backup-manager datastore update "$DS" --gc-schedule '06:00' && echo "+ garbage collection 06:00"
# weekly integrity check: new backups every Sunday, older ones re-checked after 30 days
proxmox-backup-manager verify-job create weekly-verify --store "$DS" --schedule 'sun 07:00' \
  --ignore-verified true --outdated-after 30 2>/dev/null && echo "+ verify Sun 07:00" || echo "= verify job exists"

echo "== users (one per client, backup-only rights) =="
for U in pve nas; do
  if ! proxmox-backup-manager user list --output-format json | grep -q "\"$U@pbs\""; then
    read -r -s -p "Password for $U@pbs: " P; echo
    proxmox-backup-manager user create "$U@pbs" --password "$P" && echo "+ $U@pbs"
  fi
  # DatastoreBackup = can create backups and read its own, can't delete or see others'
  proxmox-backup-manager acl update "/datastore/$DS" DatastoreBackup --auth-id "$U@pbs"
done

echo "== fingerprint (Proxmox VE needs this when adding the storage) =="
proxmox-backup-manager cert info | grep -i fingerprint
