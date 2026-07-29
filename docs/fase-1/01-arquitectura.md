# FASE 1 — Arquitectura global y flujos de datos

## 1. Principios que gobiernan el diseño

1. **Un único escritor por dato.** Cada tabla tiene exactamente un servicio que
   escribe en ella. Postgres lo escribe Flask; Scylla lo escribe Phoenix. Evita
   el infierno de la doble escritura sin necesitar transacciones distribuidas.
2. **La ruta caliente no llama a la ruta fría.** Enviar un mensaje no puede
   depender de una llamada HTTP a Flask. Phoenix valida el JWT localmente y
   resuelve permisos desde su propia caché.
3. **El servidor no puede leer el contenido.** Phoenix enruta y persiste
   *ciphertext*. Todo lo que necesita para autorizar (autor, canal, menciones)
   viaja en claro como metadato; el cuerpo no.
4. **La media nunca toca el servidor.** WebRTC P2P en malla; Phoenix solo mueve
   SDP e ICE. TURN existe como relé de último recurso, no como ruta normal.
5. **Cripto híbrida, no PQC pura.** X25519+ML-KEM-768 y Ed25519+ML-DSA-65. Si
   uno de los dos esquemas cae, el otro sigue protegiendo. Ver
   [ADR-0003](../adr/0003-criptografia-hibrida-pqc.md).

---

## 2. Vista de componentes

```mermaid
graph TB
    subgraph Cliente["Navegador — React + TypeScript"]
        UI[UI / Estado<br/>Zustand]
        WS[Cliente Phoenix<br/>phoenix.js]
        RTC[WebRTC PeerConnections<br/>Opus]
        CRYPTO[Motor cripto WASM<br/>ML-KEM-768 · ML-DSA-65<br/>XChaCha20-Poly1305]
        UI --> WS
        UI --> RTC
        UI --> CRYPTO
        WS -.claves de canal.-> CRYPTO
        RTC -.SRTP-DTLS.-> CRYPTO
    end

    subgraph Realtime["Elixir · Phoenix — ruta caliente"]
        SOCK[UserSocket<br/>verificación JWT]
        CH_CHAT[ChannelChat<br/>texto]
        CH_VOICE[ChannelVoice<br/>señalización SDP/ICE]
        PRES[Phoenix.Presence<br/>CRDT distribuido]
        AUTHZ[AuthzCache<br/>ETS · TTL 60 s]
        WRITER[MessageWriter<br/>pool + backpressure]
        SOCK --> CH_CHAT & CH_VOICE
        CH_CHAT --> AUTHZ & WRITER
        CH_VOICE --> AUTHZ & PRES
        CH_CHAT --> PRES
    end

    subgraph API["Python · Flask — ruta fría"]
        AUTH[Auth<br/>Argon2id · JWT Ed25519]
        MGMT[Servidores · Canales · Roles]
        KEYDIR[Directorio de claves PQC]
        UPLOAD[Adjuntos<br/>URLs prefirmadas]
        JWKS[/.well-known/jwks.json/]
    end

    subgraph Datos["Persistencia"]
        PG[(PostgreSQL<br/>identidad · estructura<br/>claves públicas)]
        SC[(ScyllaDB<br/>mensajes · lectura<br/>auditoría)]
        S3[(Object Storage<br/>adjuntos cifrados)]
    end

    TURN[coturn<br/>STUN / TURN]

    UI -->|HTTPS REST| AUTH & MGMT & KEYDIR & UPLOAD
    WS -->|WSS| SOCK
    RTC <-->|SRTP P2P| RTC
    RTC -.relé si falla P2P.-> TURN

    AUTH & MGMT & KEYDIR & UPLOAD -->|lectura + escritura| PG
    UPLOAD --> S3
    WRITER -->|escritura| SC
    CH_CHAT -->|lectura histórico| SC
    AUTHZ -->|SOLO LECTURA| PG
    SOCK -->|JWKS cacheado| JWKS
    MGMT -.invalidación de caché.-> AUTHZ

    style Realtime fill:#2b3a42,color:#fff
    style API fill:#3d3244,color:#fff
    style Datos fill:#1f3b2c,color:#fff
```

### Por qué dos backends y no uno

