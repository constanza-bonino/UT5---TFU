-- Esquema de la base.
--
-- La restriccion cupo_no_excedido es la C de ACID: el invariante del dominio
-- vive aca y no solo en el codigo de la aplicacion.

CREATE TABLE IF NOT EXISTS cinta (
    id            TEXT           PRIMARY KEY,
    capacidad_kg  NUMERIC(10, 2) NOT NULL,
    carga_kg      NUMERIC(10, 2) NOT NULL DEFAULT 0,
    CONSTRAINT cupo_no_excedido
        CHECK (carga_kg >= 0 AND carga_kg <= capacidad_kg)
);

CREATE TABLE IF NOT EXISTS paquete_en_transito (
    id            UUID           PRIMARY KEY,
    cinta_id      TEXT           NOT NULL REFERENCES cinta(id),
    tipo_paquete  TEXT           NOT NULL,
    peso_kg       NUMERIC(10, 2) NOT NULL,
    admitido_en   TIMESTAMPTZ    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_paquete_en_transito_cinta
    ON paquete_en_transito (cinta_id);

-- Tabla que usan solo los endpoints de demostracion que emulan BASE. A
-- proposito no tiene la restriccion de arriba.
CREATE TABLE IF NOT EXISTS cinta_eventual (
    id                TEXT           PRIMARY KEY,
    capacidad_kg      NUMERIC(10, 2) NOT NULL,
    carga_kg          NUMERIC(10, 2) NOT NULL DEFAULT 0,
    peso_admitido_kg  NUMERIC(10, 2) NOT NULL DEFAULT 0,
    admitidos         INTEGER        NOT NULL DEFAULT 0
);
