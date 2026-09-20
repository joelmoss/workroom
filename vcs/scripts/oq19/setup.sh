#!/bin/sh
# Installs the OQ19 measurement image's package list on a boxd VM (plan decision D4), so the boxd run
# measures the same tools the container did. Keep PACKAGES in step with the Dockerfile. Idempotent.
#
#   boxd machine cp -r <harness> vm:/oq19 && boxd machine exec <vm> -- sh /oq19/setup.sh
set -eu
PACKAGES="python3 iproute2 procps tmux vim less build-essential util-linux curl ca-certificates openssh-server cron"
export DEBIAN_FRONTEND=noninteractive
if ! command -v apt-get >/dev/null 2>&1; then
  echo "setup.sh: not a Debian-family box (no apt-get); install: $PACKAGES" >&2
  exit 1
fi
apt-get update -qq
# shellcheck disable=SC2086
apt-get install -y -qq --no-install-recommends $PACKAGES
ln -sf /bin/sh /usr/local/bin/wr-wakeshim   # the name boundary.md excludes by (driver.py does this too)
mkdir -p /run/oq19 /oq19-out
python3 --version
uname -r
echo "setup.sh: ok"
