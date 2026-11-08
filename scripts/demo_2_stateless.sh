#!/usr/bin/env bash
#
# Servicios sin estado.
#
#   1. una secuencia se reparte entre replicas y el total es el mismo
#   2. matar una replica en el medio no pierde nada
#   3. una replica nueva sirve desde la primera solicitud
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

titulo "DEMOSTRACION 2 — SERVICIOS SIN ESTADO"
requiere_sistema

paso "Escalando a 3 replicas de ingreso"
dc up -d --scale ingreso=3 --scale admision=2 > /dev/null 2>&1
esperar || { fallo "el sistema no volvio a responder"; exit 1; }
reiniciar_cinta

seccion "2.1  Una secuencia repartida entre replicas distintas"
nota "6 paquetes de 10 kg, uno por uno. Cada uno puede caer en una replica"
nota "distinta, pero el total tiene que dar 60 kg igual."
printf '\n'

: > /tmp/instancias.txt
for i in $(seq 1 6); do
    R="$(curl -s -X POST "$INGRESO/paquetes" -H 'Content-Type: application/json' -d "$PAQUETE_10KG")"
    ING="$(campo "$R" ingreso)"
    printf '   solicitud %d  ->  ingreso=%s  admision=%s  carga=%s kg\n' \
        "$i" "$ING" "$(campo "$R" admision)" "$(campo "$R" carga_kg)"
    echo "$ING" >> /tmp/instancias.txt
done

printf '\n'
nota "replicas que participaron: $(sort -u /tmp/instancias.txt | wc -l | tr -d ' ')"
verificar "carga total" "$(campo "$(estado_cinta)" carga_kg)" "60.0"

seccion "2.2  Matar una replica en medio de la secuencia"
VICTIMA="$(dc ps --format '{{.Name}}' | grep '^tfu-ut3-ingreso-' | head -1)"
paso "docker stop $VICTIMA"
docker stop "$VICTIMA" > /dev/null
sleep 3

paso "Sigo con 3 paquetes mas"
for i in $(seq 7 9); do
    R="$(curl -s -X POST "$INGRESO/paquetes" -H 'Content-Type: application/json' -d "$PAQUETE_10KG")"
    printf '   solicitud %d  ->  ingreso=%s  carga=%s kg\n' \
        "$i" "$(campo "$R" ingreso)" "$(campo "$R" carga_kg)"
done

printf '\n'
verificar "carga total tras 9 paquetes" "$(campo "$(estado_cinta)" carga_kg)" "90.0"
verificar "paquetes en transito" "$(campo "$(estado_cinta)" paquetes_en_transito)" "9"
nota "No se perdio ninguna admision: lo confirmado ya estaba en la base."

seccion "2.3  Una replica nueva sirve enseguida"
paso "docker start $VICTIMA"
docker start "$VICTIMA" > /dev/null
esperar || nota "(todavia iniciando)"
sleep 3

VISTA="$(curl -s "$INGRESO/cintas/$CINTA")"
nota "$VISTA"
verificar "ve la misma carga, sin sincronizar nada" "$(campo "$VISTA" carga_kg)" "90.0"

paso "El balanceador vuelve a usar las 3"
: > /tmp/instancias.txt
for _ in $(seq 1 12); do
    campo "$(curl -s "$INGRESO/health")" instancia >> /tmp/instancias.txt
done
sort /tmp/instancias.txt | uniq -c | while read -r n inst; do nota "$inst  ->  $n"; done

rm -f /tmp/instancias.txt
cierre
