SET SERVEROUTPUT ON;

-----------------------------------------------------------------------------------------------
-- 0) Limpieza (DROP seguro / re-ejecutabilidad)
-- --------------------------------------------------------------------------------------------
-- Objetivo:
--   Permitir la re-ejecución completa del script sin fallas por objetos ya existentes.
--
-- Estrategia:
--   Se ejecuta DROP mediante SQL dinámico. Si el objeto no existe u ocurre un error durante el
--   DROP, se controla con EXCEPTION WHEN OTHERS THEN NULL para continuar el despliegue.
-----------------------------------------------------------------------------------------------
BEGIN EXECUTE IMMEDIATE 'DROP TRIGGER TRG_PAGO_MOROSO_BLOQUEO'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP TRIGGER TRG_PAGO_ATENCION_VALID_FECHAS'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP PROCEDURE SP_GENERA_PAGO_MOROSO'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP FUNCTION FN_NOMBRE_ESPECIALIDAD'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP PACKAGE PKG_MXSALUD_MOROSIDAD'; EXCEPTION WHEN OTHERS THEN NULL; END;
/

-----------------------------------------------------------------------------------------------
-- 1) PACKAGE SPEC: PKG_MXSALUD_MOROSIDAD
-- --------------------------------------------------------------------------------------------
-- Rol del package:
--   Centralizar parámetros operativos y lógica reutilizable del proceso de morosidad.
--
-- Requerimientos:
--   - Variables públicas:
--       * G_VALOR_MULTA_DIARIA      : valor diario de multa según especialidad/clasificación.
--       * G_VALOR_DESCTO_APLICADO   : monto final de descuento aplicado (adulto mayor).
--   - Función pública:
--       * FN_PORC_DESCTO_3RA_EDAD   : retorna porcentaje de descuento según tramo de edad.
--
-- Complemento de integridad:
--   - G_PERMITE_DML_PAGO_MOROSO:
--       * Bandera de control usada por trigger para bloquear DML manual.
--       * Se habilita temporalmente durante SP_GENERA_PAGO_MOROSO y se deshabilita al final.
-----------------------------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE PKG_MXSALUD_MOROSIDAD IS

  /* Valor de multa diaria según especialidad */
  G_VALOR_MULTA_DIARIA       NUMBER := 0;

  /* Monto de descuento aplicado a la multa (adultos mayores) */
  G_VALOR_DESCTO_APLICADO    NUMBER := 0;

  /* Control DML sobre PAGO_MOROSO (usado por TRG_PAGO_MOROSO_BLOQUEO) */
  G_PERMITE_DML_PAGO_MOROSO  BOOLEAN := FALSE;

  /* Retorna porcentaje descuento según edad (PORC_DESCTO_3RA_EDAD) */
  FUNCTION FN_PORC_DESCTO_3RA_EDAD (P_EDAD NUMBER) RETURN NUMBER;

END PKG_MXSALUD_MOROSIDAD;
/

-----------------------------------------------------------------------------------------------
-- 1) PACKAGE BODY: PKG_MXSALUD_MOROSIDAD
-- --------------------------------------------------------------------------------------------
-- Implementación de la lógica de negocio de descuentos por 3ra edad.
--
-- FN_PORC_DESCTO_3RA_EDAD:
--   Entrada:
--     P_EDAD: edad del paciente.
--   Salida:
--     Porcentaje de descuento. Si no existe tramo o hay error, retorna 0.
-----------------------------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE BODY PKG_MXSALUD_MOROSIDAD IS

  FUNCTION FN_PORC_DESCTO_3RA_EDAD (P_EDAD NUMBER) RETURN NUMBER IS
    V_PORC NUMBER := 0;
  BEGIN
    /* Busca el porcentaje para el tramo de edad */
    SELECT NVL(PORCENTAJE_DESCTO, 0)
      INTO V_PORC
      FROM PORC_DESCTO_3RA_EDAD
     WHERE P_EDAD BETWEEN ANNO_INI AND ANNO_TER;

    RETURN NVL(V_PORC, 0);

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      /* Si no existe tramo: sin descuento */
      RETURN 0;
    WHEN OTHERS THEN
      
      RETURN 0;
  END FN_PORC_DESCTO_3RA_EDAD;

END PKG_MXSALUD_MOROSIDAD;
/

