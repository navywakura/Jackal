# FASE 1 — Contratos entre servicios

Este documento congela las interfaces para que las FASES 2, 3 y 4 puedan
desarrollarse en paralelo sin bloquearse. Todo lo de aquí es contrato: cambiarlo
después obliga a tocar más de un servicio.

Convenciones generales:

- Todos los identificadores son UUID en formato canónico con guiones.
- Todo el material binario viaja en **base64url sin relleno**.
- Las marcas de tiempo son RFC 3339 en UTC (`2026-07-29T14:03:11.482Z`).
- Los errores REST siguen `{"error": {"code": "...", "message": "...", "details": {...}}}`.
- `code` es un identificador estable en `snake_case`; `message` es texto para
  humanos y **puede cambiar sin previo aviso**. Los clientes deben ramificar por
  `code`, nunca por `message`.

---

## 1. JWT

Emitido por Flask, verificado por Phoenix. Algoritmo `EdDSA` (Ed25519).

```jsonc
{
  "iss": "https://api.jackal.local",
  "aud": "jackal-clients",
  "sub": "22222222-2222-4222-8222-222222222222",  // user_id
  "did": "90000000-4000-4000-8000-000000000001",  // device_id
  "jti": "8f1c...",                                // id único, para revocación
  "ver": 7,                                        // users.permissions_version
  "iat": 1785000000,
  "exp": 1785000900,                               // iat + 900 s
  "typ": "access"
}
```

**Lo que no lleva: la lista de permisos.** Cabría, y ahorraría una consulta —
pero entonces quitarle un rol a alguien no surtiría efecto hasta que su token
expirase, hasta 15 minutos después. Phoenix consulta permisos y los cachea 60 s;
`ver` le permite detectar que su caché quedó obsoleta sin esperar al TTL.

Rotación de claves de firma: Flask publica en `/.well-known/jwks.json` todas las
claves con `expires_at > now()`, incluidas las ya retiradas para firmar. La
ventana de solape debe ser mayor que `ACCESS_TOKEN_TTL` para no invalidar tokens
en vuelo. Phoenix cachea el JWKS 5 minutos y lo refresca si aparece un `kid`
desconocido (con límite de frecuencia, para que un `kid` inventado no sirva como
vector de denegación de servicio).

---

## 2. API REST (Flask)

Base: `${API_PUBLIC_URL}`. Autenticación: `Authorization: Bearer <access_token>`.

### Autenticación

| Método | Ruta | Descripción |
|---|---|---|
| `POST` | `/auth/register` | Alta con bundle de claves del dispositivo |
| `POST` | `/auth/login` | Devuelve tokens + `vault_salt` |
| `POST` | `/auth/refresh` | Rota el refresh token |
| `POST` | `/auth/logout` | Revoca el refresh token actual |
| `GET`  | `/auth/me` | Perfil propio + servidores |
| `GET`  | `/.well-known/jwks.json` | Claves públicas de firma (sin auth) |

```jsonc
// POST /auth/register
{
  "username": "ana",
  "email": "ana@jackal.local",
  "password": "···",
  "vault_salt": "base64url(16 B)",     // sal de Argon2id de la bóveda local
  "device": { "name": "Firefox / Linux", "platform": "web" },
  "key_bundle": {
    "key_version": 1,
    "x25519_public":  "base64url(32 B)",
    "ml_kem_public":  "base64url(1184 B)",
    "ed25519_public": "base64url(32 B)",
    "ml_dsa_public":  "base64url(1952 B)",
    "bundle_signature": "base64url(3373 B)",
    "fingerprint": "base64url(32 B)"
  }
}
// 201
{
  "access_token": "eyJ···", "refresh_token": "···", "expires_in": 900,
  "user": { "id": "···", "username": "ana", "display_name": "Ana" },
  "device_id": "···"
}
```

`vault_salt` se guarda en el servidor y se devuelve en el login porque el
cliente la necesita para rederivar su DMK en un navegador nuevo. Es una sal
pública: sin la contraseña no sirve de nada.

### Perfiles, servidores y canales

| Método | Ruta | Permiso |
|---|---|---|
| `PATCH` | `/users/me` | — |
| `GET` | `/users/{id}` | miembro de un servidor común |
| `POST` | `/servers` | — |
| `GET` | `/servers/{id}` | miembro |
| `PATCH` | `/servers/{id}` | `MANAGE_SERVER` |
| `GET` | `/servers/{id}/members` | miembro |
| `DELETE` | `/servers/{id}/members/{uid}` | `KICK_MEMBERS` |
| `POST` | `/servers/{id}/roles` | `MANAGE_ROLES` |
| `PATCH` | `/servers/{id}/roles/{rid}` | `MANAGE_ROLES` + jerarquía |
| `PUT` | `/servers/{id}/members/{uid}/roles/{rid}` | `MANAGE_ROLES` + jerarquía |
| `POST` | `/servers/{id}/channels` | `MANAGE_CHANNELS` |
| `PATCH` | `/channels/{id}` | `MANAGE_CHANNELS` |
| `PUT` | `/channels/{id}/overwrites` | `MANAGE_ROLES` |
| `POST` | `/servers/{id}/invites` | `CREATE_INVITE` |
| `POST` | `/invites/{code}/accept` | — |

