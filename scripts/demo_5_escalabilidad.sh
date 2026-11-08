#!/usr/bin/env bash
#
# Escalabilidad horizontal.
#
# Se limita la CPU de cada replica con deploy.resources.limits.cpus. Sin acotar,
# en una sola laptop agregar replicas solo reparte la capacidad que ya habia.
#
#     A)  1 replica x 0.25 CPU   linea de base
#     B)  3 replicas x 0.25 CPU  HORIZONTAL  (0.75 en total)
#     C)  1 replica x 0.75 CPU   VERTICAL    (0.75 en total)
#
# Va por el puerto 82, sin throttling (UT4).
#
# La carga son solicitudes que la validacion rechaza: no llegan a la base, asi
# que se mide el componente que se escala y no el que se comparte.
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

titulo "DEMOSTRACION 5 — ESCALABILIDAD HORIZONTAL"
requiere_sistema

SOLICITUDES=900
CONCURRENCIA=60
RESULTADOS="$(mktemp)"

# medir <etiqueta> <cpus> <replicas>
medir() {
    paso "$1  —  $3 replica(s) con $2 CPU cada una"
    INGRESO_CPUS="$2" dc up -d --scale ingreso="$3" --scale admision=2 > /dev/null 2>&1
    esperar || { fallo "el sistema no volvio a responder"; return 1; }

    local salida
    salida="$(generador rendimiento --n "$SOLICITUDES" --c "$CONCURRENCIA" \
        --url http://balanceador:82/paquetes --cuerpo "$PAQUETE_INVALIDO")"
    printf '%s\n' "$salida"
    echo "$1|$(printf '%s' "$salida" | sed -n 's/.*throughput *: *\([0-9.]*\).*/\1/p')" >> "$RESULTADOS"
}

nota "cada medicion: $SOLICITUDES solicitudes con concurrencia $CONCURRENCIA"

seccion "5.1  Linea de base"
medir "base" 0.25 1

seccion "5.2  Horizontal"
medir "horizontal" 0.25 3

seccion "5.3  Vertical"
medir "vertical" 0.75 1

seccion "5.4  Comparacion"
BASE="$(grep '^base|' "$RESULTADOS" | cut -d'|' -f2)"
HORIZ="$(grep '^horizontal|' "$RESULTADOS" | cut -d'|' -f2)"
VERT="$(grep '^vertical|' "$RESULTADOS" | cut -d'|' -f2)"

printf '\n'
printf '   %-22s %9s %9s %11s %10s\n' "configuracion" "replicas" "CPU c/u" "CPU total" "sol/seg"
printf '   %-22s %9s %9s %11s %10s\n' "----------------------" "--------" "-------" "---------" "--------"
printf '   %-22s %9s %9s %11s %10s\n' "linea de base"     "1" "0.25" "0.25" "$BASE"
printf '   %-22s %9s %9s %11s %10s\n' "HORIZONTAL (x3)"   "3" "0.25" "0.75" "$HORIZ"
printf '   %-22s %9s %9s %11s %10s\n' "VERTICAL (x3 CPU)" "1" "0.75" "0.75" "$VERT"

printf '\n'
awk -v b="$BASE" -v h="$HORIZ" -v v="$VERT" 'BEGIN {
    if (b > 0) {
        printf "   horizontal: x%.2f sobre la linea de base\n", h/b
        printf "   vertical:   x%.2f sobre la linea de base\n", v/b
    }
}'

printf '\n'
if awk -v b="$BASE" -v h="$HORIZ" 'BEGIN { exit !(h > b * 1.5) }'; then
    ok "el escalado horizontal aumento la capacidad"
else
    fallo "el escalado horizontal no mostro la mejora esperada"
fi

nota ""
nota "Con la misma CPU total el vertical da parecido, incluso un poco mejor:"
nota "tres procesos pagan un costo extra que uno solo no paga. La razon para"
nota "elegir horizontal no es el throughput sino la disponibilidad, el techo y"
nota "la granularidad."
nota ""
nota "Limite: los dos servicios escalan, la base no se replica."

paso "Restaurando 3 replicas sin limite de CPU"
dc up -d --scale ingreso=3 --scale admision=2 > /dev/null 2>&1
esperar && nota "listo"

rm -f "$RESULTADOS"
cierre
