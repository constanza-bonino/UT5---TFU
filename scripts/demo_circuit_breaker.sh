#!/usr/bin/env bash
#
# UT5 - Circuit Breaker. Falacias: "la red es confiable" y "la latencia es cero".
#
# ingreso consulta el estado de la cinta a admision por SOAP. Se congela
# admision con docker pause: el contenedor sigue en la red y acepta conexiones,
# pero no contesta, como un servicio colgado o una red que pierde paquetes.
#
#   1. con admision sana la consulta responde y el circuito esta cerrado
#   2. con admision colgada, las primeras consultas esperan el timeout y el
#      circuito se abre: las siguientes fallan en el acto, sin tocar la red
#   3. el ingreso de paquetes no depende de esta llamada y sigue funcionando
#   4. vuelve admision: pasada la apertura, una llamada de prueba cierra el circuito
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

UMBRAL="$(sed -n 's/^CIRCUITO_UMBRAL_FALLOS=//p' "$RAIZ/.env" | tr -d '\r')"
APERTURA="$(sed -n 's/^CIRCUITO_APERTURA_S=//p' "$RAIZ/.env" | tr -d '\r')"
TIMEOUT="$(sed -n 's/^TIMEOUT_SOAP_S=//p' "$RAIZ/.env" | tr -d '\r')"

circuito() { curl -s "$INGRESO/circuito/admision"; }

# consultar -> "<codigo> <ms>" de GET /cintas/{id}, siempre sin cache
consultar() {
    curl -s -X POST "$INGRESO/cintas/$CINTA/cache/invalidar" > /dev/null
    curl -s -o /tmp/cb.json -w '%{http_code} %{time_total}' "$INGRESO/cintas/$CINTA" \
        | awk '{ printf "%s %d", $1, $2 * 1000 }'
}

# mostrar_consulta <n> -> imprime la linea y deja CODIGO y MS
mostrar_consulta() {
    read -r CODIGO MS <<< "$(consultar)"
    printf '   consulta %-2s  HTTP %s  %6s ms   circuito %s\n' \
        "$1" "$CODIGO" "$MS" "$(campo "$(circuito)" estado)"
}

restaurar() { dc unpause admision > /dev/null 2>&1; }
trap restaurar EXIT

titulo "UT5 - CIRCUIT BREAKER"
requiere_sistema
nota "timeout SOAP: $TIMEOUT s   umbral: $UMBRAL fallos seguidos   apertura: $APERTURA s"

# --- 1 ------------------------------------------------------------------------
seccion "1. admision sana"
mostrar_consulta 1
verificar "consulta" "$CODIGO" "200"
verificar "circuito" "$(campo "$(circuito)" estado)" "cerrado"

# --- 2 ------------------------------------------------------------------------
seccion "2. admision colgada"
paso "docker compose pause admision"
dc pause admision > /dev/null 2>&1
DESDE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
nota "Sin el circuito, cada consulta esperaria $TIMEOUT s para terminar en error."
printf '\n'
for i in $(seq 1 $(( UMBRAL + 3 ))); do
    mostrar_consulta "$i"
    [ "$i" -eq 1 ] && PRIMERA_MS="$MS"
done
ULTIMA_MS="$MS"
nota ""
nota "Respuesta con el circuito abierto: $(cat /tmp/cb.json)"
verificar "circuito" "$(campo "$(circuito)" estado)" "abierto"
verificar "la primera consulta espero el timeout" "$([ "$PRIMERA_MS" -ge 1500 ] && echo si || echo no)" "si"
verificar "con el circuito abierto falla en menos de 100 ms" "$([ "$ULTIMA_MS" -lt 100 ] && echo si || echo no)" "si"

# --- 3 ------------------------------------------------------------------------
seccion "3. el ingreso de paquetes sigue funcionando"
nota "Recibir un paquete es publicar un evento: no llama a admision."
CODIGO="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$INGRESO/paquetes" \
    -H 'Content-Type: application/json' -d "$PAQUETE_10KG")"
verificar "POST /paquetes con admision colgada" "$CODIGO" "202"

# --- 4 ------------------------------------------------------------------------
seccion "4. admision vuelve"
paso "docker compose unpause admision"
restaurar
ESPERA="$(campo "$(circuito)" segundos_para_reintentar)"
nota "El circuito sigue abierto $ESPERA s mas; mientras tanto no se llama a admision."
mostrar_consulta "-"
sleep "$(awk -v s="$ESPERA" 'BEGIN { printf "%.0f", s + 1 }')"
nota "Termino la apertura: la proxima consulta es la llamada de prueba."
mostrar_consulta "-"
verificar "la llamada de prueba responde" "$CODIGO" "200"
verificar "circuito" "$(campo "$(circuito)" estado)" "cerrado"

paso "Transiciones registradas por ingreso"
dc logs ingreso --since "$DESDE" 2>/dev/null | grep 'circuito admision-soap' | sed 's/^/   /'

rm -f /tmp/cb.json
cierre
