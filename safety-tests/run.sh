#!/bin/bash
# Runs the existing-deployment safety scenarios (run-tests.sh) in a
# throwaway Debian 12 container with the distro's ansible package. The
# client and the backup server are both local connections in the same
# container; borg itself is a stub that only records its calls.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROLE="$(cd "$HERE/.." && pwd)"
docker run --rm -e DEBIAN_FRONTEND=noninteractive -e ANSIBLE_ROLES_PATH=/roles -e ANSIBLE_NOCOLOR=1 \
  -v "$ROLE":/roles/albancrommer.borgbackup:ro -v "$HERE":/t:ro debian:12 bash -c '
    apt-get update -qq >/dev/null && apt-get install -y -qq ansible openssh-client cron >/dev/null 2>&1
    useradd -m -d /home/borgbackup borgbackup; mkdir -p /etc/cron.d ~root/.ssh
    printf "#!/bin/sh\necho \"borg-dummy \$*\" >> /tmp/borg-calls\nexit 0\n" > /usr/local/bin/borg
    chmod 755 /usr/local/bin/borg
    bash /t/run-tests.sh'
