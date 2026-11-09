#!/usr/bin/env bash
#
# ACID. Verifica las cuatro propiedades por separado.
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

titulo "DEMOSTRACION 3 — ACID"
requiere_sistema

nota "La transaccion que ejecuta admision al recibir paquete.validado:"
nota ""
nota "    BEGIN"
nota "      SELECT ... FOR UPDATE"
nota "      verificar cupo"
nota "      INSERT paquete_en_transito"
nota "      UPDATE cinta.carga_kg"
nota "    COMMIT"
nota ""
nota "UT5: el resto del sistema es eventualmente consistente (el cliente se entera"
nota "despues), pero la decision sobre el cupo sigue siendo esta unica transaccion."

seccion "3.1  ATOMICIDAD"
reiniciar_cinta
paso "Admito 30 kg por el camino normal"
procesar_paquete '{"tipo_paquete":"normal","peso_kg":30,"alto_cm":50,"ancho_cm":50,"largo_cm":70}' > /dev/null
mostrar_cinta

paso "La misma transaccion, fallando entre las escrituras y el COMMIT"
RESP="$(curl_json POST "$ADMISION/demo/cintas/$CINTA/admision-con-fallo" \
        '{"tipo_paquete":"normal","peso_kg":25}')"
nota "$RESP"

printf '\n'
verificar "se revirtio entera" "$(campo "$RESP" sin_cambios)" "true"
verificar "carga sin cambios" "$(campo "$(estado_cinta)" carga_kg)" "30.0"
verificar "paquetes sin cambios" "$(campo "$(estado_cinta)" paquetes_en_transito)" "1"

seccion "3.2  CONSISTENCIA"
nota "El invariante esta en la tabla:"
nota ""
nota "    CONSTRAINT cupo_no_excedido"
nota "        CHECK (carga_kg >= 0 AND carga_kg <= capacidad_kg)"
nota ""
nota "Escribo directo en la tabla, salteando el servicio."

paso "Forzar 500 kg en una cinta de 100"
RESP="$(curl_json POST "$ADMISION/demo/cintas/$CINTA/forzar-carga" '{"carga_kg":500}')"
nota "$(campo "$RESP" resultado) — restriccion: $(campo "$RESP" restriccion)"
verificar "rechazado" "$(campo "$RESP" resultado)" "rechazado por la base de datos"

paso "Forzar carga negativa"
RESP="$(curl_json POST "$ADMISION/demo/cintas/$CINTA/forzar-carga" '{"carga_kg":-5}')"
nota "$(campo "$RESP" resultado)"
verificar "rechazado" "$(campo "$RESP" resultado)" "rechazado por la base de datos"
verificar "la cinta quedo intacta" "$(campo "$(estado_cinta)" carga_kg)" "30.0"

seccion "3.3  AISLAMIENTO"
reiniciar_cinta
nota "Cinta de 100 kg vacia, 50 solicitudes simultaneas de 10 kg. Caben 10."
printf '\n'
mostrar_cinta

paso "Lanzando las 50 y esperando que se decidan todas"
# Puerto 82: entrada interna sin throttling (UT4).
generador cola --n 50 --c 50 --url http://balanceador:82/paquetes \
    --estado-url http://balanceador:82/solicitudes --cuerpo "$PAQUETE_10KG"
nota ""
nota "Con 8 consumidores por replica de procesador_cola, varias transacciones"
nota "compiten por la misma fila: SELECT ... FOR UPDATE las pone en fila."

ESTADO="$(estado_cinta)"
printf '\n'
nota "$ESTADO"
printf '\n'
verificar "paquetes admitidos" "$(campo "$ESTADO" paquetes_en_transito)" "10"
verificar "carga final" "$(campo "$ESTADO" carga_kg)" "100.0"
verificar "capacidad remanente" "$(campo "$ESTADO" disponible_kg)" "0.0"

seccion "3.4  DURABILIDAD"
CARGA_ANTES="$(campo "$(estado_cinta)" carga_kg)"
PAQ_ANTES="$(campo "$(estado_cinta)" paquetes_en_transito)"

paso "docker compose restart db"
dc restart db > /dev/null 2>&1
esperar || fallo "la base no volvio a tiempo"
for _ in $(seq 1 30); do
    [ -n "$(campo "$(estado_cinta)" carga_kg)" ] && break
    sleep 1
done
mostrar_cinta

verificar "la carga sobrevivio" "$(campo "$(estado_cinta)" carga_kg)" "$CARGA_ANTES"
verificar "los paquetes sobrevivieron" "$(campo "$(estado_cinta)" paquetes_en_transito)" "$PAQ_ANTES"

cierre
