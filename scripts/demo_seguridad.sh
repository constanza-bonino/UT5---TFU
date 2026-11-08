#!/usr/bin/env bash
#
# UT4 - Patrones de Seguridad: Gatekeeper y Gateway Offloading.
#   1. Gatekeeper:
#      - Intento de admision directa a admision sin credencial interna (403)
#      - Admision pasando por ingreso (Gatekeeper valida y adjunta credencial interna) (200)
#      - Filtrado de paquetes anomalos en el Gatekeeper antes de llegar al backend (422)
#   2. Gateway Offloading:
#      - Autenticacion de clientes externos descargada en la frontera (ingreso)
#      - Rechazo de clave de cliente externa invalida con 401
#      - Aceptacion de clave valida con 200
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

titulo "UT4: GATEKEEPER Y GATEWAY OFFLOADING (SEGURIDAD)"
requiere_sistema
reiniciar_cinta

# ==============================================================================
seccion "S.1  Gatekeeper (Proteccion del perimetro y sanitizacion de entrada)"
# ==============================================================================

nota "El backend (admision) es un recurso protegido que solo confia en el"
nota "Gatekeeper (ingreso). Clientes externos no deben poder saltarse las"
nota "validaciones de negocio comunicandose directamente con admision."
printf '\n'

paso "1. Intento de admision directa a admision SIN credencial interna"
CODIGO_DIRECTO="$(curl -s -o /tmp/gate_resp.json -w '%{http_code}' \
    -X POST "$ADMISION/cintas/$CINTA/admisiones" \
    -H 'Content-Type: application/json' \
    -d '{"tipo_paquete":"normal","peso_kg":10}')"
nota "HTTP $CODIGO_DIRECTO -> $(cat /tmp/gate_resp.json 2>/dev/null)"
verificar "admision rechaza solicitud directa sin credencial" "$CODIGO_DIRECTO" "403"

paso "2. Admision a traves del Gatekeeper (ingreso)"
CODIGO_GATE="$(curl -s -o /tmp/gate_resp2.json -w '%{http_code}' \
    -X POST "$INGRESO/paquetes" \
    -H 'Content-Type: application/json' \
    -d "$PAQUETE_10KG")"
nota "HTTP $CODIGO_GATE -> $(cat /tmp/gate_resp2.json 2>/dev/null)"
verificar "a traves de ingreso la solicitud es admitida" "$CODIGO_GATE" "200"

paso "3. Sanitizacion en el Gatekeeper: paquete no conforme (fragil de 9 kg, maximo 8 kg)"
CODIGO_INVALIDO="$(curl -s -o /tmp/gate_resp3.json -w '%{http_code}' \
    -X POST "$INGRESO/paquetes" \
    -H 'Content-Type: application/json' \
    -d "$PAQUETE_INVALIDO")"
nota "HTTP $CODIGO_INVALIDO -> $(cat /tmp/gate_resp3.json 2>/dev/null)"
verificar "Gatekeeper bloquea paquete invalido en el perimetro" "$CODIGO_INVALIDO" "422"

CARGA_ACTUAL="$(campo "$(estado_cinta)" carga_kg)"
verificar "la carga en admision no vario por el paquete invalido" "$CARGA_ACTUAL" "10.0"

# ==============================================================================
seccion "S.2  Gateway Offloading (Descarga de autenticacion de clientes)"
# ==============================================================================

nota "La autenticacion de los clientes externos se resuelve en la frontera"
nota "(ingreso / API Gateway), liberando al servicio interno (admision) de"
nota "gestionar identidades, tokens o API keys de clientes externos."
printf '\n'

paso "1. Solicitud con API Key invalida hacia el Gateway"
CODIGO_AUTH_FAIL="$(curl -s -o /tmp/gw_auth_fail.json -w '%{http_code}' \
    -X POST "$INGRESO/paquetes" \
    -H 'Content-Type: application/json' \
    -H 'X-API-Key: clave-cliente-inexistente' \
    -d "$PAQUETE_10KG")"
nota "HTTP $CODIGO_AUTH_FAIL -> $(cat /tmp/gw_auth_fail.json 2>/dev/null)"
verificar "Gateway rechaza credencial de cliente invalida" "$CODIGO_AUTH_FAIL" "401"

paso "2. Solicitud con API Key valida hacia el Gateway (cliente-alpha)"
CODIGO_AUTH_OK="$(curl -s -o /tmp/gw_auth_ok.json -w '%{http_code}' \
    -X POST "$INGRESO/paquetes" \
    -H 'Content-Type: application/json' \
    -H 'X-API-Key: cliente-alpha' \
    -d "$PAQUETE_10KG")"
nota "HTTP $CODIGO_AUTH_OK -> $(cat /tmp/gw_auth_ok.json 2>/dev/null)"
verificar "Gateway autentica y procesa la solicitud con exito" "$CODIGO_AUTH_OK" "200"

CLIENTE_RESP="$(campo "$(cat /tmp/gw_auth_ok.json 2>/dev/null)" cliente)"
verificar "cliente identificado por Gateway" "$CLIENTE_RESP" "cliente-alpha"

nota ""
nota "Admision jamas vio ni proceso la API Key del cliente externo:"
nota "la responsabilidad de autenticacion quedo totalmente descargada en el Gateway."

rm -f /tmp/gate_resp.json /tmp/gate_resp2.json /tmp/gate_resp3.json /tmp/gw_auth_fail.json /tmp/gw_auth_ok.json
reiniciar_cinta
cierre
