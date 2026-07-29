# ADR-0003: Criptografía híbrida (clásica + post-cuántica)

- **Estado:** aceptada
- **Fecha:** 2026-07-29
- **Fase:** 1

## Contexto

El requisito pide PQC con CRYSTALS-Kyber y CRYSTALS-Dilithium, hoy
estandarizados por NIST como **ML-KEM** (FIPS 203) y **ML-DSA** (FIPS 204).

La amenaza concreta que esto responde es *harvest now, decrypt later*: un
adversario archiva tráfico cifrado hoy y lo descifra cuando existan ordenadores
cuánticos criptográficamente relevantes. Un mensaje que siga siendo sensible
dentro de diez años necesita protección post-cuántica **hoy**, porque el
archivado ya está ocurriendo.

## Decisión

**Híbrido en las dos primitivas asimétricas**, nunca PQC en solitario:

| Función | Clásico | Post-cuántico | Combinación |
|---|---|---|---|
| Acuerdo de clave | X25519 | ML-KEM-768 | `HKDF-SHA256(ss_x ‖ ss_kem, salt, info)` |
| Firma | Ed25519 | ML-DSA-65 | Concatenadas; **las dos** deben verificar |

Simétrico: XChaCha20-Poly1305 (ya resistente a ataques cuánticos con clave de
256 bits). Derivación: HKDF-SHA256. Contraseñas: Argon2id.

Nivel de seguridad 3 (≈ AES-192) en ambas primitivas PQC.

Detalles de construcción en
[03-seguridad-pqc.md](../fase-1/03-seguridad-pqc.md).

## Alternativas consideradas

**ML-KEM y ML-DSA en solitario.** Payloads más pequeños y código más simple.
Descartada: son estándares recientes con mucho menos escrutinio acumulado que
X25519 y Ed25519. Un fallo estructural en criptografía basada en retículos no
es imposible, y el modo híbrido convierte ese escenario en un susto en lugar de
una brecha — para romper el sistema hay que romper las dos familias.

**Solo criptografía clásica.** Es lo que hacen hoy casi todos los mensajeros.
Descartada porque es exactamente el requisito del proyecto y porque no protege
contra el archivado.

**Nivel 5 (ML-KEM-1024 / ML-DSA-87).** Duplica tamaños de clave y firma para
proteger contra un adversario que, de existir, tendría objetivos mejores que un
chat de grupo. El nivel 3 es lo que el propio NIST recomienda como opción
general.

**AES-256-GCM en vez de XChaCha20-Poly1305.** Aceleración por hardware en CPU
modernas. Descartada por el nonce: 12 bytes obligan a llevar un contador por
dispositivo y época, que es estado persistente que se puede corromper, y
reutilizar un nonce en GCM es catastrófico. Los 24 bytes de XChaCha20 permiten
generarlo aleatorio sin riesgo de colisión. `AES-256-GCM` queda declarado en el
enum `aead_algorithm` por si alguna vez interesa.

## Consecuencias

**A favor**

- Seguridad aditiva: hay que romper las dos familias criptográficas.
- Cumple el requisito PQC sin apostar todo a un estándar joven.
- Migrar a PQC puro más adelante es quitar código, no rediseñar: el `key_version`
  de `device_keys` y el enum `kem_algorithm` ya permiten convivencia de esquemas.

**En contra**

- **Tamaño.** Es el coste dominante y conviene verlo en crudo:

  | Elemento | Clásico | Híbrido | Factor |
  |---|---|---|---|
  | Bundle de claves públicas | 64 B | 3200 B | 50× |
  | Firma por mensaje | 64 B | 3373 B | 53× |
  | Share de clave por destinatario | ~80 B | ~1200 B | 15× |

  Un mensaje de veinte caracteres pasa a ocupar unos 3,5 KiB. A la escala de
  este producto (mil mensajes al día ≈ 3,5 MB/día) es asumible, y por eso se
  firma cada mensaje. **En un producto con millones de mensajes diarios esta
  decisión no se sostiene** y habría que ir a firmas por lotes o a un esquema
  tipo ratchet.

- Coste de CPU en el cliente: ~1 ms por firma ML-DSA-65 en WASM. Irrelevante
  frente al RTT de red.
- Rotar la clave de un canal de 8 miembros con 2 dispositivos cada uno son 16
  encapsulaciones y ~19 KB en la tabla de shares. Crece con O(dispositivos),
  lo que acota el tamaño práctico de un canal — coherente con el tope de 8 de
  la malla WebRTC ([ADR-0004](0004-webrtc-malla-p2p.md)).
- Menos madurez en las bibliotecas de cliente que en las clásicas.

## Cuándo revisar esta decisión

Cuando ML-KEM y ML-DSA acumulen el escrutinio que hoy tienen X25519 y Ed25519,
el componente clásico podrá retirarse y los tamaños caerán a la mitad. El
`key_version` de `device_keys` existe precisamente para permitir esa transición
sin romper a los clientes antiguos.
