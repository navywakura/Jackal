# Documentación de Jackal (RXchat)

## Fases

| Fase | Contenido | Estado |
|---|---|---|
| **1** | Arquitectura, contratos entre servicios, esquemas de base de datos | ✅ completada |
| 2 | Backend de tiempo real en Elixir/Phoenix | pendiente |
| 3 | Microservicio Flask + criptografía PQC | pendiente |
| 4 | Frontend React + TypeScript + cliente WebRTC | pendiente |

## FASE 1 — orden de lectura

1. **[Arquitectura global](fase-1/01-arquitectura.md)** — componentes, flujos de
   datos, autenticación, envío de mensajes, señalización WebRTC, modos de fallo,
   presupuesto de latencia.
2. **[Modelo de datos](fase-1/02-modelo-de-datos.md)** — qué vive en Postgres y
   qué en Scylla, ER, resolución de permisos, estrategia de bucketing y
   compactación, y lo que el modelo **no** permite.
3. **[Seguridad y PQC](fase-1/03-seguridad-pqc.md)** — modelo de amenazas,
   jerarquía de claves, KEM híbrido, rotación de épocas, cifrado de mensajes y
   límites conocidos.
4. **[Contratos entre servicios](fase-1/04-contratos-entre-servicios.md)** — JWT,
   API REST, eventos de Phoenix Channels, API interna. Es lo que hay que
   congelar para que las FASES 2, 3 y 4 avancen en paralelo.

## Decisiones de arquitectura (ADR)

| ADR | Decisión |
|---|---|
| [0001](adr/0001-separacion-elixir-flask.md) | Separar tiempo real (Elixir) de REST (Python) por perfil de carga |
| [0002](adr/0002-scylla-mensajes-postgres-estructura.md) | Scylla para mensajes, Postgres para estructura |
| [0003](adr/0003-criptografia-hibrida-pqc.md) | Criptografía híbrida clásica + post-cuántica |
| [0004](adr/0004-webrtc-malla-p2p.md) | Malla WebRTC P2P con tope de 8, sin SFU |

Cada ADR incluye las alternativas descartadas y **cuándo habría que revisar la
decisión**. Esa última sección es la parte útil cuando alguien se pregunta,
dentro de seis meses, por qué el sistema es como es.

## Esquemas

| Fichero | Contenido |
|---|---|
| [`db/postgres/migrations/`](../db/postgres/migrations/) | 4 migraciones: identidad, estructura, claves PQC, adjuntos y grants |
| [`db/postgres/seed/`](../db/postgres/seed/) | Datos de desarrollo (3 usuarios, 3 roles, 3 canales) |
| [`db/postgres/tests/`](../db/postgres/tests/) | 25 comprobaciones de restricciones |
| [`db/scylla/migrations/`](../db/scylla/migrations/) | 4 migraciones: keyspace, mensajes, lectura, auditoría |
| [`db/scylla/tests/`](../db/scylla/tests/) | Verificación de los patrones de acceso |

## Estado de validación de la FASE 1

| Artefacto | Cómo se verificó |
|---|---|
| Migraciones PostgreSQL | Ejecutadas contra PostgreSQL 16.13 real |
| Restricciones y triggers | 25 aserciones, cada una comprobando que un dato inválido se rechaza |
| Vista de permisos | Verificada con los datos del seed |
| Migraciones CQL | Ejecutadas contra Apache Cassandra 5.0.6 (compatible en CQL con Scylla) |
| Patrones de acceso Scylla | Cada consulta de producción ejecutada; ninguna necesita `ALLOW FILTERING` |
| `docker-compose.yml` | **No verificado** — no había daemon de Docker en el entorno |

El CQL se validó contra Cassandra, no contra Scylla. Las construcciones usadas
(TWCS, LCS, `counter`, `timeuuid`, clustering `DESC`, TTL por tabla) son comunes
a ambos, pero conviene ejecutar `./tools/migrate-scylla.sh up` contra un Scylla
real antes de dar la FASE 1 por cerrada.
