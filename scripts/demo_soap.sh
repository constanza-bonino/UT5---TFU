#!/usr/bin/env bash
#
# UT5 - Migracion de REST a SOAP.
#
# La consulta del estado de una cinta era GET /cintas/{id} en admision, con
# JSON. Ahora es la operacion ConsultarCinta de IAdmisionCinta, con mensajes
# XML y contrato WSDL, y la consume ingreso con un cliente SOAP (zeep).
#
#   1. el contrato WSDL
#   2. una invocacion SOAP: el sobre que se manda y el que vuelve
#   3. un SOAP Fault cuando la cinta no existe
#   4. ingreso consume el servicio SOAP y conserva su API para los clientes
#   5. el endpoint REST de admision ya no existe
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comun.sh"

NS="http://tfu.ucu.edu.uy/cinta/admision"

# sobre <cinta_id> -> sobre SOAP 1.1 de ConsultarCinta
sobre() {
    printf '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:adm="%s"><soapenv:Body><adm:ConsultarCinta><adm:cinta_id>%s</adm:cinta_id></adm:ConsultarCinta></soapenv:Body></soapenv:Envelope>' "$NS" "$1"
}

# Una etiqueta por linea, para poder leer el XML en pantalla.
legible() { sed 's/></>\n</g' | sed 's/^/      /'; }

# xml_campo <xml> <etiqueta> -> contenido de la primera <adm:etiqueta>
xml_campo() { printf '%s' "$1" | sed -n "s/.*<adm:$2>\([^<]*\)<\/adm:$2>.*/\1/p" | head -1; }

titulo "UT5 - MIGRACION DE REST A SOAP"
requiere_sistema

# --- 1 ------------------------------------------------------------------------
seccion "1. El contrato"
paso "GET $ADMISION/soap?wsdl"
WSDL="$(curl -s "$ADMISION/soap?wsdl")"
printf '%s\n' "$WSDL" | grep -E 'portType name|operation name=|soap:address|element name="(ConsultarCinta|CintaInexistente)"' | sort -u | sed 's/^ */      /'
verificar "el WSDL declara la operacion" "$(printf '%s' "$WSDL" | grep -c 'wsdl:operation name="ConsultarCinta"')" "2"

# --- 2 ------------------------------------------------------------------------
seccion "2. Invocacion SOAP"
nota "Es lo que haria cualquier cliente SOAP: POST /soap con un sobre XML."
paso "Sobre enviado"
sobre C1 | legible
RESPUESTA="$(curl -s -w '\n%{http_code}' -X POST "$ADMISION/soap" \
    -H 'Content-Type: text/xml; charset=utf-8' \
    -H "SOAPAction: \"$NS/ConsultarCinta\"" -d "$(sobre C1)")"
CODIGO="$(printf '%s' "$RESPUESTA" | tail -1)"
XML="$(printf '%s' "$RESPUESTA" | sed '$d')"
paso "Sobre recibido (HTTP $CODIGO)"
printf '%s\n' "$XML" | legible
verificar "codigo HTTP" "$CODIGO" "200"
CARGA_SOAP="$(xml_campo "$XML" carga_kg)"

# --- 3 ------------------------------------------------------------------------
seccion "3. SOAP Fault"
nota "Una cinta inexistente no es un 404: es un Fault con el detalle tipado"
nota "CintaInexistente que declara el WSDL. SOAP 1.1 los manda con HTTP 500."
RESPUESTA="$(curl -s -w '\n%{http_code}' -X POST "$ADMISION/soap" \
    -H 'Content-Type: text/xml; charset=utf-8' -d "$(sobre ZZ)")"
CODIGO="$(printf '%s' "$RESPUESTA" | tail -1)"
XML="$(printf '%s' "$RESPUESTA" | sed '$d')"
printf '%s\n' "$XML" | legible
verificar "codigo HTTP" "$CODIGO" "500"
verificar "detalle del Fault" "$(printf '%s' "$XML" | grep -c '<adm:CintaInexistente>')" "1"

# --- 4 ------------------------------------------------------------------------
seccion "4. Otro componente consume el servicio SOAP"
nota "El cliente externo sigue pidiendo GET /cintas/{id} a ingreso, con JSON."
nota "Por detras, ingreso invoca ConsultarCinta con zeep, que lee el WSDL y"
nota "valida la respuesta contra su esquema."
curl -s -X POST "$INGRESO/cintas/$CINTA/cache/invalidar" > /dev/null
DESDE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
paso "GET $INGRESO/cintas/$CINTA"
CABECERAS="$(curl -s -D - -o /tmp/soap_ingreso.json "$INGRESO/cintas/$CINTA")"
printf '%s\n' "$CABECERAS" | grep -iE '^x-(cache|origen)' | sed 's/^/      /'
nota "$(cat /tmp/soap_ingreso.json)"
sleep 1
paso "Log de admision: la llamada que hizo ingreso"
dc logs admision --since "$DESDE" 2>/dev/null | grep 'POST /soap' | tail -1 | sed 's/^/      /'
verificar "ingreso consulto por SOAP" "$(printf '%s' "$CABECERAS" | grep -ci '^x-origen: admision-soap')" "1"
verificar "misma carga que la respuesta SOAP" "$(campo "$(cat /tmp/soap_ingreso.json)" carga_kg)" "$CARGA_SOAP"

CODIGO="$(curl -s -o /dev/null -w '%{http_code}' "$INGRESO/cintas/ZZ")"
verificar "el Fault CintaInexistente llega al cliente como 404" "$CODIGO" "404"

# --- 5 ------------------------------------------------------------------------
seccion "5. El endpoint REST se retiro"
CODIGO="$(curl -s -o /dev/null -w '%{http_code}' "$ADMISION/cintas/$CINTA")"
verificar "GET /cintas/{id} en admision" "$CODIGO" "404"

rm -f /tmp/soap_ingreso.json
cierre
