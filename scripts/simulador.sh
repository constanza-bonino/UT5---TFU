#!/usr/bin/env bash
#
# La cinta funcionando en el tiempo. No es una de las cinco demostraciones.
#
# Cada segundo llega un paquete de peso aleatorio. Si entra en el cupo viaja unos
# segundos y despues sale por el otro extremo liberando su lugar.
#
#   DURACION=60 TRANSITO=20 bash scripts/simulador.sh
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

DURACION="${DURACION:-45}"    # cuantos segundos dura la simulacion
TRANSITO="${TRANSITO:-14}"    # cuantos segundos tarda un paquete en recorrer la cinta
INTERVALO="${INTERVALO:-1}"   # cada cuantos segundos llega un paquete

EN_CINTA="$(mktemp)"          # lineas: <momento_de_salida> <id> <peso>
ADMITIDOS=0
RECHAZADOS=0
EGRESADOS=0

titulo "SIMULADOR — la cinta funcionando en el tiempo"
requiere_sistema
reiniciar_cinta

CAPACIDAD="$(campo "$(estado_cinta)" capacidad_kg)"

nota "capacidad de la cinta : $CAPACIDAD kg"
nota "llega un paquete cada : $INTERVALO s (peso aleatorio entre 5 y 25 kg)"
nota "recorrido de la cinta : $TRANSITO s"
nota "duracion              : $DURACION s"
nota ""
nota "Cada linea es un segundo. La barra es la ocupacion de la cinta."
printf '\n'
printf '  tiempo   ocupacion de la cinta            carga en kg    paquetes   salen          llega\n'
printf '  ------   ------------------------------   ------------   --------   ------------   -----------\n'

# La vuelta usa solo funciones de bash (EPOCHREALTIME, aritmetica, mapfile) y
# no date, awk o wc: en Windows cada proceso cuesta ~100 ms y la vuelta tiene
# que entrar en un segundo.

# microsegundos desde 1970
ahora_us() { local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$t"; }

# barra <carga> <capacidad>
barra() {
    local carga="${1%.*}" capacidad="${2%.*}" llenos i
    llenos=$(( ${carga:-0} * 28 / ${capacidad:-1} ))
    printf '['
    for (( i = 1; i <= 28; i++ )); do
        if [ "$i" -le "$llenos" ]; then printf '#'; else printf '.'; fi
    done
    printf ']'
}

INICIO="$EPOCHSECONDS"

while true; do
    TIC_INICIO="$(ahora_us)"
    AHORA="$EPOCHSECONDS"
    T=$(( AHORA - INICIO ))
    [ "$T" -ge "$DURACION" ] && break

    SALIDAS=""

    # --- 1. Sacar los paquetes que ya terminaron su recorrido ---------------
    if [ -s "$EN_CINTA" ]; then
        : > "$EN_CINTA.nuevo"
        while read -r momento id peso; do
            if [ "$AHORA" -ge "$momento" ]; then
                curl -s -o /dev/null -X POST "$ADMISION/cintas/$CINTA/egresos" \
                    -H 'Content-Type: application/json' -d "{\"paquete_id\":\"$id\"}"
                EGRESADOS=$(( EGRESADOS + 1 ))
                SALIDAS="${SALIDAS}-${peso}kg "
            else
                echo "$momento $id $peso" >> "$EN_CINTA.nuevo"
            fi
        done < "$EN_CINTA"
        mv "$EN_CINTA.nuevo" "$EN_CINTA"
    fi

    # --- 2. Llega un paquete nuevo ------------------------------------------
    # UT5: se envia la solicitud (202) y se espera la decision de admision.
    PESO=$(( (RANDOM % 5 + 1) * 5 ))
    CUERPO="$(procesar_paquete \
        "{\"tipo_paquete\":\"normal\",\"peso_kg\":$PESO,\"alto_cm\":50,\"ancho_cm\":50,\"largo_cm\":70}")"

    if [ "$(campo "$CUERPO" estado)" = "admitida" ]; then
        ID="$(campo "$CUERPO" paquete_id)"
        echo "$(( AHORA + TRANSITO )) $ID $PESO" >> "$EN_CINTA"
        ADMITIDOS=$(( ADMITIDOS + 1 ))
        EVENTO="entra ${PESO}kg"
    else
        RECHAZADOS=$(( RECHAZADOS + 1 ))
        EVENTO="RECHAZA ${PESO}kg (sin cupo)"
    fi

    # --- 3. Mostrar el estado -----------------------------------------------
    # La carga sale de la respuesta anterior, tanto si el paquete entro como si
    # lo rechazaron. Asi se evita una llamada HTTP extra por vuelta.
    CARGA="$(campo "$CUERPO" carga_kg)"
    mapfile -t LINEAS < "$EN_CINTA"
    PAQ="${#LINEAS[@]}"

    # Las salidas van primero porque ocurren primero: un paquete libera su lugar
    # antes de que se intente admitir al siguiente.
    printf ' t=%3ss  %s  %5s/%s kg  %2s paq   %-14s %s\n' \
        "$T" "$(barra "$CARGA" "$CAPACIDAD")" "$CARGA" "$CAPACIDAD" "$PAQ" "$SALIDAS" "$EVENTO"

    # Dormir solo lo que falte para completar el intervalo, descontando lo que
    # tardaron las llamadas HTTP. Si no, cada vuelta se va corriendo.
    DEMORA_MS=$(( ( $(ahora_us) - TIC_INICIO ) / 1000 ))
    RESTA_MS=$(( INTERVALO * 1000 - DEMORA_MS ))
    if [ "$RESTA_MS" -gt 0 ]; then
        printf -v ESPERA '%d.%03d' $(( RESTA_MS / 1000 )) $(( RESTA_MS % 1000 ))
        sleep "$ESPERA"
    fi
done

# --- Vaciar la cinta al terminar -------------------------------------------
printf '\n'
paso "Fin de la simulacion: sacando los paquetes que quedaron"
if [ -s "$EN_CINTA" ]; then
    while read -r _ id _; do
        curl -s -o /dev/null -X POST "$ADMISION/cintas/$CINTA/egresos" \
            -H 'Content-Type: application/json' -d "{\"paquete_id\":\"$id\"}"
        EGRESADOS=$(( EGRESADOS + 1 ))
    done < "$EN_CINTA"
fi
mostrar_cinta

seccion "Resumen"
nota "paquetes admitidos : $ADMITIDOS"
nota "paquetes rechazados: $RECHAZADOS  (la cinta estaba llena)"
nota "paquetes egresados : $EGRESADOS"
printf '\n'
verificar "la cinta quedo vacia al final" "$(campo "$(estado_cinta)" carga_kg)" "0.0"
verificar "todo lo que entro, salio" "$EGRESADOS" "$ADMITIDOS"

rm -f "$EN_CINTA" "$EN_CINTA.nuevo"
cierre
