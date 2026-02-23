Clínica MAXSALUD – Generación de PAGO_MOROSO
Caso

Generación de PAGO_MOROSO (atenciones pagadas fuera de plazo del año anterior).

Propósito académico del script

Este script implementa una solución completa en un único archivo para identificar pagos de atenciones realizados fuera de plazo durante el año anterior al año en curso y generar el registro consolidado en la tabla PAGO_MOROSO.

Componentes exigidos por el enunciado (trazabilidad)
1) Package

Incluye:

Variables públicas:

G_VALOR_MULTA_DIARIA

G_VALOR_DESCTO_APLICADO

Función pública:

FN_PORC_DESCTO_3RA_EDAD

Variable adicional para control de integridad operativa:

G_PERMITE_DML_PAGO_MOROSO (habilita DML solo durante el proceso automático)

2) Función almacenada

FN_NOMBRE_ESPECIALIDAD: obtiene la especialidad asociada a una atención médica.

3) Procedimiento principal

SP_GENERA_PAGO_MOROSO: genera los registros en PAGO_MOROSO integrando:

Package (variables y función)

Función de especialidad

VARRAY con valores de multa diaria

Estructura IF / ELSIF / ELSE para clasificación de especialidades

TRUNCATE de tabla destino en tiempo de ejecución

4) Triggers

TRG_PAGO_MOROSO_BLOQUEO: evita inserciones, modificaciones o eliminaciones manuales sobre PAGO_MOROSO.

TRG_PAGO_ATENCION_VALID_FECHAS: valida integridad de fechas de pago y vencimiento.

Supuestos y observaciones del modelo

No existe ESPECIALIDAD_MEDICO.

El nombre de la especialidad se obtiene mediante la relación:

MEDICO.ESP_ID -> ESPECIALIDAD.ESP_ID -> ESPECIALIDAD.NOMBRE

Consideraciones de ejecución

El script es re-ejecutable: incorpora DROP seguro de objetos antes de crearlos.

Requiere permisos para:

CREATE PROCEDURE

CREATE FUNCTION

CREATE PACKAGE

CREATE TRIGGER

TRUNCATE TABLE sobre PAGO_MOROSO

Se habilita la salida por consola mediante DBMS_OUTPUT.
