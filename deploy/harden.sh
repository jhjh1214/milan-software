#!/usr/bin/env bash
# One-time OS hardening for a fresh VPS, before "First boot" brings up the
# stack. Idempotent -- safe to run again after a distro upgrade resets a
# package, or just to confirm the box is still in the state this expects.
#
#   ssh root@vps 'bash -s' < harden.sh
#
# Two things, both because the compose file cannot do either for you: a
# firewall (only 22, 80, 443 reach this box at all -- everything else
# deploy/README.md's "What is deliberately not here" already keeps off a
# published port, but SSH itself is the one port that must stay open, and a
# stray service binding to some other port later should not get a free pass
# just because nothing blocked it) and fail2ban (an internet-facing sshd gets
# credential-stuffed within hours of going up; this is what turns that into a
# log line instead of a slow brute force running forever).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root (or via sudo) -- ufw and fail2ban both need it" >&2
	exit 1
fi

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

log "installing ufw and fail2ban"
apt-get update -qq
apt-get install -y -qq ufw fail2ban

# --- firewall -----------------------------------------------------------
# Order matters: allow SSH before default-deny, or a running session on a
# fresh box locks itself out the moment `ufw enable` takes effect.
log "allowing SSH, HTTP, HTTPS"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp # HTTP/3 -- Caddy's own port mapping in docker-compose.yml

log "setting default-deny and enabling ufw"
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

# --- fail2ban -------------------------------------------------------------
# The stock sshd jail with slightly less patience than the Debian/Ubuntu
# default (3 tries, not 5) -- a real admin mistyping a password three times
# in a row from the same IP is rare enough that this is not the false
# positive it looks like, and it cuts a credential-stuffing run's useful
# window by more than half.
log "configuring fail2ban"
cat >/etc/fail2ban/jail.local <<'JAIL'
[sshd]
enabled = true
maxretry = 3
bantime = 1h
findtime = 10m
JAIL

systemctl enable --now fail2ban
systemctl restart fail2ban

log "ufw status:"
ufw status verbose
log "fail2ban status:"
fail2ban-client status sshd || true

log "ok — firewall and fail2ban are active"
