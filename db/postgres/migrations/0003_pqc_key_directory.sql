-- =============================================================================
-- Jackal — 0003: directorio de claves post-cuánticas y épocas de clave de canal
--
-- Este esquema almacena EXCLUSIVAMENTE material público o material cifrado que
-- el servidor no puede abrir. Ninguna columna contiene una clave privada ni una
-- clave de contenido (CEK) en claro.
--
-- Tamaños según FIPS 203 (ML-KEM) y FIPS 204 (ML-DSA):
--   ML-KEM-768   clave de encapsulación (pública)  1184 B
--                texto cifrado                     1088 B
--                secreto compartido                  32 B
--   ML-DSA-65    clave de verificación (pública)   1952 B
--                firma                             3309 B
--   X25519       clave pública                       32 B
--   Ed25519      clave pública / firma           32 / 64 B
-- =============================================================================

BEGIN;

CREATE TYPE kem_algorithm AS ENUM ('ML-KEM-768');
CREATE TYPE sig_algorithm AS ENUM ('ML-DSA-65');
CREATE TYPE aead_algorithm AS ENUM ('XCHACHA20-POLY1305', 'AES-256-GCM');

CREATE TYPE key_epoch_reason AS ENUM (
    'init',            -- creación del canal
    'member_join',     -- alta de miembro
    'member_leave',    -- baja, expulsión o veto
    'device_added',    -- un miembro registra un dispositivo nuevo
    'device_revoked',  -- revocación de dispositivo
    'scheduled',       -- rotación periódica
    'compromise'       -- rotación de emergencia
);

-- -----------------------------------------------------------------------------
-- device_keys
--
-- Un bundle por dispositivo y versión. Es HÍBRIDO por diseño: cada dispositivo
-- publica a la vez una clave clásica y una post-cuántica para cada primitiva.
-- Ver ADR-0003 para la justificación.
--
-- bundle_signature autofirma el resto de campos con la clave de firma del
-- propio dispositivo, de modo que el servidor no puede sustituir una clave
-- pública sin que los clientes lo detecten al verificar.
-- -----------------------------------------------------------------------------
CREATE TABLE device_keys (
    id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id        uuid          NOT NULL REFERENCES user_devices(id) ON DELETE CASCADE,
    user_id          uuid          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_version      integer       NOT NULL DEFAULT 1,

    kem_alg          kem_algorithm NOT NULL DEFAULT 'ML-KEM-768',
    sig_alg          sig_algorithm NOT NULL DEFAULT 'ML-DSA-65',

    -- Acuerdo de clave (híbrido)
    x25519_public    bytea         NOT NULL,
    ml_kem_public    bytea         NOT NULL,

    -- Firma (híbrida)
    ed25519_public   bytea         NOT NULL,
    ml_dsa_public    bytea         NOT NULL,

    -- Autofirma sobre el bundle canonicalizado: ML-DSA-65 ‖ Ed25519
    bundle_signature bytea         NOT NULL,

    -- Huella SHA-256 del bundle. Es lo que se muestra en la UI para
    -- verificación fuera de banda ("compara estos 8 grupos de 4 caracteres").
    fingerprint      bytea         NOT NULL,

    created_at       timestamptz   NOT NULL DEFAULT now(),
    revoked_at       timestamptz,
    revoked_reason   text,

    CONSTRAINT device_keys_x25519_len   CHECK (octet_length(x25519_public)    = 32),
    CONSTRAINT device_keys_mlkem_len    CHECK (octet_length(ml_kem_public)    = 1184),
    CONSTRAINT device_keys_ed25519_len  CHECK (octet_length(ed25519_public)   = 32),
    CONSTRAINT device_keys_mldsa_len    CHECK (octet_length(ml_dsa_public)    = 1952),
    -- 3309 (ML-DSA-65) + 64 (Ed25519)
    CONSTRAINT device_keys_bundlesig_len CHECK (octet_length(bundle_signature) = 3373),
    CONSTRAINT device_keys_fp_len       CHECK (octet_length(fingerprint)      = 32),
    CONSTRAINT device_keys_version_pos  CHECK (key_version > 0)
);

CREATE UNIQUE INDEX device_keys_device_version_key ON device_keys (device_id, key_version);
CREATE UNIQUE INDEX device_keys_fingerprint_key    ON device_keys (fingerprint);
-- Un solo bundle activo por dispositivo: es el que sirve el directorio.
CREATE UNIQUE INDEX device_keys_one_active_per_device
    ON device_keys (device_id) WHERE revoked_at IS NULL;
CREATE INDEX device_keys_user_active_idx
    ON device_keys (user_id) WHERE revoked_at IS NULL;

COMMENT ON TABLE device_keys IS
    'Directorio de claves públicas. Solo material público; el servidor no puede '
    'derivar ningún secreto a partir de esta tabla.';
COMMENT ON COLUMN device_keys.bundle_signature IS
    'ML-DSA-65(3309 B) ‖ Ed25519(64 B) sobre la serialización canónica del bundle. '
    'El cliente destinatario DEBE verificarla antes de encapsular contra estas claves.';

