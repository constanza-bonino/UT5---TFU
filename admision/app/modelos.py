"""Modelo de datos del componente admision."""

import uuid
from decimal import Decimal

from sqlalchemy import (CheckConstraint, DateTime, ForeignKey, Integer,
                        Numeric, String, func, text)
from sqlalchemy.dialects.postgresql import JSONB, UUID as PGUUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class Cinta(Base):
    """
    Estado compartido de una cinta.

    La restriccion cupo_no_excedido es la C de ACID: el invariante del dominio
    vive en el esquema y no solo en el codigo, asi que ninguna transaccion puede
    confirmarse dejando la cinta sobrecargada.
    """

    __tablename__ = "cinta"

    id: Mapped[str] = mapped_column(String, primary_key=True)
    capacidad_kg: Mapped[Decimal] = mapped_column(Numeric(10, 2), nullable=False)
    carga_kg: Mapped[Decimal] = mapped_column(
        Numeric(10, 2), nullable=False, server_default=text("0"))

    __table_args__ = (
        CheckConstraint("carga_kg >= 0 AND carga_kg <= capacidad_kg",
                        name="cupo_no_excedido"),
    )


class PaqueteEnTransito(Base):
    """Paquete admitido que todavia no egreso de la cinta."""

    __tablename__ = "paquete_en_transito"

    id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    cinta_id: Mapped[str] = mapped_column(ForeignKey("cinta.id"), nullable=False)
    tipo_paquete: Mapped[str] = mapped_column(String, nullable=False)
    peso_kg: Mapped[Decimal] = mapped_column(Numeric(10, 2), nullable=False)
    admitido_en: Mapped[object] = mapped_column(
        DateTime(timezone=True), server_default=func.now())


class CintaEventual(Base):
    """
    Copia de la cinta que usan solo los endpoints de demostracion que emulan un
    almacen BASE. A proposito NO tiene la restriccion cupo_no_excedido, porque
    un almacen eventualmente consistente no ofrece invariantes de ese tipo.

    - carga_kg          lo que el sistema CREE que hay sobre la cinta
    - peso_admitido_kg  lo que REALMENTE hay
    - admitidos         cuantos paquetes entraron
    """

    __tablename__ = "cinta_eventual"

    id: Mapped[str] = mapped_column(String, primary_key=True)
    capacidad_kg: Mapped[Decimal] = mapped_column(Numeric(10, 2), nullable=False)
    carga_kg: Mapped[Decimal] = mapped_column(
        Numeric(10, 2), nullable=False, server_default=text("0"))
    peso_admitido_kg: Mapped[Decimal] = mapped_column(
        Numeric(10, 2), nullable=False, server_default=text("0"))
    admitidos: Mapped[int] = mapped_column(
        Integer, nullable=False, server_default=text("0"))
    
class ResultadoSolicitudCola(Base):
    """Resultado terminal de una admision recibida por la cola."""

    __tablename__ = "resultado_solicitud_cola"

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True)
    codigo_http: Mapped[int] = mapped_column(Integer, nullable=False)
    respuesta: Mapped[dict] = mapped_column(JSONB, nullable=False)
    procesada_en: Mapped[object] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False)
