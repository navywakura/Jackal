-- =============================================================================
-- Jackal — 0002: servidores (grupos), canales, roles y permisos
--
-- Modelo de permisos: máscara de bits de 64 bits, resuelta en tres capas
--   1. rol @everyone del servidor
--   2. OR de los roles asignados al miembro
--   3. overwrites por canal (deny, luego allow; rol antes que usuario)
-- El algoritmo completo está en docs/fase-1/02-modelo-de-datos.md §4.
-- =============================================================================

BEGIN;

CREATE TYPE channel_kind AS ENUM ('text', 'voice');

-- -----------------------------------------------------------------------------
-- Catálogo de bits de permiso.
--
-- Es una tabla real, no un enum ni una constante en el código, por dos razones:
-- la UI de administración necesita listar permisos con etiquetas legibles, y
-- una restricción FK impide que un bit inventado entre en la base de datos.
-- -----------------------------------------------------------------------------
CREATE TABLE permission_bits (
    bit         smallint    PRIMARY KEY,
    code        text        NOT NULL UNIQUE,
    label_es    text        NOT NULL,
    scope       text        NOT NULL,
    description text        NOT NULL DEFAULT '',

    CONSTRAINT permission_bits_range CHECK (bit BETWEEN 0 AND 62),
    CONSTRAINT permission_bits_scope CHECK (scope IN ('server', 'channel', 'both'))
);

INSERT INTO permission_bits (bit, code, label_es, scope, description) VALUES
    ( 0, 'ADMINISTRATOR',    'Administrador',           'server',  'Concede todos los permisos e ignora los overwrites de canal.'),
    ( 1, 'VIEW_CHANNEL',     'Ver canal',               'both',    'Ver el canal y leer su histórico.'),
    ( 2, 'SEND_MESSAGES',    'Enviar mensajes',         'channel', 'Publicar en canales de texto.'),
    ( 3, 'MANAGE_MESSAGES',  'Gestionar mensajes',      'channel', 'Borrar mensajes de otros y fijar mensajes.'),
    ( 4, 'ATTACH_FILES',     'Adjuntar archivos',       'channel', 'Subir adjuntos.'),
    ( 5, 'MENTION_EVERYONE', 'Mencionar a todos',       'channel', 'Usar @everyone / @here.'),
    ( 6, 'CONNECT_VOICE',    'Conectar a voz',          'channel', 'Entrar en canales de voz.'),
    ( 7, 'SPEAK',            'Hablar',                  'channel', 'Transmitir audio en canales de voz.'),
    ( 8, 'VIDEO',            'Vídeo',                   'channel', 'Transmitir vídeo o compartir pantalla.'),
    ( 9, 'MUTE_MEMBERS',     'Silenciar miembros',      'channel', 'Silenciar a otros en canales de voz.'),
    (10, 'MANAGE_CHANNELS',  'Gestionar canales',       'server',  'Crear, editar y borrar canales.'),
    (11, 'MANAGE_ROLES',     'Gestionar roles',         'server',  'Crear roles y asignarlos por debajo del propio.'),
    (12, 'KICK_MEMBERS',     'Expulsar miembros',       'server',  'Expulsar miembros del servidor.'),
    (13, 'BAN_MEMBERS',      'Vetar miembros',          'server',  'Vetar miembros e impedirles volver.'),
    (14, 'CREATE_INVITE',    'Crear invitaciones',      'server',  'Generar códigos de invitación.'),
    (15, 'MANAGE_SERVER',    'Gestionar servidor',      'server',  'Cambiar nombre, icono y ajustes del servidor.'),
    (16, 'ROTATE_CHANNEL_KEY','Rotar clave de canal',   'channel', 'Iniciar una nueva época de clave E2EE.');

COMMENT ON TABLE permission_bits IS
    'Catálogo de bits. La columna permissions de roles/overwrites es (1 << bit) sumados.';

