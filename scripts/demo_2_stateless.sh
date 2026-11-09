#!/usr/bin/env bash
#
# Servicios sin estado.
#
#   1. una secuencia se reparte entre replicas y el total es el mismo
#   2. matar una replica en el medio no pierde nada
#   3. una replica nueva sirve desde la primera solicitud
#
# UT5: ademas de ingreso se replican los procesadores de eventos. Las replicas
# de validacion y de procesador_cola compiten por la misma cola: RabbitMQ le
# da cada evento a una sola.
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

titulo "DEMOSTRACION 2 — SERVICIOS SIN ESTADO"
requiere_sistema

paso "Escalando: 3 ingreso, 2 admision, 2 validacion, 2 procesador_cola"
dc up -d --scale ingreso=3 --scale admision=2 --scale validacion=2 --scale procesador_cola=2 > /dev/null 2>&1
esperar || { fallo "el sistema no volvio a responder"; exit 1; }
reiniciar_cinta

# un_paquete <n>: lo envia, espera el resultado y muestra que replicas lo atendieron
un_paquete() {
    local r id final
    r="$(curl -s -X POST "$INGRESO/paquetes" -H 'Content-Type: application/json' -d "$PAQUETE_10KG")"
    id="$(campo "$r" solicitud_id)"
    final="$(esperar_resultado "$id")"
    printf '   solicitud %d  ->  ingreso=%s  procesador=%s  %s  carga=%s kg\n' \
        "$1" "$(campo "$r" ingreso)" "$(campo "$final" instancia)" \
        "$(campo "$final" estado)" "$(campo "$final" carga_kg)"
    echo "$(campo "$r" ingreso)" >> /tmp/instancias.txt
}

seccion "2.1  Una secuencia repartida entre replicas distintas"
nota "6 paquetes de 10 kg, uno por uno. Cada uno puede caer en una replica"
nota "distinta, pero el total tiene que dar 60 kg igual."
printf '\n'

: > /tmp/instancias.txt
for i in $(seq 1 6); do un_paquete "$i"; done

printf '\n'
nota "replicas de ingreso que participaron: $(sort -u /tmp/instancias.txt | wc -l | tr -d ' ')"
verificar "carga total" "$(campo "$(estado_cinta)" carga_kg)" "60.0"

seccion "2.2  Matar una replica en medio de la secuencia"
VICTIMA="$(dc ps --format '{{.Name}}' | grep -- '-ingreso-' | head -1)"
paso "docker stop $VICTIMA"
docker stop "$VICTIMA" > /dev/null
sleep 3

paso "Sigo con 3 paquetes mas"
for i in $(seq 7 9); do un_paquete "$i"; done

printf '\n'
verificar "carga total tras 9 paquetes" "$(campo "$(estado_cinta)" carga_kg)" "90.0"
verificar "paquetes en transito" "$(campo "$(estado_cinta)" paquetes_en_transito)" "9"
nota "No se perdio ninguna admision: lo decidido ya estaba en la base."

seccion "2.3  Una replica nueva sirve enseguida"
paso "docker start $VICTIMA"
docker start "$VICTIMA" > /dev/null
esperar || nota "(todavia iniciando)"
sleep 3

VISTA="$(estado_cinta)"
nota "$VISTA"
verificar "ve la misma carga, sin sincronizar nada" "$(campo "$VISTA" carga_kg)" "90.0"

paso "El balanceador vuelve a usar las 3"
: > /tmp/instancias.txt
for _ in $(seq 1 12); do
    echo "$(campo "$(curl -s "$INGRESO/health")" instancia)" >> /tmp/instancias.txt
done
sort /tmp/instancias.txt | uniq -c | while read -r n inst; do nota "$inst  ->  $n"; done

paso "Los procesadores replicados comparten su cola"
for cola in validacion.recibidos admision.validados; do
    nota "$cola: $(campo "$(cola_info "$cola")" consumers) consumidores (8 hilos por replica)"
done

rm -f /tmp/instancias.txt
cierre
