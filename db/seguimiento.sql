-- Base propia del componente seguimiento.
--
-- Va en el mismo servidor que la base cinta, pero con su usuario y sin acceso
-- a la otra: seguimiento solo conoce lo que le llega por eventos.

CREATE USER seguimiento WITH PASSWORD 'seguimiento';
CREATE DATABASE seguimiento OWNER seguimiento;

REVOKE CONNECT ON DATABASE cinta FROM PUBLIC;
REVOKE CONNECT ON DATABASE seguimiento FROM PUBLIC;
GRANT CONNECT ON DATABASE seguimiento TO seguimiento;