-- -----------------------------------------------------------------------------
-- Validación de máscaras.
--
-- La constante está escrita a mano y NO se deriva de permission_bits: una
-- restricción CHECK que consulta otra tabla no es determinista y rompe en
-- restauraciones de pg_dump (el orden de carga no está garantizado). El bloque
-- DO de abajo verifica en tiempo de migración que la constante y el catálogo
-- coinciden, así que la duplicación no puede desincronizarse en silencio.
--
-- Al añadir un bit nuevo: insertar en permission_bits Y actualizar esta función.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION permissions_mask_all()
RETURNS bigint
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
AS $$
    SELECT 131071::bigint;   -- bits 0..16 → (1 << 17) - 1
$$;

CREATE OR REPLACE FUNCTION permissions_mask_is_valid(mask bigint)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
AS $$
    SELECT mask >= 0 AND (mask & ~permissions_mask_all()) = 0;
$$;

DO $$
DECLARE
    catalog_mask bigint;
BEGIN
    SELECT coalesce(sum(1::bigint << bit), 0) INTO catalog_mask FROM permission_bits;
    IF catalog_mask <> permissions_mask_all() THEN
        RAISE EXCEPTION
            'permission_bits (máscara %) y permissions_mask_all() (%) no coinciden',
            catalog_mask, permissions_mask_all();
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- servers (los "grupos" del enunciado)
-- -----------------------------------------------------------------------------
CREATE TABLE servers (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name         text        NOT NULL,
    slug         citext      NOT NULL,
    description  text        NOT NULL DEFAULT '',
    icon_url     text,

    owner_id     uuid        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,

    -- Tope de la malla WebRTC para todos los canales de voz del servidor.
    -- Ver ADR-0004: por encima de 8 la malla P2P deja de ser viable.
    max_voice_participants smallint NOT NULL DEFAULT 8,
    member_limit smallint    NOT NULL DEFAULT 50,

    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at   timestamptz,

    CONSTRAINT servers_name_len   CHECK (length(name) BETWEEN 2 AND 64),
    CONSTRAINT servers_slug_fmt   CHECK (slug OPERATOR(pg_catalog.~) '^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$'),
    CONSTRAINT servers_desc_len   CHECK (length(description) <= 500),
    CONSTRAINT servers_voice_cap  CHECK (max_voice_participants BETWEEN 2 AND 8),
    CONSTRAINT servers_member_cap CHECK (member_limit BETWEEN 1 AND 500)
);

CREATE UNIQUE INDEX servers_slug_key ON servers (slug) WHERE deleted_at IS NULL;
CREATE INDEX servers_owner_idx ON servers (owner_id);

CREATE TRIGGER servers_set_updated_at
    BEFORE UPDATE ON servers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- roles
--
-- position define la jerarquía: solo puedes asignar o editar roles con position
-- estrictamente menor que la del rol más alto que posees. El rol @everyone es
-- is_default = true y siempre ocupa position 0.
-- -----------------------------------------------------------------------------
CREATE TABLE roles (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    server_id    uuid        NOT NULL REFERENCES servers(id) ON DELETE CASCADE,

    name         text        NOT NULL,
    color        integer     NOT NULL DEFAULT 0,
    position     smallint    NOT NULL DEFAULT 0,
    permissions  bigint      NOT NULL DEFAULT 0,

    is_default   boolean     NOT NULL DEFAULT false,
    is_hoisted   boolean     NOT NULL DEFAULT false,
    is_mentionable boolean   NOT NULL DEFAULT true,

    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT roles_name_len  CHECK (length(name) BETWEEN 1 AND 32),
    CONSTRAINT roles_color_rgb CHECK (color BETWEEN 0 AND 16777215),
    CONSTRAINT roles_position  CHECK (position BETWEEN 0 AND 250),
    CONSTRAINT roles_perms     CHECK (permissions_mask_is_valid(permissions)),
    CONSTRAINT roles_default_at_zero CHECK (NOT is_default OR position = 0)
);

CREATE UNIQUE INDEX roles_server_name_key ON roles (server_id, lower(name));
-- Exactamente un rol @everyone por servidor.
CREATE UNIQUE INDEX roles_one_default_per_server ON roles (server_id) WHERE is_default;
CREATE INDEX roles_server_position_idx ON roles (server_id, position DESC);

