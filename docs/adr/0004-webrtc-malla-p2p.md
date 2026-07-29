# ADR-0004: WebRTC en malla P2P, sin SFU

- **Estado:** aceptada
- **Fecha:** 2026-07-29
- **Fase:** 1

## Contexto

El MVP necesita voz y vídeo para un grupo reducido. Hay tres topologías
posibles y la elección determina tanto el coste de servidor como el techo de
participantes.

## Decisión

**Malla P2P** (cada participante conecta directamente con todos los demás), con
un **tope duro de 8 participantes por canal de voz**, aplicado en la base de
datos (`servers.max_voice_participants`, `channels.user_limit`, restricción
`CHECK` entre 2 y 8).

Phoenix hace **solo señalización**: reenvía SDP e ICE sin interpretarlos. La
media nunca pasa por el servidor. coturn actúa como relé de último recurso
cuando el NAT impide la conexión directa.

Códec de audio: Opus con `useinbandfec=1`, `usedtx=1`, `maxaveragebitrate=32000`.

## Por qué 8 y no otro número

La malla escala mal, y conviene ver el porqué en números. Con N participantes,
cada uno mantiene N−1 conexiones y sube su audio N−1 veces. Con Opus a 32 kbps:

| N | Conexiones por peer | Subida por peer | Total en el canal |
|---|---|---|---|
| 3 | 2 | 64 kbps | 192 kbps |
| 5 | 4 | 128 kbps | 640 kbps |
| **8** | **7** | **224 kbps** | **1,8 Mbps** |
| 12 | 11 | 352 kbps | 4,2 Mbps |
| 20 | 19 | 608 kbps | 12 Mbps |

224 kbps de subida es asumible en casi cualquier conexión doméstica; 608 kbps
sostenidos ya no lo son en muchas conexiones móviles, y el consumo de CPU por
mantener 19 `PeerConnection` con cifrado activo degrada notablemente en equipos
modestos. Ocho es donde la curva todavía no duele.

DTX ayuda de forma sustancial: corta la transmisión durante los silencios, y en
una conversación real la mayoría está callada la mayor parte del tiempo. Los
números de la tabla son el peor caso con todos hablando a la vez.

## Alternativas consideradas

**SFU (Selective Forwarding Unit).** Cada peer sube una vez y el servidor
reparte. Escala a decenas de participantes y es lo que usan Discord, Meet y
Zoom. Descartada para el MVP porque exige desplegar y operar un servidor de
media (LiveKit, mediasoup, Janus), es la pieza más cara y delicada de la
infraestructura, y para 8 personas no aporta nada. Es la siguiente decisión
arquitectónica cuando el tope de 8 estorbe.

**MCU (Multipoint Control Unit).** Mezcla los flujos en el servidor y envía uno
solo. Mínimo ancho de banda en el cliente, máximo coste de CPU en el servidor, y
rompe el cifrado extremo a extremo de la media por definición: el servidor tiene
que descifrar para mezclar. Incompatible con las premisas de este proyecto.

**Malla sin tope.** Dejar que el usuario descubra el límite por sí mismo cuando
la llamada se degrada. Descartada: un límite explícito y un mensaje de error
claro (`voice_channel_full`) es infinitamente mejor experiencia que una llamada
que se cae sin explicación.

## Consecuencias

**A favor**

- Coste de servidor prácticamente nulo: Phoenix mueve unos pocos KB de SDP e ICE
  por participante y nada más.
- Latencia mínima: la ruta es directa entre pares, sin salto por servidor.
- La media va cifrada extremo a extremo por DTLS-SRTP sin trabajo adicional; el
  servidor no puede escuchar aunque quiera.
- Sin punto único de fallo para la media: una llamada en curso sobrevive a un
  reinicio de Phoenix (solo se pierde la señalización de nuevas conexiones).

**En contra**

- **Techo de 8 participantes.** Es el límite del MVP y está escrito en el
  esquema, no solo en la documentación.
- Consumo de subida O(N) en el cliente.
- Dependencia de TURN cuando el NAT es simétrico. El relé sí cuesta ancho de
  banda de servidor; `voice_session_events.candidate_type` registra cuándo se
  usa, precisamente para saber cuánto está pasando.
- Depurar es más difícil: los fallos ocurren entre navegadores y el servidor no
  los ve. Por eso existe `voice_session_events` con las transiciones de ICE — sin
  esa telemetría, "a veces no se oye a Beto" es imposible de investigar.

## Cuándo revisar esta decisión

Cuando se pidan llamadas de más de 8, o cuando la telemetría muestre que el
relé TURN se usa en una fracción alta de las sesiones (en ese caso el tráfico
ya está pasando por el servidor y un SFU daría mejor calidad por el mismo
coste). El contrato de señalización de la FASE 2 (`voice:signal` con payload
opaco) está diseñado para que introducir un SFU no obligue a cambiar el
contrato del cliente.