-----------------------------------------------------------------------------------------------
-- 2) FUNCIÓN ALMACENADA: FN_NOMBRE_ESPECIALIDAD
-- --------------------------------------------------------------------------------------------
--   Obtiene el nombre de la especialidad asociada al médico que ejecutó la atención.
--   - Si no se encuentra el médico/especialidad, retorna 'SIN_ESPECIALIDAD' para evitar NULL y
--     permitir clasificación por descarte (Medicina General)
-----------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION FN_NOMBRE_ESPECIALIDAD (
  P_MED_RUN        NUMBER,
  P_FECHA_ATENCION DATE
)
RETURN VARCHAR2
IS
  V_NOMBRE ESPECIALIDAD.NOMBRE%TYPE;
BEGIN
  /* Obtiene el nombre de especialidad asociado al médico */
  SELECT e.nombre
    INTO V_NOMBRE
    FROM medico m
    JOIN especialidad e ON e.esp_id = m.esp_id
   WHERE m.med_run = P_MED_RUN;

  RETURN V_NOMBRE;

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN 'SIN_ESPECIALIDAD';
  WHEN OTHERS THEN
    RETURN 'SIN_ESPECIALIDAD';
END FN_NOMBRE_ESPECIALIDAD;
/

-----------------------------------------------------------------------------------------------
-- 3) PROCEDIMIENTO PRINCIPAL: SP_GENERA_PAGO_MOROSO
-- --------------------------------------------------------------------------------------------
--   Pobla la tabla PAGO_MOROSO con las atenciones cuyo pago fue realizado después de la fecha
--   de vencimiento (morosidad), considerando únicamente pagos realizados en el año anterior.
--
-- Requerimientos implementados:
--   - Año objetivo dinámico: EXTRACT(YEAR FROM SYSDATE) - 1
--   - TRUNCATE de PAGO_MOROSO en tiempo de ejecución (tabla destino)
--   - Uso de VARRAY (multas diarias según clasificación de especialidad)
--   - IF/ELSIF/ELSE para TODAS las condiciones de clasificación
--   - Integración de:
--       * Package (variables públicas y función de descuento)
--       * Función de obtención de especialidad (FN_NOMBRE_ESPECIALIDAD)
--
-- Flujo general del proceso:
--   1) Determinar año objetivo.
--   2) Limpiar la tabla destino (TRUNCATE).
--   3) Habilitar flag de DML para permitir inserciones controladas.
--   4) Recorrer cursor de morosos y por cada registro:
--      a) Obtener especialidad (función).
--      b) Normalizar texto para comparar (mayúsculas y sin tildes).
--      c) Clasificar especialidad y asignar multa diaria (VARRAY).
--      d) Calcular multa base (días morosidad * multa diaria).
--      e) Calcular edad a la fecha de atención.
--      f) Aplicar descuento si corresponde (> 70) y registrar observación.
--      g) Insertar en PAGO_MOROSO.
--   5) Commit y deshabilitar flag de DML.
-----------------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_GENERA_PAGO_MOROSO IS

  /* VARRAY multas por día */
  TYPE T_VARRAY_MULTAS IS VARRAY(7) OF NUMBER;
  V_MULTAS T_VARRAY_MULTAS := T_VARRAY_MULTAS(
    1200,  -- 1 Medicina General
    1300,  -- 2 Traumatologia
    1700,  -- 3 Neurologia y Pediatria
    1900,  -- 4 Oftalmologia
    1100,  -- 5 Geriatria
    2000,  -- 6 Ginecologia y Gastroenterologia
    2300   -- 7 Dermatologia
  );

  /* Año objetivo: el año anterior al año actual */
  V_ANNO_OBJETIVO NUMBER := EXTRACT(YEAR FROM SYSDATE) - 1;

  /* Variables de trabajo */
  V_ESP_ORIG      VARCHAR2(100);   -- especialidad obtenida desde BD
  V_ESP_NORM      VARCHAR2(120);   -- especialidad normalizada
  V_ESP_CLASIF    VARCHAR2(30);    -- especialidad resultante según categorías

  V_EDAD          NUMBER := 0;     -- edad del paciente a la fecha de atención
  V_PORC_DSCTO    NUMBER := 0;     -- porcentaje de descuento 
  V_MULTA_BASE    NUMBER := 0;     -- multa antes de descuento
  V_MULTA_FINAL   NUMBER := 0;     -- multa final luego de descuento
  V_OBS           VARCHAR2(100);   -- observación para justificar descuento

  /* Cursor: atenciones pagadas fuera de plazo del año objetivo */
  CURSOR CUR_MOROSOS IS
    SELECT
      p.pac_run,
      p.dv_run AS pac_dv_run,
      TRIM(
        NVL(p.pnombre,'') || ' ' ||
        NVL(p.snombre,'') || ' ' ||
        NVL(p.apaterno,'') || ' ' ||
        NVL(p.amaterno,'')
      ) AS pac_nombre,
      a.ate_id,
      pa.fecha_venc_pago,
      pa.fecha_pago,
      /* Días morosidad = fecha_pago - fecha_venc_pago (ambas truncadas) */
      TRUNC(pa.fecha_pago) - TRUNC(pa.fecha_venc_pago) AS dias_morosidad,
      a.costo AS costo_atencion,
      p.fecha_nacimiento,
      a.fecha_atencion,
      a.med_run
    FROM pago_atencion pa
    JOIN atencion a ON a.ate_id = pa.ate_id
    JOIN paciente p ON p.pac_run = a.pac_run
    WHERE pa.fecha_pago IS NOT NULL
      AND TRUNC(pa.fecha_pago) > TRUNC(pa.fecha_venc_pago)
      AND EXTRACT(YEAR FROM pa.fecha_pago) = V_ANNO_OBJETIVO
    ORDER BY pa.fecha_venc_pago ASC, p.apaterno ASC;

