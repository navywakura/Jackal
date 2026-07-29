-- =============================================================================
-- Jackal — 0002: mensajes
--
-- En Scylla el esquema lo dicta la consulta, no la entidad. Estas tablas
-- responden exactamente a cuatro patrones de acceso:
--
--   P1  últimos N mensajes de un canal              → messages_by_channel
--   P2  paginar hacia atrás desde un cursor         → messages_by_channel
--   P3  un mensaje por su id (editar, borrar, cita) → message_lookup
--   P4  ¿qué particiones tiene este canal?          → channel_buckets
--
-- NO se puede hacer con este esquema, y es deliberado:
--   · buscar por contenido  → imposible con E2EE; irá en un índice local
--   · listar por autor      → no es un caso de uso del MVP
-- Ambas cosas exigirían tablas adicionales; añadirlas "por si acaso" es pagar
-- escrituras hoy por lecturas que nadie hará.
-- =============================================================================

USE ${SCYLLA_KEYSPACE};

-- -----------------------------------------------------------------------------
-- messages_by_channel
--
-- Clave de partición: (channel_id, bucket) donde bucket = AAAAMM.
--
-- El bucket existe para acotar la partición. Sin él, un canal con años de
-- historia sería una única partición creciendo sin límite, que es la forma
-- clásica de dejar inservible un clúster de Cassandra/Scylla. Con AAAAMM y el
-- perfil de este producto (grupo reducido, ~4 KiB por mensaje: la firma híbrida
-- son 3373 B de esos) una partición
-- llena ronda los pocos MB, muy por debajo del umbral de 100 MB.
--
-- Si un canal llegara a superarlo, se pasa a bucket diario (AAAAMMDD) para los
-- buckets NUEVOS: el código de lectura ya recorre channel_buckets, así que
-- convive con los antiguos sin migrar nada.
--
-- CLUSTERING ORDER message_id DESC: la lectura más frecuente es "los últimos
-- 50", y así es un range scan desde el principio de la partición.
-- =============================================================================
CREATE TABLE IF NOT EXISTS messages_by_channel (
    channel_id       uuid,
    bucket           int,
    message_id       timeuuid,

    author_id        uuid,
    author_device_id uuid,

    -- 0 = usuario, 1 = sistema (altas/bajas), 2 = evento de llamada
    kind             tinyint,

    -- Carga cifrada. El servidor almacena y reenvía; no puede abrirla.
    key_epoch        int,
    ciphertext       blob,
    nonce            blob,

    -- Firma híbrida del emisor (ML-DSA-65 ‖ Ed25519) sobre el transcript.
    -- La verifica el CLIENTE receptor. El servidor no puede: no conoce las
    -- claves públicas de firma con autoridad, solo las sirve.
    sender_signature blob,
    sender_key_id    uuid,

    -- Metadatos en claro. Son el precio de tener notificaciones y respuestas
    -- sin descifrar en servidor. Filtran el grafo social del canal (quién
    -- responde a quién, a quién se menciona), no el contenido. Compromiso
    -- asumido y documentado en docs/fase-1/03-seguridad-pqc.md §6.
    reply_to         timeuuid,
    mentions         set<uuid>,
    mention_everyone boolean,
    attachment_ids   set<uuid>,

    edited_at        timestamp,
    deleted_at       timestamp,

    PRIMARY KEY ((channel_id, bucket), message_id)
) WITH CLUSTERING ORDER BY (message_id DESC)
  AND compaction = {
      'class': 'TimeWindowCompactionStrategy',
      'compaction_window_unit': 'DAYS',
      'compaction_window_size': 7
  }
  AND comment = 'Mensajes por canal y bucket mensual. Escritor: Phoenix.';

-- TWCS y no STCS porque la carga es casi pura escritura secuencial en el
-- tiempo: las SSTables viejas se vuelven inmutables de hecho y dejan de
-- compactarse. Las ediciones y borrados en blando son UPDATE sobre particiones
-- antiguas, que TWCS tolera mal en teoría — pero editar un mensaje de hace
-- semanas es raro, y a este volumen la fragmentación resultante es
-- irrelevante. Si el patrón cambiara, STCS sería la alternativa.

-- -----------------------------------------------------------------------------
-- message_lookup
--
-- Índice message_id → su ubicación. Necesario porque para tocar una fila de
-- messages_by_channel hace falta la clave de partición completa, y un cliente
-- que edita un mensaje solo tiene el id.
--
-- Es una tabla y no un índice secundario a propósito: un índice secundario
-- global obliga a consultar todos los nodos (scatter-gather). Esta tabla se
-- resuelve en un solo nodo.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS message_lookup (
    message_id timeuuid PRIMARY KEY,
    channel_id uuid,
    bucket     int,
    server_id  uuid,
    author_id  uuid
) WITH comment = 'message_id → (channel_id, bucket). Denormalización deliberada.';

-- -----------------------------------------------------------------------------
-- channel_buckets
--
-- Directorio de particiones no vacías de cada canal. Paginar hacia atrás
-- necesita saber cuál es el bucket anterior CON DATOS; sin este directorio
-- habría que probar mes a mes a ciegas, gastando una consulta por cada mes
-- inactivo. En un canal creado hace dos años y usado en ráfagas, eso es la
-- diferencia entre una consulta y veinte.
--
-- Partición diminuta (una fila por mes activo) y solo se escribe una vez al
-- mes por canal; el resto de escrituras son sobre una fila que ya existe.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS channel_buckets (
    channel_id    uuid,
    bucket        int,
    message_count counter,
    PRIMARY KEY (channel_id, bucket)
) WITH CLUSTERING ORDER BY (bucket DESC)
  AND comment = 'Buckets con datos por canal, del más reciente al más antiguo.';

-- -----------------------------------------------------------------------------
-- message_dedupe
--
-- Idempotencia del envío. El cliente genera un client_nonce (UUIDv4) antes de
-- enviar. Si el socket se cae entre el push y la confirmación, el reintento
-- trae el mismo nonce; Phoenix consulta aquí y devuelve el message_id original
-- en lugar de crear un duplicado.
--
-- Sin esto, cada reconexión con un envío en vuelo produce mensajes dobles —
-- que en un móvil con cobertura intermitente no es un caso raro.
--
-- TTL 24 h: pasado ese plazo un reintento ya no es plausible.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS message_dedupe (
    channel_id   uuid,
    client_nonce uuid,
    message_id   timeuuid,
    created_at   timestamp,
    PRIMARY KEY ((channel_id, client_nonce))
) WITH default_time_to_live = 86400
  AND gc_grace_seconds = 3600
  AND comment = 'Idempotencia de envío, TTL 24 h.';

-- -----------------------------------------------------------------------------
-- pinned_messages
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pinned_messages (
    channel_id uuid,
    message_id timeuuid,
    pinned_by  uuid,
    pinned_at  timestamp,
    bucket     int,
    PRIMARY KEY (channel_id, message_id)
) WITH CLUSTERING ORDER BY (message_id DESC)
  AND comment = 'Mensajes fijados. bucket se copia para poder ir a buscar el original.';
