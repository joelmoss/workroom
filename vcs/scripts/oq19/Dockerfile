# OQ19 measurement image (plan decision D4). The SAME package list is installed on the boxd VM by setup.sh,
# so the local and boxd runs measure the same machine. Real vim, tmux and less, not imitations: scenario 2c
# exists to see tmux's real status-clock writes.
#
#   docker build -t oq19 vcs/scripts/oq19        (run.sh does this)
FROM debian:bookworm-slim

# Keep this list in step with setup.sh (`PACKAGES`).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      python3 iproute2 procps tmux vim less build-essential util-linux curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /oq19