BEGIN
  DBMS_OUTPUT.PUT_LINE('Inicio SP_GENERA_PAGO_MOROSO - Año objetivo: ' || V_ANNO_OBJETIVO);

  /* Requerimiento: truncar tabla destino en ejecución */
  EXECUTE IMMEDIATE 'TRUNCATE TABLE PAGO_MOROSO';

  /* Habilita DML sobre PAGO_MOROSO solo durante el proceso */
  PKG_MXSALUD_MOROSIDAD.G_PERMITE_DML_PAGO_MOROSO := TRUE;

  FOR R IN CUR_MOROSOS LOOP

    /* 1) Especialidad obtenida desde la BD mediante función almacenada */
    V_ESP_ORIG := FN_NOMBRE_ESPECIALIDAD(R.med_run, R.fecha_atencion);

    /* Normalización para comparar:
       - UPPER: uniforma mayúsculas
       - TRIM: elimina espacios extremos
       - TRANSLATE: elimina tildes y normaliza caracteres para evitar falsos negativos en LIKE */
    V_ESP_NORM :=
      UPPER(
        TRANSLATE(
          TRIM(V_ESP_ORIG),
          'ÁÉÍÓÚÜÑáéíóúüñ',
          'AEIOUUNaeiouun'
        )
      );

    /* 2) Clasificación a categorías del enunciado usando SOLO IF/ELSIF/ELSE
       - Se define un valor por defecto (Medicina General) y se sobrescribe según coincidencias.
       - Además, se asigna la multa diaria en el package para mantener consistencia en el cálculo. */
    V_ESP_CLASIF := 'Medicina General';
    PKG_MXSALUD_MOROSIDAD.G_VALOR_MULTA_DIARIA := V_MULTAS(1);

    IF V_ESP_NORM LIKE '%DERMATOLOG%' THEN
      V_ESP_CLASIF := 'Dermatologia';
      PKG_MXSALUD_MOROSIDAD.G_VALOR_MULTA_DIARIA := V_MULTAS(7);

    ELSIF V_ESP_NORM LIKE '%GINECOLOG%' OR V_ESP_NORM LIKE '%GASTROENTEROLOG%' THEN
      /* Grupo: Ginecologia y Gastroenterologia (multa 2000) */
      IF V_ESP_NORM LIKE '%GINECOLOG%' THEN
        V_ESP_CLASIF := 'Ginecologia';
      ELSE
        V_ESP_CLASIF := 'Gastroenterologia';
      END IF;
      PKG_MXSALUD_MOROSIDAD.G_VALOR_MULTA_DIARIA := V_MULTAS(6);

    ELSIF V_ESP_NORM LIKE '%GERIATR%' THEN
      V_ESP_CLASIF := 'Geriatria';
      PKG_MXSALUD_MOROSIDAD.G_VALOR_MULTA_DIARIA := V_MULTAS(5);

    ELSIF V_ESP_NORM LIKE '%OFTALM%' THEN
      V_ESP_CLASIF := 'Oftalmologia';
      PKG_MXSALUD_MOROSIDAD.G_VALOR_MULTA_DIARIA := V_MULTAS(4);

    ELSIF V_ESP_NORM LIKE '%NEUROLOG%' OR V_ESP_NORM LIKE '%PEDIATR%' THEN
      /* Grupo: Neurologia y Pediatria (multa 1700) */
      IF V_ESP_NORM LIKE '%NEUROLOG%' THEN
        V_ESP_CLASIF := 'Neurologia';
      ELSE
        V_ESP_CLASIF := 'Pediatria';
      END IF;
      PKG_MXSALUD_MOROSIDAD.G_VALOR_MULTA_DIARIA := V_MULTAS(3);

    ELSIF V_ESP_NORM LIKE '%TRAUMAT%' OR V_ESP_NORM LIKE '%ORTOPED%' THEN
      V_ESP_CLASIF := 'Traumatologia';
      PKG_MXSALUD_MOROSIDAD.G_VALOR_MULTA_DIARIA := V_MULTAS(2);

    ELSE
      /* Por descarte, Medicina General */
      V_ESP_CLASIF := 'Medicina General';
      PKG_MXSALUD_MOROSIDAD.G_VALOR_MULTA_DIARIA := V_MULTAS(1);
    END IF;

    /* 3) Multa base:
       - Días de morosidad multiplicado por el valor diario asociado a la especialidad. */
    V_MULTA_BASE := R.dias_morosidad * PKG_MXSALUD_MOROSIDAD.G_VALOR_MULTA_DIARIA;

    /* 4) Cálculo de edad a la fecha de atención:
       - Se calcula edad aproximada en años usando MONTHS_BETWEEN / 12.
       - Se trunca para obtener un valor entero. */
    V_EDAD := TRUNC(MONTHS_BETWEEN(TRUNC(R.fecha_atencion), TRUNC(R.fecha_nacimiento)) / 12);

    /* 5) Descuento si edad > 70:
       - Se obtiene porcentaje desde tabla PORC_DESCTO_3RA_EDAD vía función del package.
       - Se normaliza el formato del porcentaje para evitar inconsistencias:
         * Si viene como 20, se convierte a 0.20.
       - Se registra observación cuando aplica descuento.

       - Se inicializan variables de descuento por cada iteración para evitar arrastre de valores. */
    PKG_MXSALUD_MOROSIDAD.G_VALOR_DESCTO_APLICADO := 0;
    V_PORC_DSCTO := 0;
    V_OBS := NULL;

    IF V_EDAD > 70 THEN
      V_PORC_DSCTO := PKG_MXSALUD_MOROSIDAD.FN_PORC_DESCTO_3RA_EDAD(V_EDAD);

      /* Normalización de porcentaje: 20 -> 0.20 */
      IF V_PORC_DSCTO > 1 THEN
        V_PORC_DSCTO := V_PORC_DSCTO / 100;
      END IF;

      PKG_MXSALUD_MOROSIDAD.G_VALOR_DESCTO_APLICADO := ROUND(V_MULTA_BASE * V_PORC_DSCTO);
      V_MULTA_FINAL := V_MULTA_BASE - PKG_MXSALUD_MOROSIDAD.G_VALOR_DESCTO_APLICADO;

      V_OBS := 'Paciente tenía ' || V_EDAD ||
               ' a la fecha de atención. Se aplicó descuento paciente mayor a 70 años';
    ELSE
      V_MULTA_FINAL := V_MULTA_BASE;
    END IF;

    /* 6) Inserción en PAGO_MOROSO */
    INSERT INTO pago_moroso
      (pac_run, pac_dv_run, pac_nombre, ate_id,
       fecha_venc_pago, fecha_pago, dias_morosidad,
       especialidad_atencion, costo_atencion, monto_multa, observacion)
    VALUES
      (R.pac_run, R.pac_dv_run, SUBSTR(R.pac_nombre, 1, 50), R.ate_id,
       R.fecha_venc_pago, R.fecha_pago, R.dias_morosidad,
       SUBSTR(V_ESP_CLASIF, 1, 30), R.costo_atencion, V_MULTA_FINAL, V_OBS);

  END LOOP;

  /* Confirmación transaccional:
     - Se confirma la carga completa de PAGO_MOROSO.
     - Luego se vuelve a bloquear DML manual. */
  COMMIT;

  /* Vuelve a bloquear DML manual */
  PKG_MXSALUD_MOROSIDAD.G_PERMITE_DML_PAGO_MOROSO := FALSE;

  DBMS_OUTPUT.PUT_LINE('Fin SP_GENERA_PAGO_MOROSO - Datos generados en PAGO_MOROSO.');

