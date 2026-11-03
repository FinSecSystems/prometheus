#!/bin/bash
# Database and Redis exporters of the prometheus stack (issue #18, docs/monitoring.md).
#   ./exporters-init.sh          create the read-only monitoring user "exporter" in every database (idempotent), render the exporter configs
#   ./exporters-init.sh render   only render the configs (after changing exporters.env or the target lists below)
# One shared password, kept in the git-crypt file exporters.env (EXPORTER_PASSWORD, generated on the first run). The users have no rights beyond monitoring:
#   PostgreSQL: LOGIN + role pg_monitor (PostgreSQL 10 and newer; older servers give a plain login with the default statistics access); MariaDB: PROCESS, REPLICATION CLIENT, SELECT on *.* (MAX_USER_CONNECTIONS 3).
# Rendered into $BUILD_DIR/prometheus/exporters (outside the repo, folder mode 700): postgres_exporter.yml, my.cnf, redis-passwords.json.
# Targets are listed here and in the "pg", "mysql" and "redis" jobs of prometheus/prometheus.yml; keep both in sync when a database is added.
set -eu
cd "$(dirname "$(readlink -f "$0")")"
. ./.env
PG=(gitlab-postgresql helpdesk-postgresql mail-roundcube-db mattermost-db openproject-db protonmail-roundcubedb security-dojo-db vaultwarden-db)
MYSQL=(limesurvey-db matomo-db nextcloud-db nextcloud-screeenly-db paperless-db photos-db pictures-db websites-liquibrium-exchange-db)   # photos-db and pictures-db listen on port 4001
# redis targets that need a password: container:environment variable that holds it
REDIS_AUTH=(nextcloud-redis:REDIS_PASSWORD)

[ -f exporters.env ] || { umask 077; echo "EXPORTER_PASSWORD=$(python3 -c 'import secrets;print(secrets.token_hex(24))')" > exporters.env; echo "created exporters.env"; }
PW=$(sed -n 's/^EXPORTER_PASSWORD=//p' exporters.env)
[ -n "$PW" ] || { echo "EXPORTER_PASSWORD missing in exporters.env"; exit 1; }

if [ "${1:-}" != render ]; then
  for c in "${PG[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then echo "SKIP  $c (not running)"; continue; fi
    out=$(docker exec -i "$c" sh -c '
      # first account that is a superuser (the application account of some images has no CREATEROLE)
      for u in "$POSTGRES_USER" "$DB_USER" "$PG_USER" postgres; do
        [ -n "$u" ] || continue
        [ "$(psql -U "$u" -d postgres -tAc "select rolsuper from pg_roles where rolname = current_user" 2>/dev/null)" = t ] || continue
        v=$(psql -U "$u" -d postgres -tAc "show server_version_num")
        { cat; [ "$v" -ge 100000 ] && echo "GRANT pg_monitor TO exporter;"; } | exec psql -U "$u" -d postgres -v ON_ERROR_STOP=1 -q
        exit $?
      done; echo "no superuser found" >&2; exit 1' 2>&1 <<SQL
DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'exporter') THEN CREATE ROLE exporter LOGIN; END IF; END \$\$;
ALTER ROLE exporter WITH LOGIN PASSWORD '$PW';
SQL
    ) && echo "OK    $c (postgres)" || echo "FAIL  $c: $out"
  done
  for c in "${MYSQL[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then echo "SKIP  $c (not running)"; continue; fi
    out=$(docker exec -i "$c" sh -c 'exec $(command -v mariadb || command -v mysql) -uroot -p"${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}"' 2>&1 <<SQL
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY '$PW' WITH MAX_USER_CONNECTIONS 3;
ALTER USER 'exporter'@'%' IDENTIFIED BY '$PW' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
SQL
    ) && echo "OK    $c (mariadb)" || echo "FAIL  $c: $out"
  done
fi

out=$BUILD_DIR/prometheus/exporters
[ -d "$out" ] || { echo "create $out first (docker run --rm -v $BUILD_DIR:/b alpine sh -c 'mkdir -p /b/prometheus/exporters && chown 1000:1000 /b/prometheus /b/prometheus/exporters')"; exit 1; }
umask 077
cat > "$out/postgres_exporter.yml" <<YML
auth_modules:
  exporter:
    type: userpass
    userpass:
      username: exporter
      password: "$PW"
    options:
      sslmode: disable
YML
printf '[client]\nuser=exporter\npassword=%s\n' "$PW" > "$out/my.cnf"
json='{'; sep=''
for e in "${REDIS_AUTH[@]}"; do
  c=${e%%:*}; v=${e##*:}
  p=$(docker exec "$c" sh -c "printf %s \"\$$v\"")
  json+="$sep\"redis://$c:6379\": \"$p\""; sep=', '
done
echo "$json}" > "$out/redis-passwords.json"
# the exporters run as other users (nobody ...): the files are world-readable, the folder is 700 so only ubuntu (and the Docker daemon, which mounts them) can reach them
chmod 700 "$out"; chmod 644 "$out"/postgres_exporter.yml "$out"/my.cnf "$out"/redis-passwords.json
echo "rendered $out"
