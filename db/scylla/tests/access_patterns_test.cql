-- =============================================================================
-- Jackal — verificación de los patrones de acceso de ScyllaDB
--
--   cqlsh -f db/scylla/tests/access_patterns_test.cql
--
-- No es una prueba automatizada con aserciones: CQL no tiene forma de expresar
-- "esto debe fallar". Lo que hace es ejecutar exactamente las consultas que los
-- servicios harán en producción, para comprobar que el esquema las soporta sin
-- ALLOW FILTERING y con el orden correcto. Revisar la salida a ojo.
--
-- Usa el keyspace jackal_test para no tocar datos reales.
-- =============================================================================

DROP KEYSPACE IF EXISTS jackal_test;
CREATE KEYSPACE jackal_test
WITH replication = {'class': 'NetworkTopologyStrategy', 'datacenter1': 1};

USE jackal_test;

CREATE TABLE messages_by_channel (
    channel_id uuid, bucket int, message_id timeuuid,
    author_id uuid, author_device_id uuid, kind tinyint,
    key_epoch int, ciphertext blob, nonce blob,
    sender_signature blob, sender_key_id uuid,
    reply_to timeuuid, mentions set<uuid>, mention_everyone boolean,
    attachment_ids set<uuid>, edited_at timestamp, deleted_at timestamp,
    PRIMARY KEY ((channel_id, bucket), message_id)
) WITH CLUSTERING ORDER BY (message_id DESC);

CREATE TABLE message_lookup (
    message_id timeuuid PRIMARY KEY,
    channel_id uuid, bucket int, server_id uuid, author_id uuid);

CREATE TABLE channel_buckets (
    channel_id uuid, bucket int, message_count counter,
    PRIMARY KEY (channel_id, bucket)
) WITH CLUSTERING ORDER BY (bucket DESC);

CREATE TABLE channel_read_state (
    user_id uuid, channel_id uuid, last_read_message_id timeuuid,
    last_read_at timestamp, muted boolean,
    PRIMARY KEY (user_id, channel_id));

CREATE TABLE channel_unread_counters (
    user_id uuid, channel_id uuid, unread_count counter, mention_count counter,
    PRIMARY KEY (user_id, channel_id));

CREATE TABLE reactions_by_message (
    message_id uuid, emoji text, user_id uuid, reacted_at timestamp,
    PRIMARY KEY (message_id, emoji, user_id));

CREATE TABLE message_dedupe (
    channel_id uuid, client_nonce uuid, message_id timeuuid, created_at timestamp,
    PRIMARY KEY ((channel_id, client_nonce))
) WITH default_time_to_live = 86400;

-- -----------------------------------------------------------------------------
-- Datos: un canal con mensajes repartidos en dos buckets mensuales.
-- Los timeuuid van escritos a mano con timestamps crecientes para que el orden
-- sea comprobable a simple vista (los dos primeros grupos hex son el tiempo).
-- -----------------------------------------------------------------------------
INSERT INTO messages_by_channel (channel_id, bucket, message_id, author_id, kind, key_epoch, ciphertext, mentions)
VALUES (11111111-1111-4111-8111-111111111111, 202606,
        10000000-0000-1000-8000-000000000001, 22222222-2222-4222-8222-222222222222,
        0, 3, 0x4a31, {33333333-3333-4333-8333-333333333333});
INSERT INTO messages_by_channel (channel_id, bucket, message_id, author_id, kind, key_epoch, ciphertext)
VALUES (11111111-1111-4111-8111-111111111111, 202606,
        20000000-0000-1000-8000-000000000002, 22222222-2222-4222-8222-222222222222, 0, 3, 0x4a32);
INSERT INTO messages_by_channel (channel_id, bucket, message_id, author_id, kind, key_epoch, ciphertext)
VALUES (11111111-1111-4111-8111-111111111111, 202607,
        30000000-0000-1000-8000-000000000003, 22222222-2222-4222-8222-222222222222, 0, 4, 0x4a33);
INSERT INTO messages_by_channel (channel_id, bucket, message_id, author_id, kind, key_epoch, ciphertext)
VALUES (11111111-1111-4111-8111-111111111111, 202607,
        40000000-0000-1000-8000-000000000004, 33333333-3333-4333-8333-333333333333, 0, 4, 0x4a34);
INSERT INTO messages_by_channel (channel_id, bucket, message_id, author_id, kind, key_epoch, ciphertext)
VALUES (11111111-1111-4111-8111-111111111111, 202607,
        50000000-0000-1000-8000-000000000005, 22222222-2222-4222-8222-222222222222, 0, 4, 0x4a35);

UPDATE channel_buckets SET message_count = message_count + 2
 WHERE channel_id = 11111111-1111-4111-8111-111111111111 AND bucket = 202606;
UPDATE channel_buckets SET message_count = message_count + 3
 WHERE channel_id = 11111111-1111-4111-8111-111111111111 AND bucket = 202607;

INSERT INTO message_lookup (message_id, channel_id, bucket, author_id)
VALUES (40000000-0000-1000-8000-000000000004, 11111111-1111-4111-8111-111111111111,
        202607, 33333333-3333-4333-8333-333333333333);