-- -----------------------------------------------------------------------------
-- channel_key_epochs
--
-- Una época = una clave de contenido (CEK) de 32 B viva durante un intervalo.
-- La CEK se genera en el cliente que rota y jamás llega al servidor; aquí solo
-- se registran los metadatos de la época.
-- -----------------------------------------------------------------------------
CREATE TABLE channel_key_epochs (
    channel_id        uuid             NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    epoch             integer          NOT NULL,

    aead              aead_algorithm   NOT NULL DEFAULT 'XCHACHA20-POLY1305',
    reason            key_epoch_reason NOT NULL,

    -- Sal pública del HKDF que envuelve la CEK para cada destinatario.
    hkdf_salt         bytea            NOT NULL,
    -- SHA-256 de la CEK. Permite al receptor comprobar que descifró la clave
    -- correcta sin revelar nada sobre ella.
    cek_commitment    bytea            NOT NULL,

    created_by_device uuid             REFERENCES user_devices(id) ON DELETE SET NULL,
    created_at        timestamptz      NOT NULL DEFAULT now(),
    superseded_at     timestamptz,

    PRIMARY KEY (channel_id, epoch),
    CONSTRAINT cke_epoch_nonneg  CHECK (epoch >= 0),
    CONSTRAINT cke_salt_len      CHECK (octet_length(hkdf_salt) = 32),
    CONSTRAINT cke_commit_len    CHECK (octet_length(cek_commitment) = 32)
);

CREATE INDEX channel_key_epochs_current_idx
    ON channel_key_epochs (channel_id, epoch DESC);

COMMENT ON COLUMN channel_key_epochs.cek_commitment IS
    'SHA-256(CEK). Detecta que dos destinatarios recibieron CEK distintas '
    '(servidor malicioso intentando particionar el canal).';

-- -----------------------------------------------------------------------------
-- channel_key_shares
--
-- La CEK de una época, envuelta para UN dispositivo destinatario concreto.
-- Hay tantas filas por época como dispositivos con acceso al canal.
--
-- El servidor guarda y sirve estas filas sin poder abrirlas: para hacerlo
-- necesitaría la clave privada ML-KEM y la X25519 del destinatario.
-- -----------------------------------------------------------------------------
CREATE TABLE channel_key_shares (
    channel_id              uuid        NOT NULL,
    epoch                   integer     NOT NULL,
    recipient_device_id     uuid        NOT NULL REFERENCES user_devices(id) ON DELETE CASCADE,
    recipient_key_id        uuid        NOT NULL REFERENCES device_keys(id)  ON DELETE CASCADE,

    sender_device_id        uuid        REFERENCES user_devices(id) ON DELETE SET NULL,
    sender_key_id           uuid        REFERENCES device_keys(id)  ON DELETE SET NULL,

    -- Acuerdo de clave híbrido
    ml_kem_ciphertext       bytea       NOT NULL,
    x25519_ephemeral_public bytea       NOT NULL,

    -- CEK envuelta con la clave derivada del HKDF sobre ambos secretos
    wrapped_cek             bytea       NOT NULL,
    wrap_nonce              bytea       NOT NULL,

    -- Firma híbrida del emisor sobre el transcript del share
    sender_signature        bytea       NOT NULL,

    created_at              timestamptz NOT NULL DEFAULT now(),
    delivered_at            timestamptz,

    PRIMARY KEY (channel_id, epoch, recipient_device_id),
    FOREIGN KEY (channel_id, epoch)
        REFERENCES channel_key_epochs(channel_id, epoch) ON DELETE CASCADE,

    CONSTRAINT cks_kemct_len  CHECK (octet_length(ml_kem_ciphertext)       = 1088),
    CONSTRAINT cks_xeph_len   CHECK (octet_length(x25519_ephemeral_public) = 32),
    -- CEK de 32 B + etiqueta Poly1305 de 16 B
    CONSTRAINT cks_wrap_len   CHECK (octet_length(wrapped_cek)             = 48),
    CONSTRAINT cks_nonce_len  CHECK (octet_length(wrap_nonce)              = 24),
    CONSTRAINT cks_sig_len    CHECK (octet_length(sender_signature)        = 3373)
);

-- Consulta principal del cliente: "dame todas las épocas que aún no he recogido".
CREATE INDEX channel_key_shares_pending_idx
    ON channel_key_shares (recipient_device_id, created_at)
    WHERE delivered_at IS NULL;

COMMENT ON TABLE channel_key_shares IS
    'CEK envuelta por destinatario. Opaca para el servidor: abrirla exige la '
    'clave privada ML-KEM-768 y la X25519 del dispositivo receptor.';

-- -----------------------------------------------------------------------------
-- Coherencia: el share debe apuntar a la clave activa del dispositivo correcto.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION channel_key_shares_check_recipient()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    owner_device uuid;
    revoked      timestamptz;
BEGIN
    SELECT device_id, revoked_at INTO owner_device, revoked
      FROM device_keys WHERE id = NEW.recipient_key_id;

    IF owner_device IS DISTINCT FROM NEW.recipient_device_id THEN
        RAISE EXCEPTION 'recipient_key_id % no pertenece al dispositivo %',
            NEW.recipient_key_id, NEW.recipient_device_id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF revoked IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede envolver una CEK contra la clave revocada %',
            NEW.recipient_key_id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER channel_key_shares_recipient_check
    BEFORE INSERT OR UPDATE ON channel_key_shares
    FOR EACH ROW EXECUTE FUNCTION channel_key_shares_check_recipient();

COMMIT;
