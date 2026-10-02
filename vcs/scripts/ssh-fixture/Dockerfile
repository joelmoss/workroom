# The ssh container fixture for the persistent remote path (issue #228): a Linux box with sshd, a
# supervised wr-agent and nothing else Workroom-specific. The cheapest real driver, and CI for it.
#
# Two variants, chosen by FIXTURE:
# - FIXTURE=1, which run.sh builds with the agent under test in the build context: the test
#   fixture, with its own GitHub and broker (fake-github.py) answering for github.com, and a
#   repository to clone (#252).
# - FIXTURE=0 (`make remote-host-image`, tagged `workroom-host`): the host a Nightly app's
#   remote workrooms run on, on the Mac's own Docker (#253). It talks to the real github.com and
#   has no agent baked in: the app installs its own on first connect (#231), and the supervisor
#   below waits until it has.
FROM debian:bookworm-slim
ARG FIXTURE=0

# git: the VCS test reads a real repository through the relay. procps: pgrep, for the tests that
# find the supervised agent. ca-certificates: git over https to GitHub. python3 and openssl: the
# fixture's GitHub and broker (#252).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server git procps ca-certificates \
      $([ "$FIXTURE" = 1 ] && echo python3 openssl) \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --shell /bin/bash --password '*' workroom \
 && printf '%s\n' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' \
      'AllowUsers workroom' \
      > /etc/ssh/sshd_config.d/fixture.conf

# A repository a base machine clones (#252): the fixture has no GitHub, so the app's provisioning
# tests clone this one, by path, and a derived workroom fetches from its own copy of it.
RUN [ "$FIXTURE" = 1 ] || exit 0; \
    seed="$(mktemp -d)" \
 && git init -q -b main "$seed" \
 && echo origin > "$seed/README" \
 && git -C "$seed" add README \
 && git -C "$seed" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial \
 && git clone -q --bare "$seed" /srv/origin.git \
 && rm -rf "$seed" \
 && chown -R workroom:workroom /srv/origin.git

# The fixture's GitHub (fake-github.py): a certificate for github.com that git trusts for that
# host only, and the base clone token it accepts besides the ones its broker mints. The app's
# provisioning tests hand the same token out as the broker's (RemoteProvisioningIntegrationTests).
RUN [ "$FIXTURE" = 1 ] || exit 0; \
    mkdir -p /etc/workroom-fixture \
 && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=github.com \
      -addext subjectAltName=DNS:github.com \
      -keyout /etc/workroom-fixture/github.key -out /etc/workroom-fixture/github.pem 2>/dev/null \
 && chown workroom:workroom /etc/workroom-fixture/github.key \
 && git config --system http.https://github.com/.sslCAInfo /etc/workroom-fixture/github.pem \
 && echo ghs_fixture_clone_token_0123456789 > /etc/workroom-fixture/clone-token

# `wr-agen[t]`: a pattern, so a context without an agent (FIXTURE=0) copies the rest.
COPY --chmod=755 wr-agen[t] entrypoint.sh identity.sh fake-github.py /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
