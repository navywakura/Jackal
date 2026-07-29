# Jackal (RXchat)

Plataforma de comunicación en tiempo real para grupos reducidos: texto, voz y vídeo
P2P, con cifrado extremo a extremo resistente a computación cuántica.

> **Estado actual: FASE 1 completada** — arquitectura, contratos entre servicios y
> esquemas de base de datos. Sin código de aplicación todavía.

## Stack

| Capa | Tecnología | Responsabilidad |
|---|---|---|
| Frontend | React + TypeScript + Vite | UI, cliente WebRTC, criptografía de cliente (WASM) |
| Realtime | Elixir + Phoenix (Cowboy) | Phoenix Channels, presencia, fan-out de mensajes, señalización WebRTC |
| REST | Python + Flask | Autenticación, grupos/canales/roles, directorio de claves PQC, subidas |
| Media | WebRTC P2P (malla), Opus | Voz y vídeo cliente-a-cliente; el servidor solo señaliza |
| Hot data | ScyllaDB | Mensajes, estado de lectura, reacciones, auditoría, telemetría |
| Cold data | PostgreSQL | Usuarios, servidores, canales, roles, claves públicas, sesiones |
| Cripto | ML-KEM-768 + X25519, ML-DSA-65 + Ed25519 | KEM híbrido y firmas híbridas (FIPS 203/204) |

## Layout del repositorio

```
apps/
  web/          React + TypeScript          (FASE 4)
  realtime/     Elixir / Phoenix            (FASE 2)
  api/          Python / Flask              (FASE 3)
db/
  postgres/     Migraciones SQL + seed      ✅ FASE 1
  scylla/       Migraciones CQL             ✅ FASE 1
docs/
  fase-1/       Arquitectura y modelo de datos  ✅
  adr/          Architecture Decision Records  ✅
infra/          docker-compose, coturn      ✅ FASE 1
tools/          Runners de migraciones      ✅ FASE 1
```

## Arranque del entorno de desarrollo

```bash
cp .env.example .env
docker compose -f infra/docker-compose.yml up -d postgres scylla coturn

# Esperar a que Scylla acepte CQL (~30-60 s en el primer arranque)
docker compose -f infra/docker-compose.yml exec scylla cqlsh -e "DESCRIBE CLUSTER"

./tools/migrate-postgres.sh up
./tools/migrate-scylla.sh up

# Datos de prueba (opcional, solo desarrollo)
./tools/migrate-postgres.sh seed
```

## Documentación

Empieza por [`docs/README.md`](docs/README.md).

- [Arquitectura global y flujos de datos](docs/fase-1/01-arquitectura.md)
- [Modelo de datos (Postgres + Scylla)](docs/fase-1/02-modelo-de-datos.md)
- [Seguridad y pipeline PQC](docs/fase-1/03-seguridad-pqc.md)
- [Contratos entre servicios](docs/fase-1/04-contratos-entre-servicios.md)
- [Decisiones de arquitectura (ADR)](docs/adr/)

## Alcance del MVP

Explícitamente **dentro**: registro/login, perfiles, servidores, canales de texto y
voz, roles Admin/Miembro, mensajería en tiempo real persistida, voz/vídeo P2P en
malla, intercambio de claves PQC por canal.

Explícitamente **fuera**: SFU/MCU, federación, mensajes directos, búsqueda de
mensajes en servidor, hilos, notificaciones push móviles, verificación de
dispositivos out-of-band. Ver [ADR-0004](docs/adr/0004-webrtc-malla-p2p.md) para
los límites de la malla P2P.
