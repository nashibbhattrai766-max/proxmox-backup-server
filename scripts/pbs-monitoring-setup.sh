#!/bin/bash
# Run on PBS (10.0.0.20) as root. Installs Zabbix agent 2 + node exporter and a status collector
# that writes /var/lib/prometheus/node-exporter/pbs.prom every 5 minutes (read by both Prometheus and Zabbix).
set -u
echo "=== 1/4 packages ==="
apt-get update -qq
apt-get install -y -qq jq prometheus-node-exporter >/dev/null && echo "jq + node exporter installed"
if apt-cache show zabbix-agent2 >/dev/null 2>&1; then
  apt-get install -y -qq zabbix-agent2 >/dev/null
else
  wget -qO /tmp/zr.deb https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.0+debian13_all.deb \
    && dpkg -i /tmp/zr.deb >/dev/null && apt-get update -qq && apt-get install -y -qq zabbix-agent2 >/dev/null
fi
command -v zabbix_agent2 >/dev/null && echo "zabbix-agent2 $(zabbix_agent2 -V | head -1 | grep -o '[0-9.]*$')" || { echo "!! zabbix-agent2 install failed"; exit 1; }

echo "=== 2/4 agent config ==="
C=/etc/zabbix/zabbix_agent2.conf
sed -i -E 's/^#? ?Server=.*/Server=10.0.0.30/; s/^#? ?ServerActive=.*/ServerActive=10.0.0.30/; s/^#? ?Hostname=.*/Hostname=pbs/' $C
grep -E '^(Server|ServerActive|Hostname)=' $C
systemctl enable -q zabbix-agent2 && systemctl restart zabbix-agent2 && echo "agent: $(systemctl is-active zabbix-agent2)"
echo "node exporter: $(systemctl is-active prometheus-node-exporter)"

echo "=== 3/4 status collector ==="
cat > /usr/local/bin/pbs-status.sh <<'EOF'
#!/bin/bash
# Writes PBS + QDevice + Pi-hole 2 health as Prometheus metrics. Runs every 5 min from cron.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
exec 9>/run/pbs-status.lock; flock -n 9 || exit 0
DIR=/var/lib/prometheus/node-exporter; OUT=$DIR/pbs.prom; DS=backups; NOW=$(date +%s)
api() { timeout 60 proxmox-backup-debug api get "$@" --output-format json 2>/dev/null; }
{
  echo "pbs_status_timestamp_seconds $NOW"
  api /admin/datastore/$DS/groups | jq -r '.[] | "pbs_group_last_backup_seconds{type=\"\(.["backup-type"])\",id=\"\(.["backup-id"])\"} \(.["last-backup"])"'
  api /admin/datastore/$DS/snapshots | jq -r '"pbs_snapshots_total \(length)",
      "pbs_verify_failed \([.[] | select(.verification.state == "failed")] | length)",
      "pbs_verify_ok \([.[] | select(.verification.state == "ok")] | length)"'
  api /nodes/localhost/tasks --errors true --since $((NOW - 86400)) --limit 500 | jq -r '"pbs_tasks_failed_24h \(length)"'
  for s in corosync-qnetd unbound; do echo "pbs_service_up{service=\"$s\"} $(systemctl is-active --quiet $s && echo 1 || echo 0)"; done
  for c in pihole2 nebula-sync; do
    echo "pbs_container_up{container=\"$c\"} $([ "$(docker inspect -f '{{.State.Running}}' $c 2>/dev/null)" = true ] && echo 1 || echo 0)"
  done
  L=$(docker logs --timestamps --since 6h nebula-sync 2>&1 | grep -a 'Sync completed' | tail -1 | awk '{print $1}')
  echo "pbs_nebula_last_sync_seconds $([ -n "$L" ] && date -d "$L" +%s 2>/dev/null || echo 0)"
} > $OUT.tmp && chmod 644 $OUT.tmp && mv $OUT.tmp $OUT
EOF
chmod 755 /usr/local/bin/pbs-status.sh
echo '*/5 * * * * root /usr/local/bin/pbs-status.sh' > /etc/cron.d/pbs-status
/usr/local/bin/pbs-status.sh

echo "=== 4/4 result (pbs.prom) ==="
cat /var/lib/prometheus/node-exporter/pbs.prom
echo; echo "Check: group lines (vm/ct/host), verify_ok > 0, service/container lines = 1."
