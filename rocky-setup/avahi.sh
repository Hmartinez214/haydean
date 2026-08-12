#!/bin/bash
# Rocky port of avahi.sh
#
# Changes from the Ubuntu original:
#   apt → dnf
#   avahi-daemon avahi-utils  →  avahi avahi-tools nss-mdns
#     (avahi-resolve-host-name, used by sync_hosts.sh, lives in avahi-tools)
#   nss-mdns is NOT pulled in automatically on Rocky and .local resolution
#     silently fails without it — this bit the Ubuntu build too, but there the
#     package was a dependency.
#   firewalld is enabled by default on Rocky, so mDNS (UDP 5353) must be opened.

set -e

sudo dnf install -y avahi avahi-tools nss-mdns

sudo systemctl enable avahi-daemon
sudo systemctl start avahi-daemon

# Rocky ships firewalld active; Ubuntu's ufw was inactive so the original
# script never needed this.
if systemctl is-active --quiet firewalld; then
  sudo firewall-cmd --permanent --add-service=mdns
  sudo firewall-cmd --reload
  echo "  opened mDNS in firewalld"
fi

# Make sure nsswitch actually consults mDNS.
if ! grep -q 'mdns' /etc/nsswitch.conf; then
  echo "  WARNING: mdns not in /etc/nsswitch.conf hosts line — .local lookups will fail"
  echo "  current: $(grep '^hosts:' /etc/nsswitch.conf)"
fi

echo "Test with:  avahi-resolve-host-name -4 haydean1.local"
