# ADR-0002: ScyllaDB para mensajes, PostgreSQL para estructura

- **Estado:** aceptada
- **Fecha:** 2026-07-29
- **Fase:** 1

## Contexto

El stack fija ScyllaDB como base principal y PostgreSQL como "fallback /
relacional". Hay que decidir el reparto concreto. Y hay que ser honesto sobre
una tensión de fondo: **para un grupo reducido de usuarios, PostgreSQL solo
bastaría de sobra.** Un canal de chat con decenas de miles de mensajes no
necesita un clúster distribuido.

## Decisión

Reparto por naturaleza del dato, no por volumen esperado:

**PostgreSQL** — datos con relaciones que deben mantenerse íntegras:
usuarios, dispositivos, tokens, servidores, canales, roles, membresías,
overwrites, claves públicas PQC, épocas y shares de clave, metadatos de
adjuntos.

**ScyllaDB** — flujos que se escriben mucho y se leen por rango temporal:
mensajes, estado de lectura, contadores de no leídos, reacciones, índice de
suscripciones, auditoría, telemetría de voz.

Regla dura: **ninguna consulta cruza las dos bases.** El único cruce es
`attachments.message_id`, deliberadamente sin restricción de integridad porque
no puede tenerla.

## Alternativas consideradas

**Solo PostgreSQL.** Técnicamente suficiente para el MVP y bastante más simple:
una base, transacciones de verdad, JOINs, búsqueda de texto completo si algún
día se quisiera. Descartada porque el stack fija Scylla y porque migrar
mensajes a Scylla *después*, con historial en producción y clientes que ya
paginan, es un proyecto entero. Hacerlo ahora, con el esquema vacío, es gratis.

**Solo ScyllaDB.** Obligaría a implementar a mano unicidad de username y email,
la resolución de permisos con JOINs, y las transacciones del flujo de subida de
adjuntos — usando LWT (Paxos), que en Cassandra/Scylla es caro y frágil. Se
perdería lo único que Postgres aporta aquí: garantías de integridad que evitan
que un canal quede ilegible por una fila inconsistente en el reparto de claves.

**Postgres como fuente de verdad y Scylla como caché de lectura.** Doble
escritura, dos sistemas que se desincronizan, y la pregunta permanente de cuál
tiene razón. Descartada: es la peor propiedad de los dos mundos.

## Consecuencias

**A favor**

- Cada dato vive donde su motor lo maneja bien: integridad en Postgres, escritura
  secuencial y lectura por rango en Scylla.
- La ruta de escritura de mensajes no compite por recursos con las consultas
  administrativas.
- El camino a multi-región ya está abierto: el keyspace usa
  `NetworkTopologyStrategy` y `LOCAL_QUORUM` desde el primer día, así que añadir
  un DC es infraestructura, no migración.

**En contra**

- **Dos bases de datos que operar, respaldar y monitorizar** para un producto
  que con una funcionaría. Es el coste principal y es real.
- Sin integridad referencial entre mensajes y usuarios: borrar un usuario no
  limpia sus mensajes en Scylla. Se resuelve con borrado en blando en Postgres
  (`users.deleted_at`), de modo que el `author_id` de un mensaje siempre resuelve
  a algo.
- Sin búsqueda de texto completo en servidor. Aquí el coste es cero: el E2EE ya
  la impedía.
- Los contadores de Scylla no son idempotentes, así que los badges de no leídos
  son aproximados. Aceptable para un badge; sería inaceptable para un saldo.

## Cuándo revisar esta decisión

Si el coste operativo de Scylla resulta desproporcionado para la escala real —
un escenario perfectamente plausible en este producto — mover
`messages_by_channel` a Postgres particionado por rango es viable: el esquema de
mensajes no usa nada exclusivo de Cassandra salvo los tipos `counter` y
`timeuuid`, ambos con equivalente directo en Postgres (`bigint` y `uuid v7`).
