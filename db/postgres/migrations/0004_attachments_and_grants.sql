-- =============================================================================
-- Jackal — 0004: adjuntos, vistas de apoyo y roles de base de datos
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- attachments
--
-- Los bytes viven en object storage; aquí solo los metadatos. El archivo se
-- sube ya cifrado con una clave por adjunto, que a su vez viaja dentro del
-- cuerpo cifrado del mensaje. El servidor no puede abrir el contenido ni
-- conoce el nombre real del fichero (filename_ciphertext).
--
-- Ciclo de vida: Flask crea la fila en estado 'pending' y devuelve una URL
-- prefirmada. El cliente sube, confirma, y la fila pasa a 'ready'. Las
-- 'pending' con más de 24 h se recogen con un job de limpieza.
-- -----------------------------------------------------------------------------
CREATE TYPE attachment_state AS ENUM ('pending', 'ready', 'failed', 'deleted');

CREATE TABLE attachments (
    id                  uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
    channel_id          uuid             NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    uploader_id         uuid             NOT NULL REFERENCES users(id)    ON DELETE CASCADE,

    -- timeuuid del mensaje en Scylla, como texto. NO hay FK: la tabla de
    -- mensajes vive en otra base de datos. Se rellena al confirmar el envío.
    message_id          text,

    storage_key         text             NOT NULL,
    byte_size           bigint           NOT NULL,
    content_type        text             NOT NULL DEFAULT 'application/octet-stream',

    -- Nombre original cifrado con la CEK del canal; el servidor no lo ve.
    filename_ciphertext bytea            NOT NULL,
    filename_nonce      bytea            NOT NULL,
    key_epoch           integer          NOT NULL,

    -- SHA-256 del blob YA CIFRADO. Sirve para deduplicar y para que el
    -- receptor verifique integridad antes de descifrar.
    ciphertext_sha256   bytea            NOT NULL,

    state               attachment_state NOT NULL DEFAULT 'pending',
    created_at          timestamptz      NOT NULL DEFAULT now(),
    confirmed_at        timestamptz,
    deleted_at          timestamptz,

    CONSTRAINT attachments_size_range  CHECK (byte_size > 0 AND byte_size <= 104857600), -- 100 MiB
    CONSTRAINT attachments_sha_len     CHECK (octet_length(ciphertext_sha256) = 32),
    CONSTRAINT attachments_nonce_len   CHECK (octet_length(filename_nonce) = 24),
    CONSTRAINT attachments_epoch       CHECK (key_epoch >= 0),
    CONSTRAINT attachments_ready_has_msg
        CHECK (state <> 'ready' OR (message_id IS NOT NULL AND confirmed_at IS NOT NULL))
);

CREATE INDEX attachments_message_idx ON attachments (message_id) WHERE message_id IS NOT NULL;
CREATE INDEX attachments_gc_idx      ON attachments (created_at) WHERE state = 'pending';
CREATE UNIQUE INDEX attachments_storage_key_key ON attachments (storage_key);

COMMENT ON COLUMN attachments.message_id IS
    'timeuuid del mensaje en ScyllaDB, en texto. Sin FK: cruza el límite de base de datos.';

-- -----------------------------------------------------------------------------
-- Vista de permisos efectivos a nivel de servidor.
--
-- Resuelve las dos primeras capas (owner, @everyone, roles del miembro). La
-- tercera capa (overwrites por canal) se aplica en el servicio, porque depende
-- del canal concreto que se esté evaluando.
--
-- Phoenix la consulta al abrirse un socket y cachea el resultado en ETS 60 s.
-- -----------------------------------------------------------------------------
CREATE VIEW member_server_permissions AS
SELECT
    sm.server_id,
    sm.user_id,
    s.owner_id = sm.user_id                                   AS is_owner,
    CASE
        WHEN s.owner_id = sm.user_id THEN permissions_mask_all()
        ELSE coalesce(bit_or(r.permissions), 0)
    END                                                       AS permissions,
    u.permissions_version
FROM server_members sm
JOIN servers s ON s.id = sm.server_id AND s.deleted_at IS NULL
JOIN users   u ON u.id = sm.user_id   AND u.deleted_at IS NULL
LEFT JOIN roles r
       ON r.server_id = sm.server_id
      AND (r.is_default OR r.id IN (
              SELECT mr.role_id FROM member_roles mr
               WHERE mr.server_id = sm.server_id AND mr.user_id = sm.user_id
          ))
WHERE NOT sm.is_banned
GROUP BY sm.server_id, sm.user_id, s.owner_id, u.permissions_version;

COMMENT ON VIEW member_server_permissions IS
    'Capas 1-2 de la resolución de permisos. Los overwrites de canal se aplican '
    'en la aplicación. Ver docs/fase-1/02-modelo-de-datos.md §4.';

-- -----------------------------------------------------------------------------
-- Roles de base de datos
--
-- jackal_app : el servicio Flask. Único escritor.
-- jackal_ro  : el servicio Phoenix. Solo lectura, y solo sobre lo que necesita
--              para autorizar. No ve password_hash ni refresh_tokens.
--
-- Las contraseñas se asignan fuera de la migración (ALTER ROLE ... PASSWORD)
-- para no dejarlas en el historial de git.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jackal_app') THEN
        CREATE ROLE jackal_app LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jackal_ro') THEN
        CREATE ROLE jackal_ro LOGIN;
    END IF;
END;
$$;

GRANT USAGE ON SCHEMA public TO jackal_app, jackal_ro;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO jackal_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO jackal_app;

-- Phoenix: lectura estricta sobre el subconjunto de autorización y claves.
-- Sobre users el GRANT es por COLUMNAS: password_hash y email quedan fuera del
-- alcance del servicio de tiempo real, que no los necesita para nada.
GRANT SELECT (
    id, username, display_name, avatar_url, status_message,
    permissions_version, is_active, is_system, last_seen_at, deleted_at
) ON users TO jackal_ro;

GRANT SELECT ON
    user_devices,
    servers,
    roles,
    server_members,
    member_roles,
    channels,
    channel_categories,
    channel_permission_overwrites,
    permission_bits,
    device_keys,
    channel_key_epochs,
    jwt_signing_keys,
    member_server_permissions
TO jackal_ro;

-- Explícito por si un GRANT genérico se cuela en el futuro.
REVOKE ALL ON refresh_tokens, invites, attachments, channel_key_shares FROM jackal_ro;

COMMENT ON SCHEMA public IS
    'Jackal — escritor único: jackal_app (Flask). jackal_ro (Phoenix) es de solo lectura.';

COMMIT;
