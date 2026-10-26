# The ssh container fixture for the persistent remote path (issue #228): a Linux box with sshd, a
# supervised workroomd and nothing else Workroom-specific. The cheapest real driver, and CI for it.
#
# run.sh builds it with the daemon under test in the build context: the test fixture, with its own
# GitHub (fake-github.py) answering for github.com, a credential helper for it standing in for a
# provider's own (git-credential-fixture), and a repository to clone (#252). The boxd, exe.dev and
# ssh drivers' tests run on it. It was also, as FIXTURE=0, the `workroom-host` image container
# workrooms ran before #308, which made them from any image instead.
FROM debian:bookworm-slim
# run.sh still passes FIXTURE=1; there is no other variant now.
ARG FIXTURE=1

# git: the VCS test reads a real repository through the relay. procps: pgrep, for the tests that
# find the supervised daemon. ca-certificates: git over https. python3 and openssl: the fixture's
# GitHub (#252).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server git procps ca-certificates python3 openssl fish \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --shell /bin/bash --password '*' workroom \
 && useradd --create-home --shell /usr/bin/fish --password '*' workroom-fish \
 && printf '%s\n' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' \
      'AllowUsers workroom workroom-fish' \
      > /etc/ssh/sshd_config.d/fixture.conf

# A repository a base machine clones (#252): the fixture has no GitHub, so the app's provisioning
# tests clone this one, by path, and a derived workroom fetches from its own copy of it.
RUN seed="$(mktemp -d)" \
 && git init -q -b main "$seed" \
 && echo origin > "$seed/README" \
 && git -C "$seed" add README \
 && git -C "$seed" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial \
 && git clone -q --bare "$seed" /srv/origin.git \
 && rm -rf "$seed" \
 && chown -R workroom:workroom /srv/origin.git

# The fixture's GitHub (fake-github.py): a certificate for github.com that git trusts for that
# host only, and the one token it accepts, which the image's credential helper answers with as a
# provider's integration would. The app's provisioning tests hand the same token out as the Mac's
# own `gh` token for a relayed workroom (RemoteProvisioningIntegrationTests).
RUN mkdir -p /etc/workroom-fixture \
 && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=github.com \
      -addext subjectAltName=DNS:github.com \
      -keyout /etc/workroom-fixture/github.key -out /etc/workroom-fixture/github.pem 2>/dev/null \
 && chown workroom:workroom /etc/workroom-fixture/github.key \
 && git config --system http.https://github.com/.sslCAInfo /etc/workroom-fixture/github.pem \
 && git config --system credential.https://github.com.helper /usr/local/bin/git-credential-fixture \
 && echo ghs_fixture_clone_token_0123456789 > /etc/workroom-fixture/clone-token

# `workroom[d]`: a pattern, so a context without a daemon copies the rest, and the app's bootstrap
# installs one on first connect (#231).
COPY --chmod=755 workroom[d] entrypoint.sh identity.sh fake-github.py git-credential-fixture \
  /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
