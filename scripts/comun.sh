#!/usr/bin/env bash
# Funciones que usan todos los scripts de demostracion.
# No se ejecuta solo: los demas lo cargan con `source`.

set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INGRESO="${INGRESO:-http://localhost:8080}"
ADMISION="${ADMISION:-http://localhost:8081}"
CINTA="${CINTA_ID:-C1}"


PAQUETE_10KG='{"tipo_paquete":"normal","peso_kg":10,"alto_cm":50,"ancho_cm":50,"largo_cm":70}'
PAQUETE_INVALIDO='{"tipo_paquete":"fragil","peso_kg":9,"alto_cm":30,"ancho_cm":30,"largo_cm":40}'

FALLAS=0

# --- salida ------------------------------------------------------------------

titulo()  { printf '\n==============================================================\n  %s\n==============================================================\n' "$*"; }
seccion() { printf '\n--- %s ---------------------------------\n' "$*"; }
paso()    { printf '\n>> %s\n' "$*"; }
nota()    { printf '   %s\n' "$*"; }
ok()      { printf '   [OK]    %s\n' "$*"; }
fallo()   { printf '   [FALLA] %s\n' "$*"; FALLAS=1; }

# verificar <descripcion> <obtenido> <esperado>
verificar() {
    if [ "$2" = "$3" ]; then ok "$1: $2"; else fallo "$1: se obtuvo '$2' y se esperaba '$3'"; fi
}

cierre() {
    if [ "$FALLAS" -eq 0 ]; then
        printf '\n  RESULTADO: todas las verificaciones pasaron.\n\n'
    else
        printf '\n  RESULTADO: hubo verificaciones fallidas.\n\n'
    fi
    return "$FALLAS"
}

# --- utilidades --------------------------------------------------------------

# Muestra el comando curl en pantalla y lo ejecuta. Lo que se ve es exactamente
# lo que se manda, asi que sirve para copiar y pegar. El comando va a stderr
# para no mezclarse con la respuesta cuando se captura con $(...).
#
#   curl_json POST "$INGRESO/paquetes" "$PAQUETE_10KG"
#   curl_json GET  "$ADMISION/cintas/C1"
curl_json() {
    local metodo="$1" url="$2" cuerpo="${3:-}"
    {
        printf '\n   $ curl -X %s %s' "$metodo" "$url"
        if [ -n "$cuerpo" ]; then
            printf " \\\\\n        -H 'Content-Type: application/json' \\\\\n        -d '%s'" "$cuerpo"
        fi
        printf '\n\n'
    } >&2

    if [ -n "$cuerpo" ]; then
        curl -s -X "$metodo" "$url" -H 'Content-Type: application/json' -d "$cuerpo"
    else
        curl -s -X "$metodo" "$url"
    fi
}

dc() { ( cd "$RAIZ" && docker compose "$@" ); }

# El generador corre dentro de la red de Docker. --no-deps evita que compose
# cambie la cantidad de replicas de los otros servicios.
generador() { dc run --rm --no-deps generador "$@" 2>&1 | grep -vE '^ Container|^\[\+\]|^ Network'; }

# campo <json> <clave> -> valor sin comillas
campo() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\).*/\1/p" | head -1
}

estado_cinta()    { curl -s "$ADMISION/cintas/$CINTA"; }
estado_eventual() { curl -s "$ADMISION/demo/cintas/$CINTA/eventual"; }
reiniciar_cinta() { curl -s -X POST "$ADMISION/demo/cintas/$CINTA/reiniciar" > /dev/null; }

mostrar_cinta() {
    local json; json="$(estado_cinta)"
    nota "cinta $(campo "$json" id): $(campo "$json" carga_kg) kg de $(campo "$json" capacidad_kg) kg, $(campo "$json" paquetes_en_transito) paquetes en transito"
}

requiere_sistema() {
    if ! curl -sf "$INGRESO/health" > /dev/null 2>&1 \
       || ! curl -sf "$ADMISION/health" > /dev/null 2>&1; then
        printf '\nERROR: el sistema no responde. Levantalo con:\n\n    docker compose up -d --build\n\n'
        exit 1
    fi
}

# Espera a que los dos servicios respondan despues de un cambio de replicas.
esperar() {
    for _ in $(seq 1 40); do
        if curl -sf "$INGRESO/health" > /dev/null 2>&1 \
           && curl -sf "$ADMISION/health" > /dev/null 2>&1; then
            sleep 2; return 0
        fi
        sleep 1
    done
    return 1
}
