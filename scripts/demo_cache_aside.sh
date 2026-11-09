#!/usr/bin/env bash
#
# UT4 - Cache-Aside (rendimiento).
#   1. Primera consulta: Cache Miss (consulta a admision y guarda en cache)
#   2. Consultas subsecuentes: Cache Hit (servidas desde memoria en ingreso)
#   3. Medicion de rendimiento: comparacion de latencia entre hit y miss
#   4. Invalidacion de cache al admitir un paquete nuevo (consistencia)
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

titulo "UT4: CACHE-ASIDE (RENDIMIENTO)"
requiere_sistema

# La cache vive en la memoria de cada replica de ingreso. Con varias, dos
# consultas seguidas caen en replicas distintas y la segunda tambien es MISS.
# Para medir el patron se deja una sola replica y al final se restauran.
REPLICAS="$(dc ps -q ingreso | wc -l | tr -d ' ')"
if [ "$REPLICAS" -gt 1 ]; then
    paso "Bajando ingreso de $REPLICAS replicas a 1 (la cache es local a cada replica)"
    dc up -d --no-deps --scale ingreso=1 ingreso > /dev/null 2>&1
    esperar
fi
restaurar() {
    [ "$REPLICAS" -gt 1 ] && dc up -d --no-deps --scale ingreso="$REPLICAS" ingreso > /dev/null 2>&1
}
trap restaurar EXIT

# Invalida la cache previa para iniciar limpio
curl -s -X POST "$INGRESO/cintas/$CINTA/cache/invalidar" > /dev/null 2>&1 || true

# --- 1 ------------------------------------------------------------------------
seccion "C.1  Cache Miss inicial y Cache Hit subsecuente"
nota "El cliente consulta el estado de la cinta a traves de ingreso."
nota "La cabecera X-Cache indica si la respuesta salio de la cache o del origen."
printf '\n'

paso "Primera consulta a /cintas/$CINTA (debe ser Cache Miss)"
RESP1="$(curl -s -D - "$INGRESO/cintas/$CINTA")"
X_CACHE1="$(printf '%s' "$RESP1" | grep -i '^X-Cache:' | tr -d '\r' | awk '{print $2}')"
nota "Respuesta: X-Cache = $X_CACHE1"
verificar "primera consulta es MISS" "$X_CACHE1" "MISS"

paso "Segunda consulta a /cintas/$CINTA (debe ser Cache Hit)"
RESP2="$(curl -s -D - "$INGRESO/cintas/$CINTA")"
X_CACHE2="$(printf '%s' "$RESP2" | grep -i '^X-Cache:' | tr -d '\r' | awk '{print $2}')"
nota "Respuesta: X-Cache = $X_CACHE2"
verificar "segunda consulta es HIT" "$X_CACHE2" "HIT"

# --- 2 ------------------------------------------------------------------------
seccion "C.2  Medicion empirica de rendimiento (Latencia)"
nota "UT5: un MISS ya no es una llamada REST sino una invocacion SOAP a admision"
nota "(sobre XML de ida y vuelta, mas la consulta a la base). Se miden 15 consultas"
nota "de cada tipo; son pocas para no chocar con el throttling de la entrada publica."
printf '\n'

N_LAT=15

# medir_latencia <hit|miss> -> latencia media en ms
medir_latencia() {
    local tiempos
    tiempos="$(for _ in $(seq 1 "$N_LAT"); do
        if [ "$1" = "miss" ]; then
            curl -s -o /dev/null -X POST "$INGRESO/cintas/$CINTA/cache/invalidar"
        fi
        curl -s -o /dev/null -w '%{time_total}\n' "$INGRESO/cintas/$CINTA"
    done)"
    awk '{ s += $1 } END { printf "%.2f", (s / NR) * 1000 }' <<< "$tiempos"
}

curl -s -o /dev/null "$INGRESO/cintas/$CINTA"
LAT_CACHE="$(medir_latencia hit)"
sleep 2   # que el limite de la entrada publica se reponga
LAT_ORIGEN="$(medir_latencia miss)"

printf '   %-38s %15s\n' "estrategia" "latencia media (ms)"
printf '   %-38s %15s\n' "--------------------------------------" "-------------------"
printf '   %-38s %15s\n' "Cache-Aside (HIT en ingreso)" "$LAT_CACHE"
printf '   %-38s %15s\n' "MISS (SOAP a admision y base)" "$LAT_ORIGEN"
printf '\n'

ok "Cache-Aside responde en $LAT_CACHE ms frente a $LAT_ORIGEN ms de ir al origen"

# --- 3 ------------------------------------------------------------------------
seccion "C.3  Invalidacion de Cache ante modificaciones (Consistencia)"
nota "Al admitir un paquete, la cache de la cinta debe invalidarse para no servir"
nota "lecturas obsoletas. UT5: la admision la decide otro componente, asi que"
nota "ingreso se entera por el evento paquete.admitido, al que esta suscripto."
printf '\n'

reiniciar_cinta
sleep 2
curl -s -X POST "$INGRESO/cintas/$CINTA/cache/invalidar" > /dev/null 2>&1 || true

paso "Consulta inicial para calentar cache"
curl -s "$INGRESO/cintas/$CINTA" > /dev/null
CARGA_ANTES="$(campo "$(curl -s "$INGRESO/cintas/$CINTA")" carga_kg)"
nota "Carga en cache antes de admitir paquete: $CARGA_ANTES kg"
verificar "carga inicial en cache" "$CARGA_ANTES" "0.0"

paso "Admitir un paquete de 10 kg y esperar la decision"
RESP_ADM="$(procesar_paquete "$PAQUETE_10KG")"
nota "Solicitud $(campo "$RESP_ADM" estado), paquete_id: $(campo "$RESP_ADM" paquete_id)"
sleep 0.5   # el evento llega a ingreso y a seguimiento en paralelo

paso "Siguiente lectura a /cintas/$CINTA (debe ser MISS por invalidacion y ver 10.0 kg)"
RESP_DESPUES="$(curl -s -D - "$INGRESO/cintas/$CINTA")"
X_CACHE_DESPUES="$(printf '%s' "$RESP_DESPUES" | grep -i '^X-Cache:' | tr -d '\r' | awk '{print $2}')"
CARGA_DESPUES="$(campo "$(printf '%s' "$RESP_DESPUES" | grep '^{')" carga_kg)"

nota "Respuesta: X-Cache = $X_CACHE_DESPUES, carga_kg = $CARGA_DESPUES"
verificar "cache invalidada produce MISS" "$X_CACHE_DESPUES" "MISS"
verificar "la nueva lectura refleja la carga actualizada" "$CARGA_DESPUES" "10.0"

paso "Consultando metricas del componente cache"
METRICAS="$(curl -s "$INGRESO/cache/metricas")"
nota "$METRICAS"
HITS_TOTALES="$(campo "$METRICAS" hits)"
if [ "${HITS_TOTALES:-0}" -gt 0 ]; then
    ok "la cache registro $HITS_TOTALES hits acumulados"
else
    fallo "no se registraron hits en la cache"
fi

nota ""
nota "Con varias replicas cada una tiene su cache: baja la tasa de aciertos, pero"
nota "la invalidacion llega a todas, porque cada replica se suscribe a"
nota "paquete.admitido con su propia cola temporal. Una cache compartida (Redis)"
nota "subiria los aciertos a cambio de otro componente y otro salto de red."

reiniciar_cinta
cierre