Elixir y Flask no compiten: resuelven problemas con perfiles de carga opuestos.

| | Phoenix (Elixir) | Flask (Python) |
|---|---|---|
| Perfil | 10⁴ conexiones persistentes, mensajes de ~1 KB | decenas de req/s, lógica compleja |
| Latencia objetivo | p99 < 20 ms de fan-out | p99 < 200 ms |
| Estado | con estado (canales, presencia) | sin estado (escala horizontal trivial) |
| Escribe en | ScyllaDB | PostgreSQL |
| Falla si cae | se corta el tiempo real; el histórico sigue accesible | no se puede crear/administrar; el chat sigue vivo |

La última fila es el argumento decisivo: **fallan de forma independiente**. Si
Flask cae, los usuarios ya conectados siguen hablando; sus JWT son válidos hasta
15 minutos y Phoenix no necesita a Flask para enrutar.

---

## 3. Autenticación: quién emite y quién verifica

Flask es la **única autoridad de identidad**. Firma JWT con Ed25519 (`EdDSA`) y
publica la clave pública en `/.well-known/jwks.json`. Phoenix descarga ese JWKS,
lo cachea 5 minutos y verifica **en local** cada conexión de socket. Ninguna
conexión WebSocket genera una llamada HTTP a Flask.

```mermaid
sequenceDiagram
    autonumber
    participant C as React
    participant F as Flask
    participant PG as PostgreSQL
    participant P as Phoenix

    Note over C: Registro
    C->>C: Genera en WASM el bundle de claves<br/>X25519 + ML-KEM-768 + Ed25519 + ML-DSA-65
    C->>C: Deriva clave de dispositivo desde la contraseña<br/>(Argon2id) y cifra las claves privadas
    C->>F: POST /auth/register<br/>{username, email, password, device_bundle}
    F->>F: Argon2id(password) → password_hash
    F->>PG: INSERT users, user_devices, device_keys
    F-->>C: 201 {access_token, refresh_token, user, device_id}

    Note over C: Conexión al tiempo real
    C->>P: WSS /socket?token=<access_token>&device_id=...
    P->>F: GET /.well-known/jwks.json (solo si la caché expiró)
    F-->>P: {keys:[{kty:OKP, crv:Ed25519, ...}]}
    P->>P: Verifica firma, exp, iss, aud, jti
    P->>PG: SELECT membresías y permisos (rol de SOLO LECTURA)
    P->>P: Guarda en ETS con TTL 60 s
    P-->>C: phx_reply ok · socket asignado a user_id/device_id
```

