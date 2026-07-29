-- =============================================================================
-- Jackal — 0003: estado de lectura, no leídos y reacciones
-- =============================================================================

USE ${SCYLLA_KEYSPACE};

-- -----------------------------------------------------------------------------
-- channel_read_state
--
-- Partición por usuario: al abrir la aplicación, "dame mi estado de lectura de
-- todos los canales" es UNA sola lectura de partición. Si la clave fuera
-- (channel_id, user_id) haría falta una consulta por canal.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS channel_read_state (
    user_id              uuid,
    channel_id           uuid,
    last_read_message_id timeuuid,
    last_read_at         timestamp,
    muted                boolean,
    PRIMARY KEY (user_id, channel_id)
) WITH compaction = {'class': 'LeveledCompactionStrategy'}
  AND comment = 'Marcador de lectura por usuario y canal. Sobrescritura frecuente.';

-- LCS y no TWCS: cada fila se sobrescribe muchas veces (cada vez que el usuario
-- lee) y nunca crece. LCS mantiene bajo el número de SSTables que hay que tocar
-- para leer, que es justo lo que importa aquí.

-- -----------------------------------------------------------------------------
-- channel_unread_counters
--
-- Tabla separada porque en CQL una tabla con columnas counter no puede tener
-- ninguna otra columna no-counter fuera de la clave primaria. No es una
-- decisión de diseño: es una restricción del motor.
--
-- Los contadores en Cassandra/Scylla no son idempotentes: un reintento tras un
-- timeout puede contar dos veces. Es aceptable para un badge de no leídos —
-- se corrige solo en cuanto el usuario abre el canal, que hace un reset.
-- Para algo que exigiera exactitud, este sería el enfoque equivocado.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS channel_unread_counters (
    user_id      uuid,
    channel_id   uuid,
    unread_count counter,
    mention_count counter,
    PRIMARY KEY (user_id, channel_id)
) WITH comment = 'Badges de no leídos. Aproximados por diseño; el reset los corrige.';

-- -----------------------------------------------------------------------------
-- reactions_by_message
--
-- Partición por mensaje: al renderizar se piden las reacciones de los mensajes
-- visibles, uno a uno. El clustering (emoji, user_id) permite además contar por
-- emoji sin leer la partición entera.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reactions_by_message (
    message_id uuid,
    emoji      text,
    user_id    uuid,
    reacted_at timestamp,
    PRIMARY KEY (message_id, emoji, user_id)
) WITH CLUSTERING ORDER BY (emoji ASC, user_id ASC)
  AND compaction = {'class': 'LeveledCompactionStrategy'}
  AND comment = 'Reacciones. Alta rotación de inserciones y borrados → LCS.';

-- -----------------------------------------------------------------------------
-- user_channel_index
--
-- Qué canales debe suscribir un usuario al conectarse. Es una denormalización
-- de datos que viven en PostgreSQL (server_members × channels), mantenida por
-- Phoenix cuando Flask le notifica un cambio de membresía.
--
-- Existe para que abrir un socket NO tenga que consultar PostgreSQL: la ruta
-- caliente no depende de la fría. Si esta tabla se desincroniza, la
-- consecuencia es que un canal aparece o falta en la barra lateral; la
-- autorización real se sigue comprobando contra PostgreSQL al hacer join, así
-- que una entrada obsoleta aquí no concede acceso a nada.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_channel_index (
    user_id    uuid,
    server_id  uuid,
    channel_id uuid,
    kind       tinyint,     -- 0 = texto, 1 = voz
    updated_at timestamp,
    PRIMARY KEY (user_id, server_id, channel_id)
) WITH comment = 'Caché de suscripciones. NO es autoritativa para autorización.';