EXCEPTION
  WHEN OTHERS THEN
    /* Manejo defensivo:
       - Asegura que el flag de DML se restaure incluso ante error.
       - ROLLBACK revierte inserciones parciales para mantener consistencia.
       - RAISE propaga el error para diagnóstico. */
    PKG_MXSALUD_MOROSIDAD.G_PERMITE_DML_PAGO_MOROSO := FALSE;
    ROLLBACK;
    RAISE;
END SP_GENERA_PAGO_MOROSO;
/

-----------------------------------------------------------------------------------------------
-- 4) TRIGGERS
-- --------------------------------------------------------------------------------------------
--   Reforzar integridad y control operacional, evitando que el usuario final modifique datos
--   críticos del proceso por vías manuales o inconsistentes.
-----------------------------------------------------------------------------------------------

-----------------------------------------------------------------------------------------------
-- TRG_PAGO_MOROSO_BLOQUEO
-- --------------------------------------------------------------------------------------------
--   Bloquea cualquier operación DML directa (INSERT/UPDATE/DELETE) sobre la tabla PAGO_MOROSO.
--
--   Solo se permite DML cuando el procedimiento SP_GENERA_PAGO_MOROSO habilita el flag del
--   package (G_PERMITE_DML_PAGO_MOROSO = TRUE).
--
--   Garantiza que PAGO_MOROSO sea una salida calculada y no una tabla editable, protegiendo
--   la trazabilidad del resultado.
-----------------------------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER TRG_PAGO_MOROSO_BLOQUEO
BEFORE INSERT OR UPDATE OR DELETE ON PAGO_MOROSO
BEGIN
  IF PKG_MXSALUD_MOROSIDAD.G_PERMITE_DML_PAGO_MOROSO = FALSE THEN
    RAISE_APPLICATION_ERROR(-20051,
      'Operación no permitida: PAGO_MOROSO se genera solo mediante SP_GENERA_PAGO_MOROSO.');
  END IF;
