#!/usr/bin/env bash
#
# Patrones de seguridad: Gatekeeper y Gateway Offloading.
#
#   1. Gatekeeper
#      - un evento falsificado (sin la credencial interna) no admite nada:
#        admision lo descarta y termina en la cola de fallidos
#      - el mismo evento con la credencial si se procesa
#      - un paquete no conforme lo frena validacion antes de llegar a admision
#   2. Gateway Offloading
#      - ingreso autentica a los clientes externos (API Key) en la frontera
#      - clave invalida: 401 en el acto, no se publica ningun evento
#      - clave valida: 202 y la solicitud queda a nombre del cliente
#
# UT5: en la UT4 el Gatekeeper era una cabecera HTTP que admision exigia en
# POST /cintas/{id}/admisiones. Ese endpoint ya no existe: admision solo
# reacciona a eventos, asi que la credencial interna viaja en cada evento y
# cada procesador la verifica antes de actuar.
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

titulo "GATEKEEPER Y GATEWAY OFFLOADING (SEGURIDAD)"
requiere_sistema
reiniciar_cinta

# evento_validado <solicitud_id>: un paquete.validado de 10 kg
evento_validado() {
    printf '{"solicitud_id":"%s","vence_en":"%s","cinta_id":"%s","tipo_paquete":"normal","peso_kg":10,"alto_cm":50,"ancho_cm":50,"largo_cm":70}' \
        "$1" "$(date -u -d '+5 minutes' '+%Y-%m-%dT%H:%M:%S+00:00')" "$CINTA"
}

# ==============================================================================
seccion "S.1  Gatekeeper"
# ==============================================================================
nota "Admision no tiene una API para admitir: actua al recibir paquete.validado."
nota "Quien logre publicar en el broker podria intentar saltarse la validacion"
nota "publicando ese evento directamente. Cada evento lleva la credencial interna"
nota "en sus cabeceras y admision descarta los que no la traen."
printf '\n'

FALLIDOS_ANTES="$(campo "$(cola_info admision.validados.fallidos)" messages)"
DESDE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

paso "1. paquete.validado publicado SIN la credencial interna"
ID="$(uuid_nuevo)"
nota "publicacion: $(publicar_evento paquete.validado "$(evento_validado "$ID")" "clave-falsa")"
sleep 2
dc logs procesador_cola --since "$DESDE" 2>/dev/null | grep -i 'credencial' | tail -1 | sed 's/^/   /'
verificar "la carga no cambio" "$(campo "$(estado_cinta)" carga_kg)" "0.0"
sleep 5   # la API de RabbitMQ actualiza sus contadores cada 5 s
FALLIDOS_DESPUES="$(campo "$(cola_info admision.validados.fallidos)" messages)"
verificar "el evento termino en admision.validados.fallidos" \
    "$(( ${FALLIDOS_DESPUES:-0} - ${FALLIDOS_ANTES:-0} ))" "1"

paso "2. El mismo evento CON la credencial interna"
ID="$(uuid_nuevo)"
nota "publicacion: $(publicar_evento paquete.validado "$(evento_validado "$ID")")"
FINAL="$(esperar_resultado "$ID")"
verificar "admision lo proceso" "$(campo "$FINAL" estado)" "admitida"
verificar "carga" "$(campo "$(estado_cinta)" carga_kg)" "10.0"

paso "3. Paquete no conforme por la entrada publica (fragil de 9 kg, maximo 8)"
FINAL="$(procesar_paquete "$PAQUETE_INVALIDO")"
nota "$FINAL"
verificar "validacion lo rechaza" "$(campo "$FINAL" codigo_resultado)" "422"
verificar "la carga no vario" "$(campo "$(estado_cinta)" carga_kg)" "10.0"

# ==============================================================================
seccion "S.2  Gateway Offloading (autenticacion en la frontera)"
# ==============================================================================
nota "La autenticacion de los clientes externos se resuelve en ingreso. Ningun"
nota "procesador de eventos conoce ni valida API Keys de clientes."
printf '\n'

paso "1. API Key invalida"
CODIGO="$(curl -s -o /tmp/gw.json -w '%{http_code}' -X POST "$INGRESO/paquetes" \
    -H 'Content-Type: application/json' -H 'X-API-Key: clave-cliente-inexistente' \
    -d "$PAQUETE_10KG")"
nota "HTTP $CODIGO -> $(cat /tmp/gw.json)"
verificar "ingreso rechaza la credencial" "$CODIGO" "401"

paso "2. API Key valida (cliente-alpha)"
CODIGO="$(curl -s -o /tmp/gw.json -w '%{http_code}' -X POST "$INGRESO/paquetes" \
    -H 'Content-Type: application/json' -H 'X-API-Key: cliente-alpha' \
    -d "$PAQUETE_10KG")"
nota "HTTP $CODIGO -> $(cat /tmp/gw.json)"
verificar "ingreso acepta la solicitud" "$CODIGO" "202"
verificar "cliente identificado en la frontera" "$(campo "$(cat /tmp/gw.json)" cliente)" "cliente-alpha"
FINAL="$(esperar_resultado "$(campo "$(cat /tmp/gw.json)" solicitud_id)")"
verificar "y despues se admite" "$(campo "$FINAL" estado)" "admitida"

rm -f /tmp/gw.json
reiniciar_cinta
cierre
