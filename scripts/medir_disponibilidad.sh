#!/usr/bin/env bash
#
# UT5 - Validacion del atributo de calidad: DISPONIBILIDAD.
#
# Escenario: llegan paquetes a una tasa fija (TASA por segundo durante SEGUNDOS)
# y entre DESDE y HASTA se cae un componente. Se repite para:
#
#   UT4 sincronica  POST /paquetes de la UT4: ingreso llama a admision y espera
#   UT4 con cola    POST /paquetes/cola de la UT4: la ruta alternativa por cola
#   UT5 eventos     POST /paquetes de la UT5
#
# y para dos fallas:
#
#   admision  se caen admision y su procesador (docker compose kill)
#   base      se cae PostgreSQL
#
# Mide, para cada caso:
#   - que porcentaje de las solicitudes enviadas durante la caida se acepto
#   - si la consulta de estado de una solicitud siguio respondiendo
#   - cuantas de las aceptadas terminaron con resultado final, y cuanto tardo
#     la ultima despues de que volvio el componente
#
# La UT4 se levanta desde el commit de la entrega anterior (acb19c6), sin
# cambios, en un directorio aparte. Mientras se mide la UT4 se detiene la UT5,
# porque las dos publican los mismos puertos.
#
#   bash scripts/medir_disponibilidad.sh
#   SOLO=ut5 bash scripts/medir_disponibilidad.sh     (solo la UT5)
#
# La salida completa queda en resultados/disponibilidad.txt
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

