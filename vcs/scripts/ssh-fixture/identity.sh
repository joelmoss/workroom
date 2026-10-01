#!/bin/sh
# Prints the container's ssh host key, `<type> <base64>`, once its entrypoint has minted its
# identity (#252), and fails until then: until the marker names this container, the keys on disk are
# its image's or are about to be replaced. run.sh and `ContainerHostDriver` read the key to pin
# through this, out of band.
set -eu
[ "$(cat /etc/workroom-identity 2>/dev/null)" = "$(hostname)" ]
cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub
