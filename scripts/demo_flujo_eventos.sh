#!/usr/bin/env bash
#
# UT5 - Arquitectura dirigida por eventos (topologia broker).
#
#   cliente -> ingreso --paquete.recibido--> validacion --paquete.validado--> admision
#                                                 |                             |
#                                     paquete.rechazado (422)      paquete.admitido / rechazado
#                                                 v                             v
#                                            seguimiento  <---------------------+
#
#   1. los componentes y las interfaces (REST, SOAP y eventos)
#   2. un paquete atravesando la cadena, seguido por su solicitud_id
#   3. cada control vive en un procesador distinto
#   4. un paquete entra y despues sale
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

# traza <solicitud_id> <desde>: lineas de cada componente sobre esa solicitud,
# en orden de tiempo.
traza() {
    # Linea de docker logs: <servicio> | <hora docker> <fecha> <hora> INFO <mensaje>
    dc logs --timestamps --since "$2" validacion procesador_cola seguimiento 2>/dev/null \
        | grep "$1" | grep ' INFO ' \
        | awk '{ msj = ""; for (i = 7; i <= NF; i++) msj = msj " " $i
                 sub(/-[0-9]+$/, "", $1)
                 printf "%s\t%s\t%s\n", substr($3, 12, 12), $1, msj }' \
        | sort | awk -F'\t' '{ printf "      %s  %-16s%s\n", $1, $2, $3 }'
}

titulo "UT5 - FLUJO DE EVENTOS"
requiere_sistema

# --- 1 ------------------------------------------------------------------------
seccion "1. Componentes e interfaces"
dc ps --format 'table {{.Service}}\t{{.Status}}'

paso "IIngresoPaquetes (REST) - la expone ingreso, la consume el cliente"
curl -s "$INGRESO/openapi.json" | grep -o '"/[a-z0-9{}_/-]*"' | sort -u | sed 's/^/      /'

paso "Eventos - exchange topic cinta.eventos: quien escucha cada evento"
curl -s -u tfu:tfu "$RABBIT/api/exchanges/%2F/cinta.eventos/bindings/source" \
    | grep -o '"destination":"[^"]*"\|"routing_key":"[^"]*"' | sed 's/.*:"\(.*\)"/\1/' \
    | paste - - | awk '{ destino = ($1 ~ /^amq\.gen/) ? "cache de ingreso (cola temporal)" : "cola " $1
                         printf "      %-20s -> %s\n", $2, destino }' | sort
nota ""
nota "Nadie llama a nadie: cada componente publica un hecho y no sabe quien lo"
nota "consume. Sumar un consumidor nuevo es agregar un binding."

paso "IAdmisionCinta (SOAP) - la expone admision, la consume ingreso"
nota "contrato en $ADMISION/soap?wsdl (ver demo_soap.sh)"

paso "Estado de una solicitud (REST) - lo expone seguimiento, ingreso lo reenvia"
nota "GET $INGRESO/solicitudes/{solicitud_id}"

# --- 2 ------------------------------------------------------------------------
seccion "2. Un paquete atravesando la cadena"
reiniciar_cinta
mostrar_cinta
DESDE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

paso "Paquete valido de 10 kg"
RESPUESTA="$(curl_json POST "$INGRESO/paquetes" "$PAQUETE_10KG")"
nota "$RESPUESTA"
ID="$(campo "$RESPUESTA" solicitud_id)"
nota ""
nota "202: la solicitud quedo registrada como evento. Todavia no se decidio nada."

paso "El cliente consulta el resultado"
FINAL="$(esperar_resultado "$ID")"
nota "$FINAL"
verificar "estado" "$(campo "$FINAL" estado)" "admitida"
verificar "carga de la cinta" "$(campo "$(estado_cinta)" carga_kg)" "10.0"

paso "Lo que hizo cada componente con esta solicitud"
traza "$ID" "$DESDE"

# --- 3 ------------------------------------------------------------------------
seccion "3. Cada control vive en un procesador distinto"

paso "Validacion: fragil de 9 kg, el maximo es 8"
DESDE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ID="$(enviar_paquete "$PAQUETE_INVALIDO")"
FINAL="$(esperar_resultado "$ID")"
nota "$FINAL"
verificar "codigo del resultado" "$(campo "$FINAL" codigo_resultado)" "422"
traza "$ID" "$DESDE"
verificar "admision nunca vio el evento" \
    "$(dc logs --since "$DESDE" procesador_cola 2>/dev/null | grep -c "$ID")" "0"
verificar "la carga no cambio" "$(campo "$(estado_cinta)" carga_kg)" "10.0"

paso "Admision: lleno la cinta y pido 10 kg mas"
for _ in $(seq 1 9); do enviar_paquete "$PAQUETE_10KG" > /dev/null; done
esperar_cinta 10
mostrar_cinta
FINAL="$(procesar_paquete "$PAQUETE_10KG")"
nota "$FINAL"
verificar "codigo del resultado" "$(campo "$FINAL" codigo_resultado)" "409"
nota "Mismo paquete que antes entraba. Lo frena el control de cupo."

# --- 4 ------------------------------------------------------------------------
seccion "4. Un paquete entra y despues sale"
reiniciar_cinta

paso "Admito un paquete y me guardo su id"
FINAL="$(procesar_paquete "$PAQUETE_10KG")"
PAQUETE_ID="$(campo "$FINAL" paquete_id)"
nota "paquete_id = $PAQUETE_ID"
verificar "la cinta cargo los 10 kg" "$(campo "$(estado_cinta)" carga_kg)" "10.0"

paso "El paquete llega al final y se avisa el egreso (REST a admision)"
RESP="$(curl_json POST "$ADMISION/cintas/$CINTA/egresos" "{\"paquete_id\":\"$PAQUETE_ID\"}")"
nota "$RESP"
verificar "el peso se libero" "$(campo "$(estado_cinta)" carga_kg)" "0.0"
verificar "no quedan paquetes en transito" "$(campo "$(estado_cinta)" paquetes_en_transito)" "0"

paso "Egreso repetido del mismo paquete"
CODIGO="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ADMISION/cintas/$CINTA/egresos" \
          -H 'Content-Type: application/json' -d "{\"paquete_id\":\"$PAQUETE_ID\"}")"
verificar "se rechaza, el peso no se resta dos veces" "$CODIGO" "404"

cierre