# La caida dura 20 s a proposito: mas que el timeout de 15 s con el que la UT4
# espera a admision (TIMEOUT_ADMISION_S). Con caidas mas cortas la UT4
# sincronica no da error: deja al cliente bloqueado hasta que admision vuelve.
TASA="${TASA:-10}"
SEGUNDOS="${SEGUNDOS:-40}"
DESDE="${DESDE:-10}"
HASTA="${HASTA:-30}"
COMMIT_UT4="${COMMIT_UT4:-acb19c6}"
DIR_UT4="$RAIZ/.comparacion-ut4"
PROYECTO_UT4="tfu-ut4-comparacion"
PROYECTO_UT5="$(cd "$RAIZ" && docker compose config --format json 2>/dev/null | sed -n 's/^ *"name": *"\([^"]*\)".*/\1/p' | head -1)"
PROYECTO_UT5="${PROYECTO_UT5:-tfu-ut5}"

# 0.1 kg: los 300 paquetes entran en la cinta, asi que todo el que se acepta
# deberia terminar admitido. Lo que se mide es la disponibilidad, no el cupo.
LIVIANO='{"tipo_paquete":"normal","peso_kg":0.1,"alto_cm":20,"ancho_cm":20,"largo_cm":20}'

mkdir -p "$RAIZ/resultados"
SALIDA_TXT="$RAIZ/resultados/disponibilidad.txt"
exec > >(tee "$SALIDA_TXT") 2>&1

declare -A R   # R[config|escenario|clave] = valor

# compose_de <proyecto> <args...>
compose_de() {
    if [ "$1" = "$PROYECTO_UT4" ]; then
        ( cd "$DIR_UT4" && docker compose -p "$PROYECTO_UT4" "${@:2}" )
    else
        ( cd "$RAIZ" && docker compose "${@:2}" )
    fi
}

esperar_hasta() { local s=$(( $1 - EPOCHSECONDS )); [ "$s" -gt 0 ] && sleep "$s"; return 0; }

# segundos_desde <epoch> -> segundos transcurridos, con un decimal
segundos_desde() {
    local us=$(( ${EPOCHREALTIME/[.,]/} - $1 * 1000000 ))
    printf '%d.%d' $(( us / 1000000 )) $(( us % 1000000 / 100000 ))
}

sistema_listo() {
    for _ in $(seq 1 60); do
        curl -sf "$INGRESO/health" > /dev/null 2>&1 && curl -sf "$ADMISION/health" > /dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

# correr <config> <escenario> <proyecto> <url> <url_estado|""> <servicios...>
correr() {
    local config="$1" escenario="$2" proyecto="$3" url="$4" estado="$5"
    shift 5
    local servicios=("$@") salida inicio pid
    paso "$config  —  falla: $escenario (${servicios[*]})"

    if [ "$proyecto" = "$PROYECTO_UT5" ]; then reiniciar_cinta; else
        curl -s -X POST "$ADMISION/demo/cintas/$CINTA/reiniciar" > /dev/null; fi

    salida="$(mktemp)"
    inicio=$(( EPOCHSECONDS + 5 ))
    docker run --rm --network "${proyecto}_default" "${PROYECTO_UT5}-generador" disponibilidad \
        --url "$url" ${estado:+--estado-url "$estado"} --cuerpo "$LIVIANO" \
        --tasa "$TASA" --segundos "$SEGUNDOS" --empezar-en "$inicio" \
        --caida-desde "$DESDE" --caida-hasta "$HASTA" --drain-timeout 120 > "$salida" 2>&1 &
    pid=$!

    # docker compose tarda un par de segundos en ejecutar cada comando: se
    # informa el momento en que el comando termino, que es la caida real.
    esperar_hasta $(( inicio + DESDE ))
    compose_de "$proyecto" kill "${servicios[@]}" > /dev/null 2>&1
    nota "t=$(segundos_desde "$inicio") s  docker compose kill ${servicios[*]} (programado en t=$DESDE s)"
    esperar_hasta $(( inicio + HASTA ))
    compose_de "$proyecto" start "${servicios[@]}" > /dev/null 2>&1
    nota "t=$(segundos_desde "$inicio") s  docker compose start ${servicios[*]} (programado en t=$HASTA s)"
    wait "$pid"

    grep -v '^RESULTADO|' "$salida"
    while IFS='|' read -r _ grupo resto; do
        local par
        IFS='|' read -ra pares <<< "$resto"
        for par in "${pares[@]}"; do
            R["$config|$escenario|$grupo.${par%%=*}"]="${par#*=}"
        done
    done < <(grep '^RESULTADO|' "$salida")
    rm -f "$salida"
    sistema_listo || fallo "el sistema no volvio a responder"
    sleep 3
}

titulo "UT5 - VALIDACION DEL ATRIBUTO DE CALIDAD: DISPONIBILIDAD"
nota "$TASA solicitudes/s durante $SEGUNDOS s; el componente cae entre t=$DESDE s y t=$HASTA s."
nota "Fecha: $(date '+%Y-%m-%d %H:%M')"

# --- UT5 ----------------------------------------------------------------------
seccion "UT5: arquitectura dirigida por eventos"
requiere_sistema
dc --profile demos build generador > /dev/null 2>&1
correr "UT5 eventos" admision "$PROYECTO_UT5" http://balanceador:82/paquetes \
    http://balanceador:82/solicitudes admision procesador_cola
correr "UT5 eventos" base "$PROYECTO_UT5" http://balanceador:82/paquetes \
    http://balanceador:82/solicitudes db

# --- UT4 ----------------------------------------------------------------------
if [ "${SOLO:-}" != "ut5" ]; then
    seccion "UT4: arquitectura basada en servicios (commit $COMMIT_UT4)"
    paso "Se detiene la UT5 y se levanta la UT4 sin cambios"
    dc stop > /dev/null 2>&1
    rm -rf "$DIR_UT4" && mkdir -p "$DIR_UT4"
    git -C "$RAIZ" archive "$COMMIT_UT4" | tar -x -C "$DIR_UT4"
    compose_de "$PROYECTO_UT4" up -d --build > /dev/null 2>&1
    sistema_listo || { fallo "la UT4 no levanto"; }
    sleep 5

    correr "UT4 sincronica" admision "$PROYECTO_UT4" http://balanceador:82/paquetes "" \
        admision procesador_cola
    correr "UT4 con cola" admision "$PROYECTO_UT4" http://balanceador:82/paquetes/cola \
        http://balanceador:82/solicitudes admision procesador_cola
    correr "UT4 sincronica" base "$PROYECTO_UT4" http://balanceador:82/paquetes "" db
    correr "UT4 con cola" base "$PROYECTO_UT4" http://balanceador:82/paquetes/cola \
        http://balanceador:82/solicitudes db

    paso "Se baja la UT4 y vuelve la UT5"
    compose_de "$PROYECTO_UT4" down -v > /dev/null 2>&1
    rm -rf "$DIR_UT4"
    dc start > /dev/null 2>&1
    sistema_listo || fallo "la UT5 no volvio a responder"
fi

# --- Comparacion --------------------------------------------------------------
seccion "Comparacion"
v() { printf '%s' "${R[$1]:-n/a}"; }
for escenario in admision base; do
    printf '\n   Falla: %s, caida de %s s\n\n' "$escenario" "$(( HASTA - DESDE ))"
    printf '   %-15s %10s %10s %10s %10s %10s %11s %11s\n' "" "aceptadas" "en < 1 s" "latencia" "en < 1 s" "consulta" "resueltas" "ultima tras"
    printf '   %-15s %10s %10s %10s %10s %10s %11s %11s\n' "configuracion" "durante %" "durante %" "max dur. s" "despues %" "estado %" "/aceptadas" "volver (s)"
    printf '   %-15s %10s %10s %10s %10s %10s %11s %11s\n' "---------------" "---------" "---------" "---------" "---------" "---------" "----------" "----------"
    for config in "UT4 sincronica" "UT4 con cola" "UT5 eventos"; do
        [ -z "${R[$config|$escenario|durante.porcentaje]:-}" ] && continue
        printf '   %-15s %10s %10s %10s %10s %10s %11s %11s\n' "$config" \
            "$(v "$config|$escenario|durante.porcentaje")" \
            "$(v "$config|$escenario|durante.rapidas")" \
            "$(v "$config|$escenario|durante.max_s")" \
            "$(v "$config|$escenario|despues.rapidas")" \
            "$(v "$config|$escenario|consulta.porcentaje")" \
            "$(v "$config|$escenario|resolucion.resueltas")/$(v "$config|$escenario|resolucion.aceptadas")" \
            "$(v "$config|$escenario|resolucion.segundos_tras_volver")"
    done
done

printf '\n'
nota "aceptadas: respuesta 200 o 202, tarde lo que tarde. en < 1 s: aceptadas y"
nota "respondidas en menos de un segundo. consulta estado: GET /solicitudes/{id}"
nota "durante la caida (la UT4 sincronica no tiene). resueltas: aceptadas que"
nota "terminaron con resultado final."
printf '\n'
verificar "UT5 acepta en menos de 1 s durante la caida de admision" "$(v "UT5 eventos|admision|durante.rapidas")" "100.0"
verificar "UT5 acepta en menos de 1 s durante la caida de la base" "$(v "UT5 eventos|base|durante.rapidas")" "100.0"
verificar "UT5 no pierde solicitudes (falla admision)" "$(v "UT5 eventos|admision|resolucion.sin_resolver")" "0"
verificar "UT5 no pierde solicitudes (falla base)" "$(v "UT5 eventos|base|resolucion.sin_resolver")" "0"
nota ""
nota "Salida completa en resultados/disponibilidad.txt"
cierre