"Jerarquía" significa: solo se puede asignar o editar un rol cuya `position` sea
estrictamente menor que la del rol más alto del actor. Sin esa regla, cualquiera
con `MANAGE_ROLES` podría autoconcederse `ADMINISTRATOR`.

### Directorio de claves y épocas

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/users/{id}/devices` | Bundles públicos activos |
| `POST` | `/devices/{id}/keys` | Publicar un bundle nuevo (rota `key_version`) |
| `DELETE` | `/devices/{id}` | Revocar dispositivo → dispara rotación |
| `GET` | `/channels/{id}/key-recipients` | A quién hay que envolver la CEK |
| `POST` | `/channels/{id}/key-epochs` | Subir una época nueva con todos sus shares |
| `GET` | `/channels/{id}/key-epochs/{epoch}/share` | Mi share de esa época |
| `GET` | `/devices/{id}/pending-shares` | Shares sin recoger |

```jsonc
// POST /channels/{id}/key-epochs   — atómico: o entran todos los shares o ninguno
{
  "epoch": 4,
  "reason": "member_join",
  "aead": "XCHACHA20-POLY1305",
  "hkdf_salt": "base64url(32 B)",
  "cek_commitment": "base64url(32 B)",
  "shares": [
    {
      "recipient_device_id": "···",
      "recipient_key_id": "···",
      "ml_kem_ciphertext": "base64url(1088 B)",
      "x25519_ephemeral_public": "base64url(32 B)",
      "wrapped_cek": "base64url(48 B)",
      "wrap_nonce": "base64url(24 B)",
      "sender_signature": "base64url(3373 B)"
    }
  ]
}
```

Flask **rechaza** la época si falta el share de algún dispositivo activo con
acceso al canal. Un reparto incompleto deja a alguien sin poder leer, y es mucho
más barato detectarlo aquí que depurarlo después.

Códigos de error propios de este bloque:

| `code` | Significado |
|---|---|
| `epoch_conflict` | Ya existe esa época (otro cliente ganó la carrera) |
| `incomplete_share_set` | Faltan dispositivos; `details.missing_device_ids` |
| `stale_recipient_key` | Un `recipient_key_id` fue revocado durante el reparto |
| `invalid_signature` | `sender_signature` o `bundle_signature` no verifica |

### Adjuntos y TURN

| Método | Ruta | Descripción |
|---|---|---|
| `POST` | `/channels/{id}/attachments` | Reserva y devuelve URL prefirmada |
| `POST` | `/attachments/{id}/confirm` | `pending` → `ready` |
| `POST` | `/voice/turn-credentials` | Credencial TURN efímera (TTL 1 h) |

---

## 3. Phoenix Channels

Socket: `${VITE_WS_URL}?token=<access_token>&device_id=<uuid>&vsn=2.0.0`

Tópicos:

| Tópico | Contenido |
|---|---|
| `user:<user_id>` | Notificaciones personales, invalidaciones, épocas nuevas |
| `chat:<channel_id>` | Mensajes de texto |
| `voice:<channel_id>` | Señalización WebRTC y presencia de voz |
| `server:<server_id>` | Cambios de estructura, presencia del servidor |

### `chat:<channel_id>`

**Cliente → servidor**

| Evento | Payload | Respuesta |
|---|---|---|
| `message:new` | `{client_nonce, key_epoch, ciphertext, nonce, sender_signature, sender_key_id, reply_to?, mentions[], mention_everyone, attachment_ids[]}` | `{status:"ok", message_id, inserted_at}` |
| `message:edit` | `{message_id, key_epoch, ciphertext, nonce, sender_signature}` | `{status:"ok", edited_at}` |
| `message:delete` | `{message_id}` | `{status:"ok"}` |
| `message:history` | `{before?: timeuuid, limit: 50}` | `{messages: [...], has_more: bool}` |
| `reaction:add` / `reaction:remove` | `{message_id, emoji}` | `{status:"ok"}` |
| `read:ack` | `{message_id}` | `{status:"ok"}` |
| `typing:start` | `{}` | — (sin respuesta) |

**Servidor → cliente**

| Evento | Cuándo |
|---|---|
| `message:new` | Mensaje difundido (incluido el propio, para conciliar) |
| `message:failed` | La escritura en Scylla falló; **retractar de la UI** |
| `message:edited` / `message:deleted` | Edición o borrado |
| `reaction:added` / `reaction:removed` | Reacción |
| `typing` | `{user_id}`, expira a los 5 s en el cliente |
| `channel:new_epoch` | `{epoch}` — deja de cifrar con la anterior |
| `presence_state` / `presence_diff` | Phoenix.Presence |

**`message:failed` no es opcional.** Phoenix difunde antes de confirmar la
escritura, así que un mensaje puede aparecer en pantalla y luego resultar no
persistido. Un cliente que ignore este evento mostrará mensajes fantasma que
desaparecen al recargar. Ver
[01-arquitectura.md §4](01-arquitectura.md#4-flujo-enviar-un-mensaje-de-texto).

Límites aplicados en el servidor:

| Límite | Valor | Al superarse |
|---|---|---|
| Tamaño de `ciphertext` | 64 KiB | `{status:"error", reason:"payload_too_large"}` |
| Mensajes por minuto y usuario | 60 | `rate_limited` |
| `channels.rate_limit_seconds` | por canal | `slowmode_active` |
| `mentions` por mensaje | 50 | `too_many_mentions` |
| `key_epoch` ≠ época vigente | — | `stale_epoch` con la época correcta |

`stale_epoch` devuelve la época vigente para que el cliente recifre y reintente
con el **mismo** `client_nonce`. Sin esa devolución, el cliente tendría que
consultar a Flask en mitad de un envío.

### `voice:<channel_id>`

| Evento | Dirección | Payload |
|---|---|---|
| `voice:join` | C→S | `{muted, video}` → responde `{peers: [...], ice_servers: [...]}` |
| `voice:leave` | C→S | `{}` |
| `voice:signal` | C→S | `{to: peer_id, type: "offer"\|"answer"\|"ice", payload}` |
| `voice:signal` | S→C | `{from: peer_id, type, payload}` |
| `voice:peer_joined` / `voice:peer_left` | S→C | `{peer_id, user_id, device_id}` |
| `voice:state` | C→S | `{muted, video, speaking, screen_share}` |

Phoenix **no interpreta el SDP**: comprueba que emisor y destinatario están en
la misma sala y reenvía `payload` opaco. Eso mantiene la señalización
independiente de la evolución de WebRTC, y es lo que permitirá introducir un
SFU más adelante sin cambiar el contrato del cliente.

**Regla de desempate de la oferta:** el peer cuyo `peer_id` es menor en orden
lexicográfico emite la oferta. Sin una regla determinista, los dos ofertan a la
vez y la negociación entra en colisión (*glare*).

Errores: `voice_channel_full` (aforo `user_limit`), `already_connected`
(el mismo dispositivo ya está dentro), `peer_not_in_room`.

### `user:<user_id>`

| Evento | Payload |
|---|---|
| `authz:invalidated` | `{server_ids[]}` — refrescar la barra lateral |
| `channel:key_rotation_required` | `{channel_id, reason}` — solo al rotador designado |
| `channel:new_epoch` | `{channel_id, epoch}` — hay un share que recoger |
| `channel:removed` | `{channel_id}` — se perdió el acceso |

---

## 4. API interna Flask → Phoenix

No expuesta al exterior. Autenticación por secreto compartido en la cabecera
`X-Internal-Token` (`INTERNAL_API_TOKEN`).

| Método | Ruta | Efecto |
|---|---|---|
| `POST` | `/internal/authz/invalidate` | `{user_ids[], server_id}` → purga ETS, expulsa de canales perdidos |
| `POST` | `/internal/channels/{id}/epoch-bumped` | `{epoch}` → difunde `channel:new_epoch` |
| `POST` | `/internal/channels/{id}/deleted` | Cierra el tópico y desconecta a los presentes |
| `POST` | `/internal/users/{id}/disconnect` | `{reason}` → cierra los sockets (veto, revocación) |

Estas llamadas son **best-effort**: si fallan, el TTL de 60 s de la caché ETS
acaba corrigiendo el estado. Phoenix responde `202 Accepted` y procesa de forma
asíncrona; Flask no espera al resultado, porque un Phoenix caído no debe
bloquear una operación administrativa.

Sentido contrario (Phoenix → Flask): **ninguno**. Phoenix nunca llama a Flask
en la ruta de un mensaje. La única dependencia es la descarga del JWKS, que está
cacheada y tolera que Flask esté caído.

---

## 5. Matriz de compatibilidad entre fases

Qué necesita cada fase que esté congelado antes de empezar:

| Fase | Depende de |
|---|---|
| FASE 2 (Phoenix) | §1 JWT, §3 Channels, §4 interna, esquema Scylla, vista `member_server_permissions` |
| FASE 3 (Flask) | §1 JWT, §2 REST, §4 interna, esquema Postgres completo |
| FASE 4 (React) | §2 REST, §3 Channels, §6 de 03-seguridad-pqc (formato de cifrado) |

Las FASES 2 y 3 pueden desarrollarse en paralelo: su único punto de contacto es
el JWT (§1) y la API interna (§4), ambos definidos aquí.
