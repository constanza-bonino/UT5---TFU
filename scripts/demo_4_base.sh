#!/usr/bin/env bash
#
# Contrafactico: el mismo experimento de la 3.3 con y sin transaccion.
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

titulo "DEMOSTRACION 4 — CONTRAFACTICO BASE"
requiere_sistema

nota "El camino sin transaccion lee, decide fuera de toda transaccion y despues"
nota "escribe. Sin bloqueo de fila y sin restriccion CHECK, que es como se"
nota "comportaria un almacen eventualmente consistente."

seccion "4.1  Con transaccion"
reiniciar_cinta
mostrar_cinta
paso "50 solicitudes simultaneas de 10 kg"
# Puerto 82: entrada interna sin throttling (UT4).
generador rafaga --n 50 --url http://balanceador:82/paquetes --cuerpo "$PAQUETE_10KG"

ACID="$(estado_cinta)"
ACID_PAQ="$(campo "$ACID" paquetes_en_transito)"
ACID_CARGA="$(campo "$ACID" carga_kg)"

seccion "4.2  Sin transaccion"
reiniciar_cinta
paso "Lo mismo, contra el endpoint sin transaccion"
generador rafaga --n 50 \
    --url "http://balanceador:81/demo/cintas/$CINTA/admision-sin-transaccion" \
    --cuerpo '{"tipo_paquete":"normal","peso_kg":10}'

EVENTUAL="$(estado_eventual)"
printf '\n'
nota "$EVENTUAL"
BASE_ADMITIDOS="$(campo "$EVENTUAL" paquetes_admitidos)"
BASE_CREE="$(campo "$EVENTUAL" carga_kg_segun_el_sistema)"
BASE_REAL="$(campo "$EVENTUAL" peso_kg_realmente_sobre_la_cinta)"
BASE_SOBRE="$(campo "$EVENTUAL" sobrecarga_kg)"

seccion "4.3  Comparacion"
printf '\n'
printf '   %-34s %14s %14s\n' "" "CON transaccion" "SIN transaccion"
printf '   %-34s %14s %14s\n' "----------------------------------" "--------------" "--------------"
printf '   %-34s %14s %14s\n' "paquetes admitidos"       "$ACID_PAQ"   "$BASE_ADMITIDOS"
printf '   %-34s %14s %14s\n' "carga que el sistema cree" "$ACID_CARGA" "$BASE_CREE"
printf '   %-34s %14s %14s\n' "peso REAL sobre la cinta"  "$ACID_CARGA" "$BASE_REAL"
printf '   %-34s %14s %14s\n' "capacidad de la cinta"     "100.0"       "100.0"
printf '   %-34s %14s %14s\n' "sobrecarga"                "0.0"         "$BASE_SOBRE"

printf '\n'
verificar "con transaccion la cinta queda en su capacidad" "$ACID_CARGA" "100.0"

if awk -v real="$BASE_REAL" 'BEGIN { exit !(real > 100) }'; then
    ok "sin transaccion quedo sobrecargada ($BASE_REAL kg sobre 100.0 kg)"
else
    fallo "se esperaba sobrecarga y no la hubo"
fi

if [ "$BASE_CREE" != "$BASE_REAL" ]; then
    ok "el contador miente: dice $BASE_CREE kg y hay $BASE_REAL kg"
else
    nota "en esta corrida el contador coincidio"
fi

nota ""
nota "El RNF-01 de la UT2 exigia que ninguna solicitud rechazada produjera, por"
nota "ningun camino, la respuesta de admision. Con consistencia eventual eso no"
nota "se puede cumplir: la ventana entre lectura y escritura es parte del modelo."
nota ""
nota "Donde si convendria BASE: un tablero de metricas o un historial de"
nota "paquetes procesados."

cierre
