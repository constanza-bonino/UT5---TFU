import os

from dotenv import load_dotenv

load_dotenv()

DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql+psycopg://seguimiento:seguimiento@db:5432/seguimiento"
)
DB_POOL_SIZE = int(float(os.getenv("DB_POOL_SIZE", 20)))
DB_POOL_TIMEOUT_S = int(float(os.getenv("DB_POOL_TIMEOUT_S", 30)))

RABBITMQ_URL = os.getenv("RABBITMQ_URL", "amqp://tfu:tfu@rabbitmq:5672/%2F")
EXCHANGE_EVENTOS = os.getenv("EXCHANGE_EVENTOS", "cinta.eventos")
COLA_RESULTADOS = os.getenv("COLA_RESULTADOS", "seguimiento.resultados")
COLA_CONSUMIDORES = int(float(os.getenv("COLA_CONSUMIDORES", 8)))
COLA_PREFETCH = int(float(os.getenv("COLA_PREFETCH", 1)))
CLAVE_INTERNA = os.getenv("CLAVE_INTERNA", "cinta-interna-dev")

# Una solicitud pendiente se informa como vencida recien cuando paso su
# vence_en mas este margen. admision compara vence_en al empezar la
# transaccion, y una transaccion puede tardar hasta el statement_timeout (20 s):
# con el margen, nunca se informa "vencida" algo que despues termina admitido.
MARGEN_VENCIDA_S = float(os.getenv("SEGUIMIENTO_MARGEN_VENCIDA_S", 30))
