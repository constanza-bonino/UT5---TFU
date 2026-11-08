#!/usr/bin/env bash
#
# Componentes e interfaces.
#
#   cliente -> IIngresoPaquetes -> ingreso -> IAdmisionCinta -> admision -> BD
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

titulo "DEMOSTRACION 1 — COMPONENTES E INTERFACES"
requiere_sistema

seccion "1.1  Los componentes estan desplegados por separado"
dc ps --format 'table {{.Name}}\t{{.Service}}\t{{.Status}}'

paso "Sonda de vida de cada uno"
nota "ingreso  -> $(curl -s "$INGRESO/health")"
nota "admision -> $(curl -s "$ADMISION/health")"

seccion "1.2  Las interfaces publicadas"

paso "IIngresoPaquetes — la expone ingreso, la consume el cliente"
curl -s "$INGRESO/openapi.json" | grep -o '"/[a-z0-9{}_/-]*"' | sort -u | sed 's/^/      /'

paso "IAdmisionCinta — la expone admision, la consume ingreso"
curl -s "$ADMISION/openapi.json" | grep -o '"/[a-z0-9{}_/-]*"' | sort -u | sed 's/^/      /'
nota ""
nota "Las rutas bajo /demo las usan estos scripts, no son parte de la interfaz."
nota "Tambien estan en $INGRESO/docs y $ADMISION/docs"
nota ""
nota "IRepositorioCinta no es REST: es la clase abstracta de repositorio.py."

paso "Formato de las solicitudes"
cat <<FORMATO
      curl -X POST $INGRESO/paquetes \\
           -H 'Content-Type: application/json' \\
           -d '{"tipo_paquete":"normal","peso_kg":10,
                "alto_cm":50,"ancho_cm":50,"largo_cm":70}'

      curl $ADMISION/cintas/$CINTA

      curl -X POST $ADMISION/cintas/$CINTA/egresos \\
           -H 'Content-Type: application/json' \\
           -d '{"paquete_id":"<uuid que devolvio POST /paquetes>"}'
FORMATO
nota ""
nota "tipo_paquete: 'normal' o 'fragil'. Los cuatro campos de medidas son"
nota "obligatorios; si falta alguno o no es numerico, da 422."

seccion "1.3  Un paquete atravesando la cadena completa"
reiniciar_cinta
mostrar_cinta

paso "Paquete valido de 10 kg"
RESPUESTA="$(curl_json POST "$INGRESO/paquetes" "$PAQUETE_10KG")"
nota "$RESPUESTA"
nota ""
nota "El campo 'instancia' trae dos nombres: paso por dos componentes."

verificar "carga de la cinta" "$(campo "$(estado_cinta)" carga_kg)" "10.0"

seccion "1.4  Cada control vive en un componente distinto"

paso "Control 1 (ingreso): fragil de 9 kg, el maximo es 8"
CODIGO="$(curl -s -o /tmp/r1.json -w '%{http_code}' -X POST "$INGRESO/paquetes" \
          -H 'Content-Type: application/json' -d "$PAQUETE_INVALIDO")"
nota "HTTP $CODIGO -> $(cat /tmp/r1.json)"
verificar "codigo devuelto" "$CODIGO" "422"
verificar "la carga no cambio, el rechazo no llego a admision" "$(campo "$(estado_cinta)" carga_kg)" "10.0"

paso "Control 2 (admision): lleno la cinta y pido 10 kg mas"
for _ in $(seq 1 9); do
    curl -s -o /dev/null -X POST "$INGRESO/paquetes" -H 'Content-Type: application/json' -d "$PAQUETE_10KG"
done
mostrar_cinta

CODIGO="$(curl -s -o /tmp/r2.json -w '%{http_code}' -X POST "$INGRESO/paquetes" \
          -H 'Content-Type: application/json' -d "$PAQUETE_10KG")"
nota "HTTP $CODIGO -> $(cat /tmp/r2.json)"
verificar "codigo devuelto" "$CODIGO" "409"
nota "Mismo paquete que antes entraba. Lo frena el control de cupo."

seccion "1.5  Un paquete entra y despues sale"
reiniciar_cinta

paso "Admito un paquete y me guardo su id"
RESP="$(curl_json POST "$INGRESO/paquetes" "$PAQUETE_10KG")"
PAQUETE_ID="$(campo "$RESP" paquete_id)"
nota "paquete_id = $PAQUETE_ID"
mostrar_cinta
verificar "la cinta cargo los 10 kg" "$(campo "$(estado_cinta)" carga_kg)" "10.0"

paso "El paquete llega al final y se avisa el egreso"
RESP="$(curl_json POST "$ADMISION/cintas/$CINTA/egresos" "{\"paquete_id\":\"$PAQUETE_ID\"}")"
nota "$RESP"
mostrar_cinta
verificar "el peso se libero" "$(campo "$(estado_cinta)" carga_kg)" "0.0"
verificar "no quedan paquetes en transito" "$(campo "$(estado_cinta)" paquetes_en_transito)" "0"

paso "Egreso repetido del mismo paquete"
CODIGO="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ADMISION/cintas/$CINTA/egresos" \
          -H 'Content-Type: application/json' -d "{\"paquete_id\":\"$PAQUETE_ID\"}")"
verificar "se rechaza, el peso no se resta dos veces" "$CODIGO" "404"

rm -f /tmp/r1.json /tmp/r2.json
cierre