CREATE TRIGGER roles_set_updated_at
    BEFORE UPDATE ON roles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- server_members
-- -----------------------------------------------------------------------------
CREATE TABLE server_members (
    server_id  uuid        NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    user_id    uuid        NOT NULL REFERENCES users(id)   ON DELETE CASCADE,

    nickname   text,
    joined_at  timestamptz NOT NULL DEFAULT now(),
    invited_by uuid        REFERENCES users(id) ON DELETE SET NULL,

    is_banned  boolean     NOT NULL DEFAULT false,
    banned_at  timestamptz,
    ban_reason text,

    PRIMARY KEY (server_id, user_id),
    CONSTRAINT server_members_nick_len CHECK (nickname IS NULL OR length(nickname) BETWEEN 1 AND 32),
    CONSTRAINT server_members_ban_consistency
        CHECK ((is_banned AND banned_at IS NOT NULL) OR (NOT is_banned AND banned_at IS NULL))
);

-- Índice inverso: "¿a qué servidores pertenece este usuario?" es la primera
-- consulta que hace Phoenix al abrirse un socket.
CREATE INDEX server_members_user_idx ON server_members (user_id) WHERE NOT is_banned;

COMMENT ON TABLE server_members IS
    'Membresía. El baneo se conserva como fila (is_banned) para poder impedir el reingreso.';

-- -----------------------------------------------------------------------------
-- member_roles
-- -----------------------------------------------------------------------------
CREATE TABLE member_roles (
    server_id   uuid        NOT NULL,
    user_id     uuid        NOT NULL,
    role_id     uuid        NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by uuid        REFERENCES users(id) ON DELETE SET NULL,

    PRIMARY KEY (server_id, user_id, role_id),
    FOREIGN KEY (server_id, user_id) REFERENCES server_members(server_id, user_id) ON DELETE CASCADE
);

CREATE INDEX member_roles_role_idx ON member_roles (role_id);

-- Un rol solo puede asignarse a un miembro del MISMO servidor. Sin esto, la FK
-- compuesta permite (server A, user X, role de server B).
CREATE OR REPLACE FUNCTION member_roles_same_server()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    role_server uuid;
BEGIN
    SELECT server_id INTO role_server FROM roles WHERE id = NEW.role_id;
    IF role_server IS DISTINCT FROM NEW.server_id THEN
        RAISE EXCEPTION 'El rol % pertenece al servidor %, no al %',
            NEW.role_id, role_server, NEW.server_id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER member_roles_same_server_check
    BEFORE INSERT OR UPDATE ON member_roles
    FOR EACH ROW EXECUTE FUNCTION member_roles_same_server();

-- -----------------------------------------------------------------------------
-- channel_categories — agrupación visual en la barra lateral
-- -----------------------------------------------------------------------------
CREATE TABLE channel_categories (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    server_id  uuid        NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    name       text        NOT NULL,
    position   smallint    NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT channel_categories_name_len CHECK (length(name) BETWEEN 1 AND 32)
);

CREATE INDEX channel_categories_server_idx ON channel_categories (server_id, position);

