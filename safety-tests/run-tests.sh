#!/bin/bash
# Runs inside the container. Each scenario resets client/server state,
# seeds what's "already deployed", runs the role, and checks the result.
cd /t
PASS=0; FAIL=0
AK=/home/borgbackup/.ssh/authorized_keys
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); grep -E -A6 "^fatal|^failed|ERROR!" /tmp/out | head -12 | sed "s/^/      /"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
reset(){
  rm -f /usr/local/bin/borg-backup ~root/.borg.passphrase ~root/.ssh/config /tmp/prune-* /tmp/borg-calls
  rm -rf /home/borgbackup/.ssh; mkdir -p /home/borgbackup/.ssh; touch $AK; chown -R borgbackup: /home/borgbackup/.ssh
}
play(){ ansible-playbook -i inventory.yml site.yml "$@" > /tmp/out 2>&1; echo $? > /tmp/rc; }
rc(){ cat /tmp/rc; }
KEY(){ cut -d' ' -f1,2 ~root/.ssh/id_borg_rsa.pub; }
seed_line(){ echo "command=\"$1\",no-port-forwarding,no-X11-forwarding,no-pty,no-agent-forwarding,no-user-rc $(cat ~root/.ssh/id_borg_rsa.pub)" > $AK; }
seed_script(){ printf '#!/bin/bash\n    REPOSITORY=%s\n' "$1" > /usr/local/bin/borg-backup; }
# generate the client key once (the role would do the same)
ssh-keygen -q -t rsa -b 2048 -N "" -C "ansible-generated on client1" -f ~root/.ssh/id_borg_rsa

echo "S1 fresh client"; reset; play -l client1
check "role succeeds" '[ $(rc) = 0 ]'
check "script REPOSITORY" 'grep -q "REPOSITORY=borgbackup@backupsrv:/backup/repos/client1$" /usr/local/bin/borg-backup'
check "key line (historical format, append-only)" 'grep -q "^command=\"cd /backup/repos/client1;borg serve --append-only --restrict-to-path /backup//repos/client1\"" $AK'
check "borg binary not replaced" 'grep -q borg-dummy /usr/local/bin/borg'
check "prune script REPOSITORY" 'grep -q "REPOSITORY=borgbackup@backupsrv:/backup/repos/client1$" /tmp/prune-client1'

echo "S2 re-run is a no-op on deployed files"; S=$(md5sum $AK /usr/local/bin/borg-backup ~root/.borg.passphrase); play -l client1
check "role succeeds" '[ $(rc) = 0 ]'
check "files byte-identical" '[ "$S" = "$(md5sum $AK /usr/local/bin/borg-backup ~root/.borg.passphrase)" ]'

echo "S3 nc1-shaped existing deployment"; reset
seed_line "cd /backup/repos/client1;borg serve --append-only --restrict-to-path /backup//repos/client1"
seed_script "borgbackup@backupsrv:/backup/repos/client1"; echo 'export BORG_PASSPHRASE="s3cret"' > ~root/.borg.passphrase
S=$(md5sum $AK); play -l client1
check "role succeeds" '[ $(rc) = 0 ]'
check "authorized_keys byte-identical" '[ "$S" = "$(md5sum $AK)" ]'

echo "S4 existing repo elsewhere, no override -> refused, nothing written"; reset
seed_line "cd /srv/old/client1;borg serve --append-only --restrict-to-path /srv/old/client1"
seed_script "borgbackup@backupsrv:/srv/old/client1"; echo 'export BORG_PASSPHRASE="s3cret"' > ~root/.borg.passphrase
S=$(md5sum $AK /usr/local/bin/borg-backup ~root/.borg.passphrase); play -l client1
check "role fails" '[ $(rc) != 0 ]'
check "message names the existing repo" 'grep -q "uses borgbackup@backupsrv:/srv/old/client1" /tmp/out'
check "nothing changed" '[ "$S" = "$(md5sum $AK /usr/local/bin/borg-backup ~root/.borg.passphrase)" ]'
check "borg init never called" '[ ! -e /tmp/borg-calls ]'