-- =============================================================================
-- P4 — ¿qué buckets tiene este canal? (más reciente primero)
--      Espera: 202607 con 3, luego 202606 con 2.
-- =============================================================================
SELECT bucket, message_count FROM channel_buckets
 WHERE channel_id = 11111111-1111-4111-8111-111111111111;

-- =============================================================================
-- P1 — carga inicial: los 2 últimos del bucket más reciente.
--      Espera: 5000…0005 y luego 4000…0004 (orden DESC).
-- =============================================================================
SELECT message_id, author_id, key_epoch FROM messages_by_channel
 WHERE channel_id = 11111111-1111-4111-8111-111111111111
   AND bucket = 202607
 LIMIT 2;

-- =============================================================================
-- P2 — paginar hacia atrás desde un cursor, dentro del mismo bucket.
--      Espera: solo 3000…0003.
-- =============================================================================
SELECT message_id FROM messages_by_channel
 WHERE channel_id = 11111111-1111-4111-8111-111111111111
   AND bucket = 202607
   AND message_id < 40000000-0000-1000-8000-000000000004;

-- =============================================================================
-- P2b — bucket agotado: se salta al anterior que da channel_buckets.
--       Espera: 2000…0002 y 1000…0001.
-- =============================================================================
SELECT message_id FROM messages_by_channel
 WHERE channel_id = 11111111-1111-4111-8111-111111111111
   AND bucket = 202606;

-- =============================================================================
-- P3 — un mensaje por su id, sin conocer la partición.
--      Espera: una fila con bucket 202607.
-- =============================================================================
SELECT channel_id, bucket FROM message_lookup
 WHERE message_id = 40000000-0000-1000-8000-000000000004;

-- =============================================================================
-- Estado de lectura: toda la partición del usuario de una sola vez.
-- =============================================================================
INSERT INTO channel_read_state (user_id, channel_id, last_read_message_id, last_read_at, muted)
VALUES (33333333-3333-4333-8333-333333333333, 11111111-1111-4111-8111-111111111111,
        30000000-0000-1000-8000-000000000003, toTimestamp(now()), false);
UPDATE channel_unread_counters SET unread_count = unread_count + 2, mention_count = mention_count + 1
 WHERE user_id = 33333333-3333-4333-8333-333333333333
   AND channel_id = 11111111-1111-4111-8111-111111111111;

SELECT channel_id, last_read_message_id, muted FROM channel_read_state
 WHERE user_id = 33333333-3333-4333-8333-333333333333;
SELECT channel_id, unread_count, mention_count FROM channel_unread_counters
 WHERE user_id = 33333333-3333-4333-8333-333333333333;

-- Reset al abrir el canal: es lo que corrige la imprecisión de los contadores.
UPDATE channel_unread_counters SET unread_count = unread_count - 2, mention_count = mention_count - 1
 WHERE user_id = 33333333-3333-4333-8333-333333333333
   AND channel_id = 11111111-1111-4111-8111-111111111111;
SELECT channel_id, unread_count, mention_count FROM channel_unread_counters
 WHERE user_id = 33333333-3333-4333-8333-333333333333;

-- =============================================================================
-- Reacciones: partición por mensaje, agrupadas por emoji.
-- =============================================================================
INSERT INTO reactions_by_message (message_id, emoji, user_id, reacted_at)
VALUES (40000000-0000-1000-8000-000000000004, ':+1:',
        22222222-2222-4222-8222-222222222222, toTimestamp(now()));
INSERT INTO reactions_by_message (message_id, emoji, user_id, reacted_at)
VALUES (40000000-0000-1000-8000-000000000004, ':+1:',
        33333333-3333-4333-8333-333333333333, toTimestamp(now()));
INSERT INTO reactions_by_message (message_id, emoji, user_id, reacted_at)
VALUES (40000000-0000-1000-8000-000000000004, ':tada:',
        22222222-2222-4222-8222-222222222222, toTimestamp(now()));

SELECT emoji, count(*) FROM reactions_by_message
 WHERE message_id = 40000000-0000-1000-8000-000000000004
 GROUP BY emoji;

-- Slice por emoji concreto, sin leer la partición entera.
SELECT user_id FROM reactions_by_message
 WHERE message_id = 40000000-0000-1000-8000-000000000004 AND emoji = ':+1:';

-- =============================================================================
-- Idempotencia: el reintento encuentra el message_id original.
-- =============================================================================
INSERT INTO message_dedupe (channel_id, client_nonce, message_id, created_at)
VALUES (11111111-1111-4111-8111-111111111111, 99999999-9999-4999-8999-999999999999,
        50000000-0000-1000-8000-000000000005, toTimestamp(now()));

SELECT message_id FROM message_dedupe
 WHERE channel_id = 11111111-1111-4111-8111-111111111111
   AND client_nonce = 99999999-9999-4999-8999-999999999999;

-- =============================================================================
-- Borrado en blando: la fila permanece, el cliente decide cómo mostrarla.
-- =============================================================================
UPDATE messages_by_channel SET deleted_at = toTimestamp(now()), ciphertext = null
 WHERE channel_id = 11111111-1111-4111-8111-111111111111
   AND bucket = 202607
   AND message_id = 30000000-0000-1000-8000-000000000003;

SELECT message_id, ciphertext, deleted_at FROM messages_by_channel
 WHERE channel_id = 11111111-1111-4111-8111-111111111111 AND bucket = 202607;

DROP KEYSPACE jackal_test;
