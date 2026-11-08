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
nota "Midiendo 50 consultas servidas desde Cache en ingreso vs 50 directas a admision."
printf '\n'

medir_latencia() {
    local url="$1"
    local tiempos
    tiempos="$(for _ in $(seq 1 50); do
        curl -s -o /dev/null -w '%{time_total}\n' "$url"
    done)"
    awk '{ s += $1 } END { printf "%.2f", (s / NR) * 1000 }' <<< "$tiempos"
}

LAT_CACHE="$(medir_latencia "$INGRESO/cintas/$CINTA")"
LAT_ORIGEN="$(medir_latencia "$ADMISION/cintas/$CINTA")"

printf '   %-32s %15s\n' "estrategia" "latencia media (ms)"
printf '   %-32s %15s\n' "--------------------------------" "-------------------"
printf '   %-32s %15s\n' "Cache-Aside (HIT en ingreso)" "$LAT_CACHE"
printf '   %-32s %15s\n' "Sin cache (directo a admision)" "$LAT_ORIGEN"
printf '\n'

ok "Cache-Aside responde en $LAT_CACHE ms frente a $LAT_ORIGEN ms del servicio origen"

# --- 3 ------------------------------------------------------------------------
seccion "C.3  Invalidacion de Cache ante modificaciones (Consistencia)"
nota "Al admitir un paquete en ingreso, la cache de la cinta debe invalidarse"
nota "inmediatamente para no servir lecturas obsoletas."
printf '\n'

reiniciar_cinta
curl -s -X POST "$INGRESO/cintas/$CINTA/cache/invalidar" > /dev/null 2>&1 || true

paso "Consulta inicial para calentar cache"
curl -s "$INGRESO/cintas/$CINTA" > /dev/null
CARGA_ANTES="$(campo "$(curl -s "$INGRESO/cintas/$CINTA")" carga_kg)"
nota "Carga en cache antes de admitir paquete: $CARGA_ANTES kg"
verificar "carga inicial en cache" "$CARGA_ANTES" "0.0"

paso "Admitir un paquete de 10 kg en ingreso"
RESP_ADM="$(curl -s -X POST "$INGRESO/paquetes" \
    -H 'Content-Type: application/json' \
    -d "$PAQUETE_10KG")"
nota "Paquete admitido id: $(campo "$RESP_ADM" paquete_id)"

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

reiniciar_cinta
cierre
