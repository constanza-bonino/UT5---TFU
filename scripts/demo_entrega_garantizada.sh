#!/usr/bin/env bash
#
# UT5 - Entrega garantizada y consumidor idempotente.
# Falacia: "la red es confiable".
#
#   1. el procesador de admision se cae (SIGKILL) en plena rafaga: los eventos
#      sin confirmar vuelven a la cola y no se pierde ningun paquete
#   2. el mismo evento llega dos veces: el cupo se reserva una sola vez
#
# Por que funciona:
#   - colas durables y mensajes persistentes: sobreviven a la caida
#   - el procesador confirma (ack) recien despues del commit: si cae antes,
#     RabbitMQ vuelve a entregar el evento
#   - esa reentrega puede duplicar: admision guarda la decision de cada
#     solicitud_id y, si ya la tomo, no vuelve a reservar cupo
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

N=200
PESO=0.25
ESPERADO_KG="50.0"   # 200 x 0.25 kg: entra entero en la cinta de 100 kg
PAQUETE="{\"tipo_paquete\":\"normal\",\"peso_kg\":$PESO,\"alto_cm\":20,\"ancho_cm\":20,\"largo_cm\":20}"

# cola_campo <cola> <campo>
cola_campo() { campo "$(cola_info "$1")" "$2"; }

procesador_con_pausa() {
    ( export COLA_PAUSA_PROCESAMIENTO_S="$1"; dc up -d procesador_cola > /dev/null 2>&1 )
    for _ in $(seq 1 30); do
        [ "$(cola_campo admision.validados consumers)" -gt 0 ] 2>/dev/null && return 0
        sleep 1
    done
}

restaurar() { procesador_con_pausa 0; }
trap restaurar EXIT

titulo "UT5 - ENTREGA GARANTIZADA E IDEMPOTENCIA"
requiere_sistema
reiniciar_cinta

# --- 1 ------------------------------------------------------------------------
seccion "1. El procesador se cae en plena rafaga"
paso "Se frena el procesador a 0.2 s por evento, para que la rafaga dure unos segundos"
procesador_con_pausa 0.2
DESDE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

paso "Llegan $N paquetes de $PESO kg"
generador rafaga --n "$N" --url http://balanceador:82/paquetes --cuerpo "$PAQUETE"
sleep 1.5

paso "docker compose kill procesador_cola   (SIGKILL: sin cierre ordenado, como un corte de luz)"
dc kill procesador_cola > /dev/null 2>&1
sleep 6   # la API de RabbitMQ actualiza sus contadores cada 5 s
mostrar_cinta
nota "cola admision.validados: $(cola_campo admision.validados messages) eventos esperando, $(cola_campo admision.validados consumers) consumidores"
EN_ESPERA="$(cola_campo admision.validados messages)"
verificar "quedaron eventos esperando en la cola" "$([ "${EN_ESPERA:-0}" -gt 0 ] && echo si || echo no)" "si"

paso "Vuelve el procesador"
procesador_con_pausa 0
for _ in $(seq 1 60); do
    [ "$(campo "$(estado_cinta)" paquetes_en_transito)" = "$N" ] && break
    sleep 1
done
sleep 2
mostrar_cinta
verificar "paquetes en la cinta (ni perdidos ni duplicados)" "$(campo "$(estado_cinta)" paquetes_en_transito)" "$N"
verificar "carga de la cinta" "$(campo "$(estado_cinta)" carga_kg)" "$ESPERADO_KG"
REENTREGAS="$(dc logs procesador_cola --since "$DESDE" 2>/dev/null | grep -c 'entrega duplicada')"
nota "reentregas detectadas por el consumidor idempotente en esta caida: $REENTREGAS"

# --- 2 ------------------------------------------------------------------------
seccion "2. El mismo evento llega dos veces"
nota "RabbitMQ entrega al menos una vez, no exactamente una: si el procesador"
nota "cae entre el commit y el ack, el evento vuelve. Se simula publicando dos"
nota "veces el mismo paquete.validado, con el mismo solicitud_id."
ID="$(uuid_nuevo)"
VENCE="$(date -u -d '+5 minutes' '+%Y-%m-%dT%H:%M:%S+00:00')"
EVENTO="{\"solicitud_id\":\"$ID\",\"vence_en\":\"$VENCE\",\"cinta_id\":\"$CINTA\",\"tipo_paquete\":\"normal\",\"peso_kg\":$PESO,\"alto_cm\":20,\"ancho_cm\":20,\"largo_cm\":20}"
DESDE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
paso "publicar paquete.validado  solicitud_id=$ID  (dos veces)"
nota "1ra: $(publicar_evento paquete.validado "$EVENTO")"
nota "2da: $(publicar_evento paquete.validado "$EVENTO")"
sleep 3

paso "Log del procesador"
dc logs procesador_cola --since "$DESDE" 2>/dev/null | grep "$ID" | sed 's/^/   /'
mostrar_cinta
verificar "se admitio un solo paquete" "$(campo "$(estado_cinta)" paquetes_en_transito)" "$(( N + 1 ))"
verificar "carga de la cinta" "$(campo "$(estado_cinta)" carga_kg)" "50.25"
verificar "estado en seguimiento" "$(campo "$(curl -s "$INGRESO/solicitudes/$ID")" estado)" "admitida"

cierre
