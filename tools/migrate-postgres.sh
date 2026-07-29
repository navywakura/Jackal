#!/usr/bin/env bash
# =============================================================================
# Jackal — runner de migraciones de PostgreSQL
#
#   ./tools/migrate-postgres.sh up      aplica las migraciones pendientes
#   ./tools/migrate-postgres.sh status  muestra qué se ha aplicado
#   ./tools/migrate-postgres.sh seed    carga datos de desarrollo
#   ./tools/migrate-postgres.sh test    ejecuta la prueba de restricciones
#   ./tools/migrate-postgres.sh reset   BORRA la base de datos y la recrea
#
# Cada migración corre dentro de su propia transacción (los ficheros llevan su
# BEGIN/COMMIT) y se registra en schema_migrations con el SHA-256 del fichero.
# Si un fichero ya aplicado cambia, el runner aborta: editar una migración
# publicada en vez de escribir una nueva es la vía más rápida a que dos entornos
# tengan esquemas distintos creyendo que son iguales.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS="$ROOT/db/postgres/migrations"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

PGHOST="${POSTGRES_HOST:-localhost}"
PGPORT="${POSTGRES_PORT:-5432}"
PGDATABASE="${POSTGRES_DB:-jackal}"
PGUSER="${POSTGRES_USER:-jackal}"
export PGPASSWORD="${POSTGRES_PASSWORD:-}"
export PGHOST PGPORT PGDATABASE PGUSER

psql_q() { psql -v ON_ERROR_STOP=1 -q -t -A "$@"; }

ensure_tracking_table() {
    psql_q -c "SET client_min_messages=warning;
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version     text        PRIMARY KEY,
            sha256      text        NOT NULL,
            applied_at  timestamptz NOT NULL DEFAULT now(),
            duration_ms integer     NOT NULL
        );" > /dev/null
}

file_sha() { sha256sum "$1" | cut -d' ' -f1; }

cmd_up() {
    ensure_tracking_table
    local applied=0
    for file in "$MIGRATIONS"/*.sql; do
        local version sha recorded
        version="$(basename "$file" .sql)"
        sha="$(file_sha "$file")"
        recorded="$(psql_q -c "SELECT sha256 FROM schema_migrations WHERE version = '$version'")"

        if [ -n "$recorded" ]; then
            if [ "$recorded" != "$sha" ]; then
                echo "ERROR: $version ya se aplicó pero su contenido ha cambiado." >&2
                echo "       Escribe una migración nueva en vez de editar esta." >&2
                exit 1
            fi
            continue
        fi

        echo "→ aplicando $version"
        local start end
        start=$(date +%s%3N)
        psql -v ON_ERROR_STOP=1 -q -f "$file"
        end=$(date +%s%3N)
        psql_q -c "INSERT INTO schema_migrations (version, sha256, duration_ms)
                   VALUES ('$version', '$sha', $((end - start)))" > /dev/null
        echo "  aplicada en $((end - start)) ms"
        applied=$((applied + 1))
    done
    [ "$applied" -eq 0 ] && echo "Sin migraciones pendientes." || echo "$applied migración(es) aplicada(s)."
}

cmd_status() {
    ensure_tracking_table
    echo "Migraciones en $PGDATABASE@$PGHOST:$PGPORT"
    for file in "$MIGRATIONS"/*.sql; do
        local version recorded sha
        version="$(basename "$file" .sql)"
        sha="$(file_sha "$file")"
        recorded="$(psql_q -c "SELECT sha256 FROM schema_migrations WHERE version = '$version'")"
        if   [ -z "$recorded" ];        then printf '  [ ] %s\n' "$version"
        elif [ "$recorded" != "$sha" ]; then printf '  [!] %s  (MODIFICADA tras aplicarse)\n' "$version"
        else                                 printf '  [x] %s\n' "$version"
        fi
    done
}

cmd_seed() {
    echo "→ cargando datos de desarrollo"
    psql -v ON_ERROR_STOP=1 -f "$ROOT/db/postgres/seed/0001_dev_seed.sql"
}

cmd_test() {
    echo "→ prueba de restricciones (hace ROLLBACK al terminar)"
    psql -v ON_ERROR_STOP=1 -q -f "$ROOT/db/postgres/tests/constraints_test.sql"
}

cmd_reset() {
    if [ "${FLASK_ENV:-development}" != "development" ]; then
        echo "ERROR: reset solo está permitido con FLASK_ENV=development." >&2
        exit 1
    fi
    read -rp "Esto BORRA la base de datos '$PGDATABASE'. Escribe el nombre para confirmar: " confirm
    [ "$confirm" = "$PGDATABASE" ] || { echo "Cancelado."; exit 1; }
    PGDATABASE=postgres psql -v ON_ERROR_STOP=1 -q \
        -c "DROP DATABASE IF EXISTS $PGDATABASE" \
        -c "CREATE DATABASE $PGDATABASE"
    cmd_up
}

case "${1:-up}" in
    up)     cmd_up ;;
    status) cmd_status ;;
    seed)   cmd_seed ;;
    test)   cmd_test ;;
    reset)  cmd_reset ;;
    *) echo "uso: $0 {up|status|seed|test|reset}" >&2; exit 1 ;;
esac
