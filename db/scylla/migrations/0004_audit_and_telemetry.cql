-- =============================================================================
-- Jackal — 0004: auditoría y telemetría
--
-- Todo lo de este fichero lleva TTL. Son datos operativos, no de producto: se
-- consultan durante una investigación y luego dejan de importar. Sin TTL, esto
-- sería lo que acabaría llenando el disco del clúster.
-- =============================================================================

USE ${SCYLLA_KEYSPACE};

-- -----------------------------------------------------------------------------
-- server_audit_log — quién hizo qué en la administración de un servidor
--
-- TTL 90 días. Nada aquí contiene contenido de mensajes.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS server_audit_log (
    server_id   uuid,
    bucket      int,          -- AAAAMM
    event_id    timeuuid,
    actor_id    uuid,
    action      text,         -- 'channel.create', 'member.kick', 'role.update', ...
    target_type text,         -- 'channel' | 'member' | 'role' | 'server' | 'invite'
    target_id   uuid,
    metadata    map<text, text>,
    PRIMARY KEY ((server_id, bucket), event_id)
) WITH CLUSTERING ORDER BY (event_id DESC)
  AND default_time_to_live = 7776000
  AND compaction = {
      'class': 'TimeWindowCompactionStrategy',
      'compaction_window_unit': 'DAYS',
      'compaction_window_size': 7
  }
  AND comment = 'Auditoría administrativa, TTL 90 días.';

-- Con TWCS y TTL uniforme, una SSTable entera caduca a la vez y se descarta
-- sin compactar. Es la razón principal para usar TWCS en tablas con TTL.

-- -----------------------------------------------------------------------------
-- voice_session_events — diagnóstico de WebRTC
--
-- Sin esto, depurar "a veces no se oye a Beto" es imposible: los fallos de
-- WebRTC ocurren entre navegadores y el servidor no los ve. Registrar las
-- transiciones de ICE es lo que permite distinguir un NAT simétrico de un TURN
-- mal configurado de un problema de dispositivo.
--
-- TTL 7 días: un problema de conectividad se investiga en caliente o no se
-- investiga.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS voice_session_events (
    channel_id  uuid,
    day_bucket  int,          -- AAAAMMDD
    event_id    timeuuid,
    user_id     uuid,
    peer_id     uuid,
    -- 'join','leave','offer','answer','ice_candidate','ice_state','dtls_state',
    -- 'renegotiate','relay_used','failed'
    event       text,
    ice_state   text,
    -- 'host' | 'srflx' | 'relay' — si esto es 'relay' con frecuencia, el TURN
    -- está soportando tráfico que debería ir P2P.
    candidate_type text,
    metadata    map<text, text>,
    PRIMARY KEY ((channel_id, day_bucket), event_id)
) WITH CLUSTERING ORDER BY (event_id DESC)
  AND default_time_to_live = 604800
  AND compaction = {
      'class': 'TimeWindowCompactionStrategy',
      'compaction_window_unit': 'HOURS',
      'compaction_window_size': 6
  }
  AND comment = 'Telemetría de señalización WebRTC, TTL 7 días.';

-- -----------------------------------------------------------------------------
-- voice_session_summary — una fila por participación en una llamada
--
-- Alimenta "Beto estuvo en la llamada 42 minutos" y las métricas de calidad
-- agregadas. TTL 30 días.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS voice_session_summary (
    channel_id       uuid,
    day_bucket       int,
    session_id       timeuuid,
    user_id          uuid,
    joined_at        timestamp,
    left_at          timestamp,
    duration_seconds int,
    peer_count_max   int,
    used_relay       boolean,
    codec            text,
    packets_lost_pct float,
    jitter_ms_p95    float,
    PRIMARY KEY ((channel_id, day_bucket), session_id, user_id)
) WITH CLUSTERING ORDER BY (session_id DESC, user_id ASC)
  AND default_time_to_live = 2592000
  AND comment = 'Resumen por participante y llamada, TTL 30 días.';

-- -----------------------------------------------------------------------------
-- key_epoch_delivery — trazabilidad del reparto de claves
--
-- El material criptográfico vive en PostgreSQL; esto solo registra que un
-- dispositivo recogió y descifró correctamente la clave de una época. Sirve
-- para diagnosticar el fallo más molesto de un sistema E2EE: "no puedo leer
-- estos mensajes" porque un share nunca llegó.
--
-- TTL 30 días.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS key_epoch_delivery (
    channel_id  uuid,
    epoch       int,
    device_id   uuid,
    user_id     uuid,
    fetched_at  timestamp,
    unwrapped_ok boolean,
    error_code  text,
    PRIMARY KEY ((channel_id, epoch), device_id)
) WITH default_time_to_live = 2592000
  AND comment = 'Confirmación de recogida de clave por dispositivo. Sin material secreto.';
