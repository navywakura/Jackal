#!/usr/bin/env bash
# =============================================================================
# Jackal — arranque del entorno de desarrollo
#
#   ./dev.sh          arranca todo y aplica migraciones pendientes
#   ./dev.sh seed     ídem + carga datos de prueba
#   ./dev.sh stop     para todos los contenedores
#   ./dev.sh status   muestra estado de contenedores y migraciones
#   ./dev.sh reset    BORRA volúmenes y recrea desde cero (pide confirmación)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="docker compose -f $ROOT/infra/docker-compose.yml"

# ── Colores ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
hdr()  { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Subcomandos ──────────────────────────────────────────────────────────────
cmd_stop() {
    hdr "Parando contenedores"
    $COMPOSE stop postgres scylla coturn minio
    ok "Contenedores parados (volúmenes preservados)"
}

cmd_status() {
    hdr "Contenedores"
    $COMPOSE ps

    hdr "Migraciones PostgreSQL"
    "$ROOT/tools/migrate-postgres.sh" status 2>/dev/null || warn "No se puede conectar a Postgres"

    hdr "Migraciones ScyllaDB"
    "$ROOT/tools/migrate-scylla.sh" status 2>/dev/null || warn "No se puede conectar a Scylla"
}

cmd_reset() {
    err "Esto BORRA todos los volúmenes (postgres, scylla, minio). No hay vuelta atrás."
    read -rp "Escribe RESET para confirmar: " confirm
    [ "$confirm" = "RESET" ] || { echo "Cancelado."; exit 1; }
    $COMPOSE down -v
    ok "Volúmenes eliminados"
    cmd_up
}

# ── Arranque principal ────────────────────────────────────────────────────────
cmd_up() {
    # 1. Prerequisitos
    hdr "Prerequisitos"
    local missing=0
    for cmd in docker psql; do
        if command -v "$cmd" > /dev/null 2>&1; then
            ok "$cmd $(command -v "$cmd")"
        else
            err "$cmd no encontrado"
            missing=1
        fi
    done
    if ! docker compose version > /dev/null 2>&1; then
        err "docker compose (plugin) no disponible"
        missing=1
    else
        ok "docker compose $(docker compose version --short)"
    fi
    [ "$missing" -eq 0 ] || { err "Instala las dependencias que faltan y vuelve a intentarlo."; exit 1; }

    # 2. Fichero .env
    hdr "Configuración"
    if [ ! -f "$ROOT/.env" ]; then
        if [ -f "$ROOT/.env.example" ]; then
            err ".env no existe. Cópialo desde .env.example y rellena los secretos:"
            echo "  cp .env.example .env"
            echo "  for v in POSTGRES_PASSWORD POSTGRES_READONLY_PASSWORD INTERNAL_API_TOKEN TURN_STATIC_AUTH_SECRET S3_SECRET_KEY; do"
            echo "    echo \"\$v=\$(openssl rand -base64 24 | tr -d '=+/')\""
            echo "  done"
            echo "  echo \"JWT_SIGNING_SEED_HEX=\$(openssl rand -hex 32)\""
        else
            err ".env no existe."
        fi
        exit 1
    fi
    ok ".env presente"

    # 3. Symlink infra/.env → ../.env (docker compose lo necesita en su directorio)
    if [ ! -L "$ROOT/infra/.env" ]; then
        ln -s ../.env "$ROOT/infra/.env"
        ok "Creado infra/.env → ../.env"
    else
        ok "infra/.env symlink presente"
    fi

    # 4. Levantar contenedores
    hdr "Contenedores"
    $COMPOSE up -d postgres scylla coturn minio
    echo ""

    # 5. Esperar a que Postgres esté healthy
    echo -n "  Esperando Postgres"
    for i in $(seq 1 24); do
        status=$(docker inspect --format='{{.State.Health.Status}}' jackal-postgres 2>/dev/null || echo "missing")
        if [ "$status" = "healthy" ]; then echo ""; ok "Postgres listo"; break; fi
        if [ "$i" -eq 24 ]; then echo ""; err "Postgres no respondió en 120 s"; exit 1; fi
        echo -n "."; sleep 5
    done

    # 6. Esperar a que Scylla esté healthy (primer arranque puede tardar ~90 s)
    echo -n "  Esperando Scylla (primer arranque ~90 s)"
    for i in $(seq 1 40); do
        status=$(docker inspect --format='{{.State.Health.Status}}' jackal-scylla 2>/dev/null || echo "missing")
        if [ "$status" = "healthy" ]; then echo ""; ok "Scylla lista"; break; fi
        if [ "$i" -eq 40 ]; then echo ""; err "Scylla no respondió en 200 s"; exit 1; fi
        echo -n "."; sleep 5
    done

    # 7. Migraciones
    hdr "Migraciones PostgreSQL"
    "$ROOT/tools/migrate-postgres.sh" up

    hdr "Migraciones ScyllaDB"
    "$ROOT/tools/migrate-scylla.sh" up

    # 8. Seed opcional
    if [ "${1:-}" = "seed" ]; then
        hdr "Datos de prueba"
        "$ROOT/tools/migrate-postgres.sh" seed
    fi

    # 9. Resumen
    hdr "Entorno listo"
    echo ""
    echo -e "  ${BOLD}Infraestructura${NC}"
    echo -e "  ├─ PostgreSQL   →  localhost:5432  (DB: jackal, user: jackal)"
    echo -e "  ├─ ScyllaDB     →  localhost:9042  (keyspace: jackal)"
    echo -e "  ├─ MinIO        →  localhost:9000  (consola: http://localhost:9001)"
    echo -e "  └─ Coturn       →  localhost:3478"
    echo ""
    echo -e "  ${BOLD}Estado de las fases${NC}"
    echo -e "  ├─ ${GREEN}✓ FASE 1${NC}  Infraestructura, esquemas y migraciones"
    echo -e "  ├─ ${YELLOW}· FASE 2${NC}  Realtime (Elixir/Phoenix)   → apps/realtime/  [pendiente]"
    echo -e "  ├─ ${YELLOW}· FASE 3${NC}  API REST (Python/Flask)     → apps/api/       [pendiente]"
    echo -e "  └─ ${YELLOW}· FASE 4${NC}  Frontend (React/Vite)       → apps/web/       [pendiente]"
    echo ""
    echo -e "  ${YELLOW}⚠${NC}  Aún no hay app arrancable. Cuando estén las FASES 2-4:"
    echo -e "     API REST   →  http://localhost:8000"
    echo -e "     Realtime   →  ws://localhost:4000/socket"
    echo -e "     Frontend   →  http://localhost:5173"
    echo ""
    echo -e "  ${BOLD}Útiles:${NC}"
    echo -e "  ├─ ./tools/migrate-postgres.sh {up|status|seed|reset}"
    echo -e "  ├─ ./tools/migrate-scylla.sh   {up|status|render|reset}"
    echo -e "  ├─ ./dev.sh stop     — para los contenedores"
    echo -e "  └─ ./dev.sh status   — estado actual"
    echo ""
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "${1:-up}" in
    up)     cmd_up "${2:-}" ;;
    seed)   cmd_up seed ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    reset)  cmd_reset ;;
    *)
        echo "uso: $0 {up|seed|stop|status|reset}"
        exit 1
        ;;
esac