END;
/

-----------------------------------------------------------------------------------------------
-- TRG_PAGO_ATENCION_VALID_FECHAS
-- --------------------------------------------------------------------------------------------
--   Validar consistencia de fechas en PAGO_ATENCION.
--
--   1) FECHA_VENC_PAGO es obligatoria (no puede ser NULL).
--   2) Si FECHA_PAGO existe, no puede ser anterior a FECHA_VENC_PAGO.
--
--   Se aplica TRUNC a las fechas para comparar a nivel de día, coherente con el cálculo de
--   morosidad del procedimiento principal.
-----------------------------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER TRG_PAGO_ATENCION_VALID_FECHAS
BEFORE INSERT OR UPDATE OF FECHA_PAGO, FECHA_VENC_PAGO ON PAGO_ATENCION
FOR EACH ROW
BEGIN
  IF :NEW.FECHA_VENC_PAGO IS NULL THEN
    RAISE_APPLICATION_ERROR(-20052, 'FECHA_VENC_PAGO no puede ser NULL.');
  END IF;

  IF :NEW.FECHA_PAGO IS NOT NULL THEN
    IF TRUNC(:NEW.FECHA_PAGO) < TRUNC(:NEW.FECHA_VENC_PAGO) THEN
      RAISE_APPLICATION_ERROR(-20053, 'FECHA_PAGO no puede ser anterior a FECHA_VENC_PAGO.');
    END IF;
  END IF;
END;
/

-----------------------------------------------------------------------------------------------
-- 5) PRUEBAS
-- --------------------------------------------------------------------------------------------
-- Ejecutar el proceso (genera datos en PAGO_MOROSO):
-- EXEC SP_GENERA_PAGO_MOROSO;

-- Validar el orden solicitado (vencimiento ascendente + nombre ascendente):
-- SELECT *
-- FROM pago_moroso
-- ORDER BY fecha_venc_pago ASC, pac_nombre ASC;

-- Probar bloqueo de modificación manual (debe fallar con ORA-20051):
-- UPDATE pago_moroso SET observacion = 'PRUEBA' WHERE ROWNUM = 1;

-- Probar integridad en PAGO_ATENCION (debe fallar con ORA-20053):
-- UPDATE pago_atencion
--    SET fecha_pago = fecha_venc_pago - 1
--  WHERE ate_id = (SELECT MIN(ate_id) FROM pago_atencion);