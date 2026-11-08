"""
Interfaz IRepositorioCinta y su implementacion sobre PostgreSQL.

Es la misma idea que IReglaValidacion en la UT2: una abstraccion delante de una
implementacion concreta, para que el servicio de admision no dependa de
SQLAlchemy ni de PostgreSQL directamente.
"""

import uuid
from abc import ABC, abstractmethod
from decimal import Decimal

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from app.modelos import Cinta, CintaEventual, PaqueteEnTransito


class IRepositorioCinta(ABC):
    """Contrato de persistencia que necesita el componente de admision."""

    @abstractmethod
    def obtener_para_actualizar(self, sesion: Session, cinta_id: str):
        """Devuelve la cinta con bloqueo exclusivo de fila, o None si no existe."""

    @abstractmethod
    def obtener(self, sesion: Session, cinta_id: str):
        """Devuelve la cinta sin bloquear, para consultas de solo lectura."""

    @abstractmethod
    def registrar_admision(self, sesion, cinta, tipo_paquete, peso_kg):
        """Registra el paquete y suma su peso a la carga de la cinta."""

    @abstractmethod
    def registrar_egreso(self, sesion, cinta, paquete_id):
        """Saca el paquete de la cinta y libera su peso."""


class RepositorioCintaSQL(IRepositorioCinta):

    def obtener_para_actualizar(self, sesion, cinta_id):
        # SELECT ... FOR UPDATE serializa a los que compiten por esta misma
        # cinta. Es lo que garantiza el aislamiento y evita la actualizacion
        # perdida sobre carga_kg.
        return sesion.scalar(
            select(Cinta).where(Cinta.id == cinta_id).with_for_update())

    def obtener(self, sesion, cinta_id):
        return sesion.scalar(select(Cinta).where(Cinta.id == cinta_id))

    def registrar_admision(self, sesion, cinta, tipo_paquete, peso_kg):
        paquete = PaqueteEnTransito(
            id=uuid.uuid4(), cinta_id=cinta.id,
            tipo_paquete=tipo_paquete, peso_kg=peso_kg)
        sesion.add(paquete)
        cinta.carga_kg = cinta.carga_kg + peso_kg
        return paquete.id

    def registrar_egreso(self, sesion, cinta, paquete_id):
        paquete = sesion.scalar(
            select(PaqueteEnTransito).where(
                PaqueteEnTransito.id == paquete_id,
                PaqueteEnTransito.cinta_id == cinta.id))
        if paquete is None:
            return None

        peso = paquete.peso_kg
        sesion.delete(paquete)
        cinta.carga_kg = cinta.carga_kg - peso
        return peso

    # --- Operaciones para las demostraciones. No son parte de la interfaz. ---

    def reiniciar(self, sesion, cinta_id, capacidad_kg):
        """Vacia la cinta y vuelve a aplicar la capacidad configurada."""
        sesion.execute(
            delete(PaqueteEnTransito).where(PaqueteEnTransito.cinta_id == cinta_id))
        sesion.execute(
            update(Cinta).where(Cinta.id == cinta_id)
            .values(carga_kg=Decimal("0"), capacidad_kg=capacidad_kg))
        sesion.execute(
            update(CintaEventual).where(CintaEventual.id == cinta_id)
            .values(carga_kg=Decimal("0"), peso_admitido_kg=Decimal("0"),
                    admitidos=0, capacidad_kg=capacidad_kg))

    def leer_eventual(self, sesion, cinta_id):
        """Lectura sin bloqueo del almacen que emula BASE."""
        return sesion.execute(
            select(CintaEventual.carga_kg, CintaEventual.capacidad_kg,
                   CintaEventual.peso_admitido_kg, CintaEventual.admitidos)
            .where(CintaEventual.id == cinta_id)).first()

    def escribir_eventual(self, sesion, cinta_id, carga_kg, peso_kg):
        """
        Escritura del camino sin transaccion.

        carga_kg se pisa con el valor calculado a partir de una lectura vieja:
        es el ciclo leer-modificar-escribir que pierde actualizaciones. En
        cambio peso_admitido_kg y admitidos se suman de forma atomica, asi que
        registran bien lo que realmente entro. La diferencia entre los dos
        valores es la evidencia del problema.
        """
        sesion.execute(
            update(CintaEventual).where(CintaEventual.id == cinta_id)
            .values(carga_kg=carga_kg,
                    peso_admitido_kg=CintaEventual.peso_admitido_kg + peso_kg,
                    admitidos=CintaEventual.admitidos + 1))
