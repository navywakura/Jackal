#!/usr/bin/env bash
# =============================================================================
# Jackal — runner de migraciones de ScyllaDB
#
#   ./tools/migrate-scylla.sh up      aplica las migraciones pendientes
#   ./tools/migrate-scylla.sh status  muestra qué se ha aplicado
#   ./tools/migrate-scylla.sh render  imprime el CQL con las variables resueltas
#   ./tools/migrate-scylla.sh reset   BORRA el keyspace y lo recrea
#
# Los ficheros .cql llevan marcadores ${SCYLLA_KEYSPACE}, ${SCYLLA_LOCAL_DC} y
# ${SCYLLA_REPLICATION_FACTOR} que se sustituyen desde el entorno. El factor de
# replicación es 1 en desarrollo y 3 en producción; el resto del esquema es
# idéntico en ambos.
#
# CQL no tiene DDL transaccional: cada sentencia se aplica por separado y una
# migración a medias deja el keyspace en un estado intermedio. Por eso todas las
# tablas usan CREATE TABLE IF NOT EXISTS y reejecutar es seguro.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS="$ROOT/db/scylla/migrations"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

export SCYLLA_KEYSPACE="${SCYLLA_KEYSPACE:-jackal}"
export SCYLLA_LOCAL_DC="${SCYLLA_LOCAL_DC:-datacenter1}"
export SCYLLA_REPLICATION_FACTOR="${SCYLLA_REPLICATION_FACTOR:-1}"

CONTACT="${SCYLLA_CONTACT_POINTS:-localhost:9042}"
CQL_HOST="${CONTACT%%:*}"
CQL_PORT="${CONTACT##*:}"
[ "$CQL_PORT" = "$CQL_HOST" ] && CQL_PORT=9042

if command -v cqlsh > /dev/null 2>&1; then
    CQLSH=(cqlsh "$CQL_HOST" "$CQL_PORT")
elif docker compose -f "$ROOT/infra/docker-compose.yml" ps scylla > /dev/null 2>&1; then
    CQLSH=(docker compose -f "$ROOT/infra/docker-compose.yml" exec -T scylla cqlsh)
else
    echo "ERROR: no encuentro cqlsh ni el contenedor scylla en marcha." >&2
    echo "       docker compose -f infra/docker-compose.yml up -d scylla" >&2
    exit 1
fi

# Sustituye SOLO las tres variables previstas; así un '$' en un comentario del
# CQL no se convierte en cadena vacía silenciosamente.
render() {
    sed -e "s|\${SCYLLA_KEYSPACE}|$SCYLLA_KEYSPACE|g" \
        -e "s|\${SCYLLA_LOCAL_DC}|$SCYLLA_LOCAL_DC|g" \
        -e "s|\${SCYLLA_REPLICATION_FACTOR}|$SCYLLA_REPLICATION_FACTOR|g" \
        "$1"
}

cql() { "${CQLSH[@]}" -e "$1"; }

ensure_tracking_table() {
    cql "CREATE KEYSPACE IF NOT EXISTS $SCYLLA_KEYSPACE
         WITH replication = {'class':'NetworkTopologyStrategy','$SCYLLA_LOCAL_DC':$SCYLLA_REPLICATION_FACTOR};" > /dev/null
    cql "CREATE TABLE IF NOT EXISTS $SCYLLA_KEYSPACE.schema_migrations (
             version    text PRIMARY KEY,
             sha256     text,
             applied_at timestamp
         );" > /dev/null
}

cmd_up() {
    ensure_tracking_table
    local applied=0
    for file in "$MIGRATIONS"/*.cql; do
        local version sha recorded tmp
        version="$(basename "$file" .cql)"
        sha="$(sha256sum "$file" | cut -d' ' -f1)"
        recorded="$(cql "SELECT sha256 FROM $SCYLLA_KEYSPACE.schema_migrations
                         WHERE version = '$version';" | sed -n '4p' | tr -d ' ')"

        if [ -n "$recorded" ] && [ "$recorded" != "null" ]; then
            if [ "$recorded" != "$sha" ]; then
                echo "ERROR: $version ya se aplicó pero su contenido ha cambiado." >&2
                echo "       Escribe una migración nueva en vez de editar esta." >&2
                exit 1
            fi
            continue
        fi

        echo "→ aplicando $version"
        tmp="$(mktemp)"
        render "$file" > "$tmp"
        "${CQLSH[@]}" -f "$tmp"
        rm -f "$tmp"
        cql "INSERT INTO $SCYLLA_KEYSPACE.schema_migrations (version, sha256, applied_at)
             VALUES ('$version', '$sha', toTimestamp(now()));" > /dev/null
        applied=$((applied + 1))
    done
    [ "$applied" -eq 0 ] && echo "Sin migraciones pendientes." || echo "$applied migración(es) aplicada(s)."
}

cmd_status() {
    ensure_tracking_table
    echo "Migraciones en keyspace '$SCYLLA_KEYSPACE' (RF=$SCYLLA_REPLICATION_FACTOR)"
    for file in "$MIGRATIONS"/*.cql; do
        local version recorded sha
        version="$(basename "$file" .cql)"
        sha="$(sha256sum "$file" | cut -d' ' -f1)"
        recorded="$(cql "SELECT sha256 FROM $SCYLLA_KEYSPACE.schema_migrations
                         WHERE version = '$version';" | sed -n '4p' | tr -d ' ')"
        if   [ -z "$recorded" ] || [ "$recorded" = "null" ]; then printf '  [ ] %s\n' "$version"
        elif [ "$recorded" != "$sha" ];                       then printf '  [!] %s  (MODIFICADA tras aplicarse)\n' "$version"
        else                                                       printf '  [x] %s\n' "$version"
        fi
    done
}

cmd_render() { for f in "$MIGRATIONS"/*.cql; do render "$f"; echo; done; }

cmd_reset() {
    if [ "${FLASK_ENV:-development}" != "development" ]; then
        echo "ERROR: reset solo está permitido con FLASK_ENV=development." >&2
        exit 1
    fi
    read -rp "Esto BORRA el keyspace '$SCYLLA_KEYSPACE'. Escribe el nombre para confirmar: " confirm
    [ "$confirm" = "$SCYLLA_KEYSPACE" ] || { echo "Cancelado."; exit 1; }
    cql "DROP KEYSPACE IF EXISTS $SCYLLA_KEYSPACE;"
    cmd_up
}

case "${1:-up}" in
    up)     cmd_up ;;
    status) cmd_status ;;
    render) cmd_render ;;
    reset)  cmd_reset ;;
    *) echo "uso: $0 {up|status|render|reset}" >&2; exit 1 ;;
esac
