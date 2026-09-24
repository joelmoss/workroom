# The ssh container fixture for the persistent remote path (issue #228): a Linux box with sshd, a
# supervised wr-agent and nothing else Workroom-specific. The cheapest real driver, and CI for it.
#
# run.sh builds this with the agent under test in the build context. Nobody else should.
FROM debian:bookworm-slim

# git: the VCS test reads a real repository through the relay. procps: pgrep, for the tests that
# find the supervised agent.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server git procps \
 && rm -rf /var/lib/apt/lists/* \
 && ssh-keygen -A \
 && useradd --create-home --shell /bin/bash --password '*' workroom \
 && printf '%s\n' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' \
      'AllowUsers workroom' \
      > /etc/ssh/sshd_config.d/fixture.conf

COPY --chmod=755 wr-agent entrypoint.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
