#!/usr/bin/env bash
#
# UT4 - Health Endpoint Monitoring (disponibilidad).
#   1. sondas /health/live y /health/ready
#   2. el monitor detecta la caida y la vuelta de la base y de una replica
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

titulo "UT4 — HEALTH ENDPOINT MONITORING"
requiere_sistema

# Lineas del monitor desde un momento dado (UTC, formato de docker logs).
monitor_desde() { dc logs --no-log-prefix --since "$1" monitor 2>/dev/null | sed 's/^/      /'; }

# Segundos entre dos horas HH:MM:SS.mmm del mismo dia.
segundos_entre() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, ":"); split(b, y, ":")
        printf "%.1f", (y[1]*3600 + y[2]*60 + y[3]) - (x[1]*3600 + x[2]*60 + x[3])
    }'
}

codigo() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

# --- 1 ------------------------------------------------------------------------
seccion "H.1  Dos sondas distintas"
nota "/health/live   ¿el proceso responde?        No mira dependencias."
nota "/health/ready  ¿puede hacer su trabajo?     Verifica cada dependencia."
nota ""
nota "Docker usa live (si se cae la base, reiniciar el servicio no arregla"
nota "nada). El monitor usa ready."

paso "admision"
nota "live  -> $(curl -s "$ADMISION/health/live")"
nota "ready -> $(curl -s "$ADMISION/health/ready")"
paso "ingreso (su dependencia es admision)"
nota "live  -> $(curl -s "$INGRESO/health/live")"
nota "ready -> $(curl -s "$INGRESO/health/ready")"

verificar "admision ready" "$(codigo "$ADMISION/health/ready")" "200"
verificar "ingreso ready" "$(codigo "$INGRESO/health/ready")" "200"

# --- 2 ------------------------------------------------------------------------
seccion "H.2  El monitor externo"
nota "Contenedor aparte que cada 2 s consulta el /health/ready de CADA replica"
nota "(las descubre por el DNS de Docker) y escribe una linea solo cuando una"
nota "cambia de estado. Se puede seguir en vivo con:"
nota ""
nota "    docker compose logs -f monitor"
nota ""
nota "Estado actual:"
dc logs --no-log-prefix monitor 2>/dev/null | tail -8 | sed 's/^/      /'

# --- 3 ------------------------------------------------------------------------
seccion "H.3  Se cae la base"
DESDE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
T_CAIDA="$(date -u +%H:%M:%S.%3N)"
paso "docker compose stop db   (a las $T_CAIDA UTC)"
dc stop db > /dev/null 2>&1
sleep 5

paso "Lo que contestan las sondas"
nota "admision live  -> HTTP $(codigo "$ADMISION/health/live")"
nota "admision ready -> $(curl -s "$ADMISION/health/ready")"
nota "ingreso  ready -> $(curl -s "$INGRESO/health/ready")"

verificar "admision live sigue viva" "$(codigo "$ADMISION/health/live")" "200"
verificar "admision ready informa la falla" "$(codigo "$ADMISION/health/ready")" "503"
verificar "ingreso ready informa la falla" "$(codigo "$INGRESO/health/ready")" "503"

paso "Docker no los marca enfermos: el proceso esta bien, le falta la base"
dc ps --format '{{.Name}}\t{{.Status}}' | grep -E 'ingreso|admision' | sed 's/^/   /'

paso "Lo que registro el monitor"
monitor_desde "$DESDE"
T_DETECCION="$(dc logs --no-log-prefix --since "$DESDE" monitor 2>/dev/null \
               | grep -m1 -- '-> DEGRADADO' | cut -c1-12)"
if [ -n "$T_DETECCION" ]; then
    ok "falla detectada a los $(segundos_entre "$T_CAIDA" "$T_DETECCION") s de la caida"
else
    fallo "el monitor no registro la falla"
fi

# --- 4 ------------------------------------------------------------------------
seccion "H.4  Vuelve la base"
DESDE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
T_VUELTA="$(date -u +%H:%M:%S.%3N)"
paso "docker compose start db   (a las $T_VUELTA UTC)"
dc start db > /dev/null 2>&1
for _ in $(seq 1 30); do
    [ "$(codigo "$ADMISION/health/ready")" = "200" ] && break
    sleep 1
done
sleep 3

paso "Lo que registro el monitor"
monitor_desde "$DESDE"
verificar "admision ready" "$(codigo "$ADMISION/health/ready")" "200"
verificar "ingreso ready" "$(codigo "$INGRESO/health/ready")" "200"
nota "Nadie reinicio los servicios: se recuperaron solos cuando volvio la base."

# --- 5 ------------------------------------------------------------------------
seccion "H.5  Se detiene una replica"
VICTIMA="$(dc ps --format '{{.Name}}' | grep -- '-ingreso-' | head -1)"
if [ -z "$VICTIMA" ] || [ "$(dc ps --format '{{.Name}}' | grep -c -- '-ingreso-')" -lt 2 ]; then
    nota "(se necesitan al menos 2 replicas de ingreso; levantalo con --scale ingreso=3)"
else
    DESDE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    paso "docker stop $VICTIMA"
    docker stop "$VICTIMA" > /dev/null
    sleep 5
    verificar "la API publica sigue respondiendo" "$(codigo "$INGRESO/health/live")" "200"

    paso "docker start $VICTIMA"
    docker start "$VICTIMA" > /dev/null
    sleep 8

    paso "Lo que registro el monitor"
    monitor_desde "$DESDE"
    if dc logs --no-log-prefix --since "$DESDE" monitor 2>/dev/null | grep -q "$VICTIMA.*-> FUERA"; then
        ok "el monitor vio salir a $VICTIMA"
    else
        fallo "el monitor no registro la salida de $VICTIMA"
    fi
    if dc logs --no-log-prefix --since "$DESDE" monitor 2>/dev/null | grep -q "$VICTIMA.*FUERA -> OK"; then
        ok "y la vio volver"
    else
        fallo "el monitor no registro la vuelta de $VICTIMA"
    fi
fi

nota ""
nota "Limites (para el informe): Docker Compose marca un contenedor como"
nota "unhealthy pero no lo reinicia (Swarm o Kubernetes si), y nginx open source"
nota "no consulta estas sondas para sacar replicas del balanceo. El monitor"
nota "detecta e informa; actuar sobre eso le corresponderia al orquestador."

cierre
