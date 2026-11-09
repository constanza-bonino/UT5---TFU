#!/usr/bin/env bash
#
# Queue-Based Load Leveling (rendimiento).
#
# En la UT4 la cola era una ruta alternativa (/paquetes/cola) al lado de la
# sincronica. En la UT5 todo el ingreso pasa por eventos: la cola deja de ser
# un patron agregado y pasa a ser el mecanismo normal de comunicacion.
#
#   1. una rafaga grande se acepta en segundos (HTTP 202)
#   2. los procesadores la consumen a su ritmo, sin perder nada
#   3. el cupo se respeta igual: entran exactamente los que caben
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

titulo "QUEUE-BASED LOAD LEVELING"
requiere_sistema

N="${N:-3000}"
CONCURRENCIA="${CONCURRENCIA:-500}"

nota "$N paquetes de 10 kg con concurrencia $CONCURRENCIA, por la entrada interna"
nota "82 (sin throttling). La cinta tiene lugar para 10."

reiniciar_cinta
paso "Rafaga y sondeo de resultados"
SALIDA="$(generador cola --n "$N" --c "$CONCURRENCIA" \
    --url http://balanceador:82/paquetes --estado-url http://balanceador:82/solicitudes \
    --cuerpo "$PAQUETE_10KG" --drain-timeout 180 --poll-interval 0.5 --poll-workers 50)"
printf '%s\n' "$SALIDA"

ACEPTADAS="$(printf '%s\n' "$SALIDA" | sed -n 's/.*aceptadas por la cola: \([0-9][0-9]*\).*/\1/p')"
PENDIENTES="$(printf '%s\n' "$SALIDA" | sed -n 's/.*solicitudes aun pendientes: \([0-9][0-9]*\).*/\1/p')"
P95="$(printf '%s\n' "$SALIDA" | sed -n 's/.*p95 \([0-9.]*\) ms.*/\1/p')"
ACEPTACION="$(printf '%s\n' "$SALIDA" | sed -n 's/.*tiempo para aceptar la rafaga: \([0-9.]*\) s.*/\1/p')"
VACIADO="$(printf '%s\n' "$SALIDA" | sed -n 's/.*tiempo desde inicio hasta vaciar la rafaga: \([0-9.]*\) s.*/\1/p')"

seccion "Resultado"
printf '\n'
printf '   %-42s %10s\n' "solicitudes aceptadas (202)" "${ACEPTADAS:-N/D}"
printf '   %-42s %10s\n' "p95 de la respuesta al cliente (ms)" "${P95:-N/D}"
printf '   %-42s %10s\n' "tiempo para aceptar la rafaga (s)" "${ACEPTACION:-N/D}"
printf '   %-42s %10s\n' "tiempo hasta decidir todas (s)" "${VACIADO:-N/D}"
printf '\n'
mostrar_cinta

verificar "todas aceptadas" "${ACEPTADAS:-0}" "$N"
verificar "ninguna quedo sin decidir" "${PENDIENTES:-N/D}" "0"
verificar "paquetes admitidos" "$(campo "$(estado_cinta)" paquetes_en_transito)" "10"

nota ""
nota "El cliente recibe 202 cuando el evento quedo guardado en el broker, sin"
nota "esperar a la base. La cola no agranda la cinta: reparte el trabajo en el"
nota "tiempo y protege a admision y a la base de los picos."

reiniciar_cinta
cierre