**Claims del JWT** — el detalle exacto está en
[04-contratos-entre-servicios.md](04-contratos-entre-servicios.md#1-jwt).
El token lleva `sub` (user_id), `did` (device_id) y `ver` (version de permisos),
pero **no lleva la lista de permisos**: cabría en el token, pero entonces
revocar un rol tardaría hasta 15 minutos en surtir efecto. En su lugar Phoenix
consulta y cachea 60 segundos.

---

## 4. Flujo: enviar un mensaje de texto

```mermaid
sequenceDiagram
    autonumber
    participant A as Emisor (React)
    participant P as Phoenix Channel
    participant E as ETS AuthzCache
    participant W as MessageWriter
    participant S as ScyllaDB
    participant B as Otros miembros

    A->>A: Cifra: XChaCha20-Poly1305(CEK_epoch, plaintext)
    A->>A: Firma el digest con ML-DSA-65 + Ed25519
    A->>P: push "message:new"<br/>{client_nonce, epoch, ciphertext, nonce, sig, mentions[]}
    P->>E: ¿user tiene SEND_MESSAGES en channel?
    E-->>P: sí (hit de caché, ~1 µs)
    P->>P: Valida tamaño ≤ 64 KiB, epoch == current_epoch
    P->>P: message_id = timeuuid(now)

    par Fan-out inmediato
        P-->>B: broadcast "message:new" (estado: confirmado)
        P-->>A: reply {status:"ok", message_id, inserted_at}
    and Persistencia
        P->>W: cast {mensaje}
        W->>S: INSERT messages_by_channel (CL=LOCAL_QUORUM)
        W->>S: INSERT message_lookup, channel_buckets
        W->>S: INSERT message_dedupe (TTL 24 h)
        W->>S: UPDATE counters de no leídos
    end

    alt La escritura en Scylla falla
        W-->>P: {:error, reason}
        P-->>A: broadcast "message:failed" {client_nonce}
        P-->>B: broadcast "message:failed" {message_id}
        Note over A,B: El cliente marca el mensaje como no entregado<br/>y ofrece reintentar con el mismo client_nonce
    end
```

**La decisión discutible, hecha explícita:** difundimos *antes* de confirmar la
escritura en Scylla. Eso baja el p99 percibido de ~15 ms a ~3 ms, a cambio de
una ventana en la que un mensaje se ve en pantalla y luego se retracta si la
escritura falla. Para un grupo reducido y un fallo raro, es el intercambio
correcto; el mecanismo de retractación (`message:failed`) es obligatorio, no
opcional. Si en el futuro esto molesta, se invierte el orden cambiando una
línea en `MessageWriter` — el contrato del cliente ya contempla los dos estados.

`client_nonce` es un UUIDv4 generado por el cliente. Si el socket se cae entre
el `push` y el `reply`, el reintento trae el mismo nonce, `message_dedupe` lo
detecta y devuelve el `message_id` original en lugar de duplicar. Sin esto, cada
reconexión en un tren de metro genera mensajes dobles.

---

## 5. Flujo: unirse a un canal de voz (WebRTC en malla)

```mermaid
sequenceDiagram
    autonumber
    participant A as Alice
    participant P as Phoenix ChannelVoice
    participant F as Flask
    participant B as Bob (ya dentro)
    participant T as coturn

    A->>F: POST /voice/turn-credentials
    F-->>A: {username: "<exp>:<uid>", credential: HMAC(secret, username), urls:[...]}
    Note right of F: Credencial efímera, TTL 1 h.<br/>El secreto estático nunca sale del servidor.

    A->>P: join "voice:<channel_id>"
    P->>P: Comprueba CONNECT_VOICE y aforo (máx. 8)
    P-->>A: {peers: [{user_id: bob, device_id, peer_id}]}
    P-->>B: "voice:peer_joined" {peer_id: alice}

    Note over A,B: Regla de desempate: el peer con UUID menor emite la oferta.
    A->>A: getUserMedia({audio: {opus, DTX, FEC}})
    A->>A: createOffer() → SDP con preferencia Opus
    A->>P: "voice:signal" {to: bob, type: "offer", sdp}
    P->>P: Verifica que ambos están en la sala
    P-->>B: "voice:signal" {from: alice, type: "offer", sdp}
    B->>P: "voice:signal" {to: alice, type: "answer", sdp}
    P-->>A: "voice:signal" {from: bob, type: "answer", sdp}

    loop Trickle ICE
        A->>P: "voice:signal" {to: bob, type: "ice", candidate}
        P-->>B: "voice:signal" {from: alice, type: "ice", candidate}
    end

    A<<->>B: DTLS-SRTP · audio Opus P2P
    alt No hay ruta directa (NAT simétrico)
        A<<->>T: Relé TURN
        T<<->>B: Relé TURN
    end

    A->>P: "voice:state" {muted: false, speaking: true}
    P-->>B: Presence diff
```

Phoenix **no interpreta el SDP**: solo comprueba que emisor y receptor están en
la misma sala y reenvía el payload opaco. Eso mantiene el servicio de
señalización independiente de la evolución de WebRTC.

**Selección de códec.** Opus se negocia en el SDP con `useinbandfec=1`,
`usedtx=1`, `maxaveragebitrate=32000` para voz. DTX corta la transmisión en
silencio, lo que en una malla de N peers importa: el ancho de banda de subida
crece con O(N), y en una llamada real la mayoría está callada la mayor parte
del tiempo.

---

## 6. Flujo: establecer la clave de un canal (pipeline PQC)

Resumen aquí; el detalle criptográfico completo está en
[03-seguridad-pqc.md](03-seguridad-pqc.md).

```mermaid
sequenceDiagram
    autonumber
    participant N as Nuevo miembro (Carol)
    participant F as Flask
    participant PG as PostgreSQL
    participant P as Phoenix
    participant A as Admin (dispositivo)

    N->>F: POST /servers/<id>/join {invite_code}
    F->>PG: INSERT server_members + member_roles
    F->>PG: UPDATE users.permissions_version += 1
    F->>P: POST /internal/authz/invalidate {user_ids, server_id}
    P->>P: Purga entradas ETS afectadas

    Note over A: La rotación de clave la ejecuta un cliente, no el servidor.
    P-->>A: "channel:key_rotation_required" {channel_id, reason: "member_join"}
    A->>F: GET /channels/<id>/key-recipients
    F-->>A: [{device_id, ml_kem_public, x25519_public, ml_dsa_public, bundle_signature}]
    A->>A: Verifica bundle_signature de cada dispositivo
    A->>A: CEK_n+1 = random(32)
    loop Por cada dispositivo destinatario
        A->>A: (ct_kem, ss_kem) = ML-KEM-768.Encaps(ek_dest)
        A->>A: ss_x = X25519(esk_efímera, pk_dest)
        A->>A: wrap_key = HKDF-SHA256(ss_x ‖ ss_kem, salt, info)
        A->>A: wrapped = XChaCha20-Poly1305(wrap_key, CEK_n+1)
        A->>A: sig = ML-DSA-65(sk_admin, transcript) ‖ Ed25519(...)
    end
    A->>F: POST /channels/<id>/key-epochs {epoch, shares[]}
    F->>PG: INSERT channel_key_epochs + channel_key_shares
    F->>P: POST /internal/channels/<id>/epoch-bumped {epoch}
    P-->>N: "channel:new_epoch" {epoch}
    N->>F: GET /channels/<id>/key-epochs/<epoch>/share
    F-->>N: {ml_kem_ciphertext, x25519_ephemeral_public, wrapped_key, sig}
    N->>N: Verifica firma → Decaps → HKDF → descifra CEK
```

Dos propiedades importantes de este diseño:

- **El servidor almacena, no participa.** Flask guarda `wrapped_key` sin poder
  abrirla. Nunca ve una CEK ni una clave privada.
- **La rotación es sincrónica con la membresía, no periódica.** Cada
  alta/baja produce una época nueva. Un miembro expulsado conserva las claves
  de las épocas en que estuvo (no hay borrado retroactivo posible en E2EE),
  pero no puede leer nada posterior: *post-compromise security* a nivel de
  membresía.

---

## 7. Ruta de lectura: cargar el histórico de un canal

Un cliente que abre un canal pide los últimos 50 mensajes y luego pagina hacia
atrás. En Scylla eso no es un `OFFSET`; es un recorrido de particiones.

```mermaid
flowchart LR
    START([Abrir canal]) --> B1["Leer channel_buckets<br/>WHERE channel_id = ?<br/>ORDER BY bucket DESC LIMIT 3"]
    B1 --> B2{"¿Hay bucket?"}
    B2 -->|no| EMPTY([Canal vacío])
    B2 -->|sí| Q["SELECT * FROM messages_by_channel<br/>WHERE channel_id=? AND bucket=?<br/>LIMIT n"]
    Q --> C{"¿n filas<br/>obtenidas?"}
    C -->|sí| DEC["El cliente descifra por epoch<br/>y verifica firmas"]
    C -->|no, faltan k| NEXT["Siguiente bucket más antiguo"]
    NEXT --> Q
    DEC --> DONE([Render])
```

Paginar hacia atrás desde un mensaje concreto añade
`AND message_id < <timeuuid_cursor>` dentro del mismo bucket. Como el
clustering es `message_id DESC`, es un *range scan* secuencial sobre disco:
la operación más barata que ofrece Scylla.

`channel_buckets` existe precisamente porque un canal puede tener meses sin
actividad. Sin ese directorio, paginar significaría probar mes a mes hacia
atrás a ciegas, gastando una query por cada mes vacío.

---

## 8. Consistencia y modos de fallo

| Escenario | Comportamiento | Recuperación |
|---|---|---|
| Cae un nodo Phoenix | Los clientes reconectan a otro nodo (LB con sticky opcional); Presence converge por CRDT | Automática, ~2 s |
| Cae Flask entero | No hay login ni administración; el chat y la voz siguen | Los JWT vivos duran hasta 15 min |
| Cae un nodo Scylla (RF=3) | `LOCAL_QUORUM` sigue satisfaciéndose con 2 nodos | Hinted handoff + repair |
| Cae Postgres | Phoenix sirve desde caché ETS 60 s, luego rechaza *joins* nuevos | Réplica en espera |
| Partición Phoenix↔Scylla | Las escrituras fallan → `message:failed`; el fan-out sigue funcionando | Reintento del cliente por `client_nonce` |
| Reloj desincronizado entre nodos Phoenix | Los timeuuid podrían desordenarse entre nodos | NTP obligatorio; el orden se define por timeuuid, no por llegada |

**Sobre el orden de los mensajes.** El orden canónico es el `timeuuid` asignado
por el nodo Phoenix que recibe el mensaje. Con varios nodos y relojes con deriva
de milisegundos, dos mensajes casi simultáneos pueden ordenarse distinto de como
los vio un observador humano. Para un grupo reducido esto es invisible y no
justifica el coste de un secuenciador central. Queda documentado como límite
conocido, no como bug.

---

## 9. Presupuesto de latencia (objetivo p99, un solo DC)

| Tramo | Presupuesto |
|---|---|
| Cifrado en cliente (XChaCha20 + ML-DSA-65 sign) | 2 ms |
| RTT WebSocket cliente→Phoenix | 8 ms |
| Autorización (ETS hit) | < 0.1 ms |
| Fan-out PubSub a N≤8 suscriptores | 1 ms |
| RTT Phoenix→cliente receptor | 8 ms |
| Descifrado + verificación en cliente | 3 ms |
| **Total percibido emisor→receptor** | **~22 ms** |
| Escritura Scylla `LOCAL_QUORUM` (fuera de la ruta percibida) | 6 ms |

La firma ML-DSA-65 es lo más caro del cliente (~1 ms en WASM, y 3309 bytes de
firma por mensaje). Ver [ADR-0003](../adr/0003-criptografia-hibrida-pqc.md) para
por qué firmamos igualmente cada mensaje en lugar de solo autenticar con el AEAD.

---

## 10. Despliegue

```mermaid
graph TB
    subgraph Edge
        LB[Load Balancer<br/>TLS 1.3 · WSS]
    end
    subgraph App
        F1[Flask ×2<br/>gunicorn + gevent]
        P1[Phoenix nodo 1]
        P2[Phoenix nodo 2]
        P1 <-.->|libcluster · Distributed Erlang<br/>PubSub + Presence| P2
    end
    subgraph Estado
        PGM[(Postgres primario)]
        PGR[(Postgres réplica)]
        SC1[(Scylla ×3 · RF=3)]
        OBJ[(Object storage)]
    end
    TURN[coturn]
    CDN[CDN → bundle React estático]

    LB --> CDN & F1 & P1 & P2
    F1 --> PGM & OBJ
    P1 & P2 --> PGR
    P1 & P2 --> SC1
    PGM --> PGR
```

Phoenix se agrupa con `libcluster`; `Phoenix.PubSub` y `Phoenix.Presence`
replican entre nodos por Distributed Erlang, así que un usuario en el nodo 1 y
otro en el nodo 2 comparten canal sin infraestructura adicional. Esto es lo que
hace que no necesitemos Redis para el fan-out.

---

## 11. Qué NO decide esta fase

Deliberadamente aplazado, con el punto de decisión anotado:

- **SFU.** Cuando la malla deje de aguantar (>8 participantes), se introduce un
  SFU y la señalización cambia de N×N a 1×N. La capa de señalización de la
  FASE 2 está diseñada para que ese cambio no toque el contrato del cliente.
- **Búsqueda de mensajes.** Imposible en servidor con E2EE. Será un índice
  local en el cliente (IndexedDB) en una fase posterior.
- **Multi-región.** El esquema de Scylla ya usa `NetworkTopologyStrategy` y
  `LOCAL_QUORUM`, así que añadir un DC es una operación de infraestructura, no
  una migración de datos.

---

**Siguiente:** [02 — Modelo de datos](02-modelo-de-datos.md)
