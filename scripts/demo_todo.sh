#!/usr/bin/env bash
#
# Corre las  demostraciones en orden y muestra un resumen al final.
#
#   bash scripts/demo_todo.sh            para entre una y otra, esperando Enter
#   PAUSA=0 bash scripts/demo_todo.sh    las corre todas seguidas, sin parar
#
# La pausa sirve para la defensa: se corre una demo, se explica lo que salió en
# pantalla, y recién ahí se pasa a la siguiente.
#
set -uo pipefail
DIRECTORIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIRECTORIO/comun.sh"

# Por defecto pausa solo si la terminal es interactiva, para que siga sirviendo
# cuando se corre de forma automatica.
PAUSA="${PAUSA:-auto}"
if [ "$PAUSA" = "auto" ]; then
    if [ -t 0 ] && [ -e /dev/tty ]; then PAUSA=1; else PAUSA=0; fi
fi

DEMOS=(
    "demo_health.sh|Health Endpoint Monitoring (disponibilidad)"
    "demo_throttling.sh|Throttling (disponibilidad)"
    "demo_cache_aside.sh|Cache-Aside (rendimiento)"
    "demo_queue_load_leveling.sh|Queue Based Load Leveling (rendimiento)"
    "demo_seguridad.sh|Gatekeeper y Gateway Offloading (seguridad)"
)

titulo "TFU UT4: DEMOSTRACION COMPLETA"
requiere_sistema

nota "Se van a correr estas demostraciones:"

printf '\n'
for i in "${!DEMOS[@]}"; do
    printf '     %d. %s\n' "$(( i + 1 ))" "${DEMOS[$i]##*|}"
done

# Espera un Enter antes de la siguiente demo.
pausar() {
    [ "$PAUSA" = "1" ] || return 0
    printf '\n'
    printf '   ┌────────────────────────────────────────────────────────┐\n'
    printf '   │  Siguiente:  [%d/%d]  %-35s│\n' "$1" "${#DEMOS[@]}" "$2"
    printf '   └────────────────────────────────────────────────────────┘\n'
    printf '   Enter para correrla   (Ctrl+C para cortar) '
    read -r _ < /dev/tty
}

RESUMEN=()
NUMERO=0
for entrada in "${DEMOS[@]}"; do
    archivo="${entrada%%|*}"
    nombre="${entrada##*|}"
    NUMERO=$(( NUMERO + 1 ))

    pausar "$NUMERO" "$nombre"

    if bash "$DIRECTORIO/$archivo"; then
        RESUMEN+=("OK     $nombre")
    else
        RESUMEN+=("FALLA  $nombre")
    fi
done

if [ "$PAUSA" = "1" ]; then
    printf '\n   Enter para ver el resumen '
    read -r _ < /dev/tty
fi

titulo "RESUMEN"
for linea in "${RESUMEN[@]}"; do
    printf '   %s\n' "$linea"
done
printf '\n'

if printf '%s\n' "${RESUMEN[@]}" | grep -q '^FALLA'; then
    exit 1
fi
exit 0