-- -----------------------------------------------------------------------------
-- channels
-- -----------------------------------------------------------------------------
CREATE TABLE channels (
    id            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    server_id     uuid         NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    category_id   uuid         REFERENCES channel_categories(id) ON DELETE SET NULL,

    name          text         NOT NULL,
    kind          channel_kind NOT NULL,
    topic         text         NOT NULL DEFAULT '',
    position      smallint     NOT NULL DEFAULT 0,
    is_private    boolean      NOT NULL DEFAULT false,

    -- E2EE
    e2ee_enabled  boolean      NOT NULL DEFAULT true,
    current_epoch integer      NOT NULL DEFAULT 0,

    -- Solo para kind = 'voice'
    bitrate       integer,
    user_limit    smallint,

    rate_limit_seconds smallint NOT NULL DEFAULT 0,

    created_by    uuid         REFERENCES users(id) ON DELETE SET NULL,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now(),
    deleted_at    timestamptz,

    CONSTRAINT channels_name_fmt  CHECK (name OPERATOR(pg_catalog.~) '^[a-z0-9][a-z0-9._-]{0,30}[a-z0-9]$'),
    CONSTRAINT channels_topic_len CHECK (length(topic) <= 512),
    CONSTRAINT channels_epoch_nonneg CHECK (current_epoch >= 0),
    CONSTRAINT channels_slowmode  CHECK (rate_limit_seconds BETWEEN 0 AND 3600),
    -- bitrate y user_limit solo tienen sentido en voz; en texto deben ser NULL.
    CONSTRAINT channels_voice_fields CHECK (
        (kind = 'voice' AND bitrate IS NOT NULL AND user_limit IS NOT NULL)
     OR (kind = 'text'  AND bitrate IS NULL     AND user_limit IS NULL)
    ),
    -- Rango útil de Opus para voz en banda ancha completa.
    CONSTRAINT channels_bitrate_range CHECK (bitrate IS NULL OR bitrate BETWEEN 8000 AND 128000),
    CONSTRAINT channels_user_limit    CHECK (user_limit IS NULL OR user_limit BETWEEN 2 AND 8)
);

CREATE UNIQUE INDEX channels_server_name_key
    ON channels (server_id, name) WHERE deleted_at IS NULL;
CREATE INDEX channels_server_listing_idx
    ON channels (server_id, position) WHERE deleted_at IS NULL;

CREATE TRIGGER channels_set_updated_at
    BEFORE UPDATE ON channels
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON COLUMN channels.current_epoch IS
    'Época de clave E2EE vigente. Los mensajes en Scylla la referencian para '
    'que el cliente sepa con qué CEK descifrar.';
COMMENT ON COLUMN channels.bitrate IS
    'Bitrate objetivo de Opus en bps (maxaveragebitrate del SDP). 32000 basta para voz.';

-- -----------------------------------------------------------------------------
-- channel_permission_overwrites
--
-- Cada fila apunta a un rol O a un usuario, nunca a los dos. Las máscaras allow
-- y deny deben ser disjuntas: permitir y denegar el mismo bit no significa nada.
-- -----------------------------------------------------------------------------
CREATE TABLE channel_permission_overwrites (
    channel_id uuid        NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    role_id    uuid        REFERENCES roles(id) ON DELETE CASCADE,
    user_id    uuid        REFERENCES users(id) ON DELETE CASCADE,

    allow_mask bigint      NOT NULL DEFAULT 0,
    deny_mask  bigint      NOT NULL DEFAULT 0,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT cpo_exactly_one_target CHECK (num_nonnulls(role_id, user_id) = 1),
    CONSTRAINT cpo_disjoint           CHECK ((allow_mask & deny_mask) = 0),
    CONSTRAINT cpo_allow_valid        CHECK (permissions_mask_is_valid(allow_mask)),
    CONSTRAINT cpo_deny_valid         CHECK (permissions_mask_is_valid(deny_mask))
);

-- Unicidad sobre columnas nullable: dos índices parciales en vez de una PK.
CREATE UNIQUE INDEX cpo_role_key ON channel_permission_overwrites (channel_id, role_id)
    WHERE role_id IS NOT NULL;
CREATE UNIQUE INDEX cpo_user_key ON channel_permission_overwrites (channel_id, user_id)
    WHERE user_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- invites
-- -----------------------------------------------------------------------------
CREATE TABLE invites (
    code       text        PRIMARY KEY,
    server_id  uuid        NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    channel_id uuid        REFERENCES channels(id) ON DELETE SET NULL,
    created_by uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    max_uses   smallint,
    uses       smallint    NOT NULL DEFAULT 0,
    expires_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT invites_code_fmt  CHECK (code OPERATOR(pg_catalog.~) '^[A-Za-z0-9_-]{8,24}$'),
    CONSTRAINT invites_max_uses  CHECK (max_uses IS NULL OR max_uses > 0),
    CONSTRAINT invites_uses_cap  CHECK (max_uses IS NULL OR uses <= max_uses)
);

CREATE INDEX invites_server_idx ON invites (server_id) WHERE revoked_at IS NULL;

COMMIT;