echo "S5 same, with borgbackup_repository_paths override"; S=$(md5sum $AK)
play -l client1 -e '{"borgbackup_repository_paths": {"backupsrv": "/srv/old/client1"}}'
check "role succeeds" '[ $(rc) = 0 ]'
check "authorized_keys byte-identical" '[ "$S" = "$(md5sum $AK)" ]'
check "script keeps REPOSITORY" 'grep -q "REPOSITORY=borgbackup@backupsrv:/srv/old/client1$" /usr/local/bin/borg-backup'
check "prune script follows override" 'grep -q "REPOSITORY=borgbackup@backupsrv:/srv/old/client1$" /tmp/prune-client1'

echo "S6 append-only would be dropped -> refused"; reset
seed_line "cd /backup/repos/client1;borg serve --append-only --restrict-to-path /backup//repos/client1"
S=$(md5sum $AK); play -l client1 -e borgbackup_appendonly=false
check "role fails" '[ $(rc) != 0 ]'
check "message mentions append-only" 'grep -q "append-only" /tmp/out'
check "authorized_keys unchanged" '[ "$S" = "$(md5sum $AK)" ]'

echo "S7 different passphrase -> refused, secret not logged"; reset
echo 'export BORG_PASSPHRASE="older"' > ~root/.borg.passphrase; S=$(md5sum ~root/.borg.passphrase); play -l client1
check "role fails" '[ $(rc) != 0 ]'
check "passphrase file unchanged" '[ "$S" = "$(md5sum ~root/.borg.passphrase)" ]'
check "no secret in output" '! grep -q -e s3cret -e older /tmp/out'

echo "S8 tube-shaped: port 20222, /rpool, override keeps line byte-identical"; reset
cat > /tmp/tube.json <<'J'
{"borgbackup_servers":[{"fqdn":"backupsrv","user":"borgbackup","home":"/rpool/backup/","pool":"repos","type":"normal","port":20222,"options":""}],
 "borgbackup_repository_paths":{"backupsrv":"/rpool/backup/repos/client1"}}
J
seed_line "cd /rpool/backup/repos/client1;borg serve --append-only --restrict-to-path /rpool/backup/repos/client1"
seed_script "ssh://borgbackup@backupsrv:20222//rpool/backup/repos/client1"; echo 'export BORG_PASSPHRASE="s3cret"' > ~root/.borg.passphrase
S=$(md5sum $AK); play -l client1 -e @/tmp/tube.json
check "role succeeds" '[ $(rc) = 0 ]'
check "authorized_keys byte-identical" '[ "$S" = "$(md5sum $AK)" ]'
check "script REPOSITORY with port" 'grep -q "REPOSITORY=ssh://borgbackup@backupsrv:20222//rpool/backup/repos/client1$" /usr/local/bin/borg-backup'
check "prune script has the port too" 'grep -q "REPOSITORY=ssh://borgbackup@backupsrv:20222//rpool/backup/repos/client1$" /tmp/prune-client1'

echo "S9 tube-shaped but inventory forgets the port -> refused"; S=$(md5sum /usr/local/bin/borg-backup)
play -l client1 -e '{"borgbackup_servers":[{"fqdn":"backupsrv","user":"borgbackup","home":"/rpool/backup/","pool":"repos","type":"normal","options":""}]}'
check "role fails" '[ $(rc) != 0 ]'
check "script unchanged" '[ "$S" = "$(md5sum /usr/local/bin/borg-backup)" ]'

echo "S10 backup server in the play: account left alone by default"; reset
play -l client1,backupsrv
check "role succeeds" '[ $(rc) = 0 ]'
check "borgbackup home unchanged" '[ "$(getent passwd borgbackup | cut -d: -f6)" = /home/borgbackup ]'
check "server tasks skipped" '! grep -q "server | create user" /tmp/out || grep -A1 "server | create user" /tmp/out | grep -q skipping'
play -l backupsrv -e borgbackup_manage_server=true -e borgbackup_force_install=false
echo "      home now: $(getent passwd borgbackup | cut -d: -f6)"; check "with manage_server=true the server tasks do run (moves home)" '[ "$(getent passwd borgbackup | cut -d: -f6)" != /home/borgbackup ]'

echo; echo "passed=$PASS failed=$FAIL"; [ $FAIL = 0 ]
