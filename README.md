# TFU UT5 — Cinta transportadora con arquitectura dirigida por eventos

Sistema de admisión de paquetes a una cinta transportadora con capacidad
limitada. En la UT4 era una arquitectura basada en servicios con llamadas REST
sincrónicas; en la UT5 pasó a una **arquitectura dirigida por eventos con
topología broker** sobre RabbitMQ.

```
cliente ──REST──▶ ingreso ──paquete.recibido──▶ validacion ──paquete.validado──▶ admision ──▶ PostgreSQL
                     │                              │                               │        (cinta)
                     │                    paquete.rechazado (422)       paquete.admitido / rechazado
                     │                              ▼                               ▼
                     └──REST──▶ seguimiento ◀───────────────────────────────────────┘
                     └──SOAP──▶ admision (ConsultarCinta)                         PostgreSQL
                                                                                 (seguimiento)
```

## Componentes

| Servicio | Qué hace | Interfaz |
|---|---|---|
| `balanceador` | nginx. Reparte entre réplicas de ingreso y aplica throttling por IP | 8080 (público), 8081 (admision, para demos) |
| `ingreso` | Frontera: autentica (API Key), publica `paquete.recibido` y responde 202. Consulta la cinta por SOAP con Circuit Breaker y cache | REST |
| `validacion` | Aplica las reglas de cada tipo de paquete. Publica `paquete.validado` o `paquete.rechazado` | eventos |
| `procesador_cola` | Proceso de admision que reserva el cupo en una transacción ACID al recibir `paquete.validado`. Publica `paquete.admitido` o `paquete.rechazado` | eventos |
| `admision` | API de admision: `ConsultarCinta` por SOAP (`/soap`, `/soap?wsdl`) y egresos por REST | SOAP, REST |
| `seguimiento` | Vista del estado de cada solicitud, armada a partir de los eventos. Tiene su propia base | REST |
| `rabbitmq` | Broker. Exchange topic `cinta.eventos`; colas y bindings en `rabbitmq/definitions.json` | AMQP, 15672 (consola) |
| `db` | PostgreSQL con dos bases: `cinta` (admision) y `seguimiento` | — |
| `monitor` | Health Endpoint Monitoring de las APIs y de las colas | logs |

## Eventos

| Evento | Lo publica | Lo consumen |
|---|---|---|
| `paquete.recibido` | ingreso | validacion, seguimiento |
| `paquete.validado` | validacion | admision |
| `paquete.rechazado` | validacion (422), admision (404, 409, 410) | seguimiento |
| `paquete.admitido` | admision | seguimiento, ingreso (invalida su cache) |

Todos los eventos llevan el `solicitud_id` y la credencial interna en sus
cabeceras. Las colas son durables y tienen cola de fallidos.

## Requisitos

- Docker con Docker Compose v2.
- Para las demos: bash (en Windows, Git Bash) y curl.

## Levantar

```bash
docker compose up -d --build
```

Para empezar con las bases vacías:

```bash
docker compose down -v
docker compose up -d --build
```

Escalar réplicas:

```bash
docker compose up -d --scale ingreso=3 --scale validacion=2 --scale procesador_cola=2
```

## Uso

```bash
# Recibir un paquete: responde 202 con un solicitud_id
curl -X POST http://localhost:8080/paquetes \
     -H 'Content-Type: application/json' \
     -d '{"tipo_paquete":"normal","peso_kg":10,"alto_cm":50,"ancho_cm":50,"largo_cm":70}'

# Consultar la decisión: 202 mientras está pendiente, después admitida/rechazada/vencida
curl http://localhost:8080/solicitudes/<solicitud_id>

# Estado de la cinta (ingreso lo consulta a admision por SOAP)
curl http://localhost:8080/cintas/C1

# Contrato SOAP
curl 'http://localhost:8081/soap?wsdl'

# Seguir el monitor
docker compose logs -f monitor
```

Consola de RabbitMQ: http://localhost:15672 (usuario y clave `tfu`).

## Demostraciones

```bash
bash scripts/demo_todo.sh            # las de la UT5, con pausa entre una y otra
TODAS=1 bash scripts/demo_todo.sh    # suma las de la UT3 y la UT4
```

| Script | Muestra |
|---|---|
| `demo_flujo_eventos.sh` | Componentes, eventos y un paquete seguido por todos los procesadores |
| `demo_soap.sh` | Migración de REST a SOAP: WSDL, sobres, Fault y consumo desde ingreso |
| `demo_circuit_breaker.sh` | Circuit Breaker con admision colgada |
| `demo_entrega_garantizada.sh` | Caída del procesador en plena ráfaga y eventos duplicados |
| `demo_2_stateless.sh` … `demo_5_escalabilidad.sh` | UT3: sin estado, ACID, BASE, escalabilidad |
| `demo_health.sh`, `demo_throttling.sh`, `demo_cache_aside.sh`, `demo_queue_load_leveling.sh`, `demo_seguridad.sh` | Patrones de la UT4 en la arquitectura nueva |
| `simulador.sh` | La cinta funcionando en el tiempo |

## Configuración

Todo está en `.env`: límites por tipo de paquete, capacidad de la cinta,
throttling, cache, vigencia de las solicitudes, Circuit Breaker
(`TIMEOUT_SOAP_S`, `CIRCUITO_UMBRAL_FALLOS`, `CIRCUITO_APERTURA_S`) y
consumidores por proceso.

## Estructura

```
admision/      API (SOAP y egresos) y procesador de eventos de admision
ingreso/       frontera REST, publicación de eventos, cliente SOAP y Circuit Breaker
validacion/    procesador de eventos con las reglas de paquetes
seguimiento/   vista del estado de las solicitudes
rabbitmq/      topología de eventos y configuración del broker
db/            esquemas de las bases
monitor/       Health Endpoint Monitoring
carga/         generador de carga para las demos
nginx/         balanceador y throttling
scripts/       demostraciones
```
