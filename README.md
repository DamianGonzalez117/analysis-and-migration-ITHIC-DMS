# analysis-and-migration-ITHIC-DMS

CLI en Ruby para conciliar archivos `.txt` exportados de ITHIC (separados por `|`) contra
la base de datos DSM (PostgreSQL): defines en un mapeo YAML qué campos comparar contra qué
columnas, el sistema muestra las diferencias en reportes Markdown y, si hace falta, genera
y ejecuta la migración (INSERT / UPSERT) de los registros faltantes.

## Requisitos

- Ruby 3.1+ (desarrollado con 3.3)
- PostgreSQL (DSM)
- `libpq` (`sudo apt install libpq-dev`)

## Instalación

```bash
bundle install
cp config/.env.example .env   # edita credenciales
chmod +x bin/ithic
```

## Configuración (`.env`)

```ini
CONNECTION_STRING="host:5432"
USER="usuario"
PASSWORD="contraseña"
DATABASE="postgres"
SCHEMA="core"
```

## Comandos

```bash
bin/ithic mapeos                                      # lista los mapeos disponibles
bin/ithic importar "30 sep" [--origen DIR] [--mapeo pagares]
bin/ithic consultar pagares --param year=2026         # total de registros DSM
bin/ithic comparar pagares pagares-26.txt [--param year=2026]
bin/ithic migrar pagares pagares-con_id252852.txt --sql salida.sql --ejecutar
bin/ithic help COMMAND
```

`comparar` infiere parámetros desde el nombre del archivo (p. ej. `pagares-26.txt` → `year=2026`)
y genera en `data/reportes/<mapeo>/`:

- `diferencia_<CAMPO>-<aa>.md`: una tabla por campo con `CLAVE | ITHIC | DSM | Diferencia`
  (en montos la diferencia es `DSM - ITHIC`; lo que existe de un solo lado se marca
  `solo en ITHIC` / `solo en DSM`).
- `resumen-<mapeo>-<aa>.md`: totales y resultado `CUADRA` / `NO CUADRA`.

`migrar` es segura por defecto: **simula** y muestra el plan; solo aplica cambios con
`--ejecutar` (en una transacción). Opciones:

| Opción | Efecto |
| --- | --- |
| `--sql RUTA` | escribe el script SQL generado (sin ejecutarlo) |
| `--ejecutar` | aplica las sentencias en una transacción |
| `--conflicto nada` | `ON CONFLICT DO NOTHING`: solo inserta faltantes (default) |
| `--conflicto actualizar` | `ON CONFLICT DO UPDATE`: inserta y actualiza existentes (upsert) |

## Arquitectura

```
bin/ithic                        punto de entrada
lib/ithic/
  cli.rb              Thor: comandos, opciones y salida por consola
  configuracion.rb    lectura de .env y rutas del proyecto
  base_datos.rb       conexión PostgreSQL (pg) y search_path
  repositorio_dsm.rb  consultas de apoyo (claves existentes, ejecución transaccional)
  lector_txt.rb       lectura de .txt separados por | (BOM, UTF-8, latin-1)
  normalizador.rb     conversión de tipos: uuid, fecha, decimal, entero
  mapeo.rb            carga y valida el YAML declarativo
  comparador.rb       motor genérico de comparación por clave
  reporte_markdown.rb reportes por campo + resumen
  migrador.rb         plan de migración, generación de SQL y UPSERT
config/mapeos/*.yml   mapeos declarativos (pagarés incluido)
data/entrada/         .txt importados desde ITHIC
data/reportes/        reportes generados (ignorado por git)
spec/                 pruebas RSpec con fixtures
```

Flujo de comparación: `LectorTxt` → `Normalizador` → `Comparador` → `ReporteMarkdown`.
Flujo de migración: `LectorTxt` + claves existentes en DSM (`RepositorioDsm`) → `Migrador` →
sentencias SQL transaccionales.

### Capas

- **Entrada**: `LectorTxt` normaliza encabezados y valores; el mapeo declara la clave.
- **Dominio**: `Comparador` y `Migrador` no conocen la base de datos ni la CLI (testeables con datos).
- **Infraestructura**: `BaseDatos`/`RepositorioDsm` aíslan `pg`; `Configuracion` aísla `.env`.
- **Presentación**: `CLI` (Thor) y `ReporteMarkdown`.

## Mapeo YAML

```yaml
nombre: pagares
clave:                # campo que identifica el registro
  fuente: COI_UUID    # columna en el .txt
  dsm: COI_UUID       # alias devuelto por la consulta
  tipo: uuid
parametros:           # parámetros de la consulta
  - nombre: year
    tipo: entero
    desde_nombre: 'pagares-(\d+)\.txt$'  # se infiere del archivo
    sumar: 2000                          # 26 -> 2026
consulta: |           # SQL con placeholders :nombre -> $1, $2...
  select ... where con.year = :year
campos:               # columnas comparadas y reportadas
  - fuente: COI_AMOUNT
    dsm: COI_AMOUNT
    tipo: decimal
reporte:
  carpeta: pagares
migracion:
  tabla: promissory_notes
  conflicto: nada     # nada | actualizar
  clave:
    fuente: COI_UUID
    columna: promissory_note_id
    tipo: uuid_postgres
  columnas:
    - fuente: COI_AMOUNT
      columna: amount
      tipo: decimal
```

Tipos de normalización disponibles:

| Tipo | Uso |
| --- | --- |
| `texto` | comparación literal (trim) |
| `entero` / `decimal` | comparación numérica; en decimales el reporte resta `DSM - ITHIC` |
| `fecha` | comparación por día (`20/07/2026 00:00` = `20/07/2026`) |
| `fecha_iso` | conversión a `YYYY-MM-DD` para migración |
| `uuid` | mayúsculas sin guiones (comparación) |
| `uuid_postgres` | minúsculas con guiones (clave para INSERT) |

Si el `.txt` no trae un campo declarado, se omite de la comparación y se reporta como
ausente. Si un campo de migración obligatorio falta en el `.txt`, `migrar` falla con un
mensaje claro (marca `opcional: true` para permitir `NULL`).

## Pruebas

```bash
bundle exec rspec
```

Sin Ruby local, con Docker (requiere `--network host` si el DNS del contenedor no resuelve):

```bash
docker run --rm --network host -v "$PWD":/app -w /app ruby:3.3 \
  bash -lc "apt-get update && apt-get install -y libpq-dev && bundle install && bundle exec rspec"
```

## Migrado desde `balance-of-ITHIC` (Python)

| Original | Ruby |
| --- | --- |
| `app.py` + `nucleo/ejecutor.py` | `bin/ithic` + Thor (`lib/ithic/cli.rb`) |
| `conexion/database.py` | `lib/ithic/base_datos.rb` + `configuracion.rb` |
| `pagares/compare/compare.py` | `comparador.rb` + `reporte_markdown.rb` (genérico) |
| `pagares/compare/query.py` | mapeo YAML (`consulta`) + `consultar` |
| `pagares/compare/import_pagares.py` | `ithic importar` |
| `pagares/migracion/migrate.py` (vacío) | `migrador.rb` + `ithic migrar` |

El motor es genérico y guiado por configuración: para una entidad nueva basta crear otro
`.yml` en `config/mapeos/`.

## Migración de consumos (scripts puntuales)

`data/entrada/migracion/consumos/` contiene el export de ITHIC
(`consumption_blocked_details.txt` con 122,270 registros + catálogos). El flujo usa cuatro
scripts:

```bash
# 1) Insertar los catálogos si aún no existen en DSM (simula por defecto)
bundle exec ruby scripts/migracion_consumos/insertar_catalogos.rb
bundle exec ruby scripts/migracion_consumos/insertar_catalogos.rb --actualizar --ejecutar

# 2) Resolver los UUID existentes en DSM y escribir mapa_catalogos.json
bundle exec ruby scripts/migracion_consumos/generar_mapa.rb

# 3) Simular (no escribe nada) o insertar
bundle exec ruby scripts/migracion_consumos/insertar_consumos.rb
bundle exec ruby scripts/migracion_consumos/insertar_consumos.rb --ejecutar
bundle exec ruby scripts/migracion_consumos/insertar_consumos.rb --actualizar --ejecutar  # rellena cat_*_id NULL
bundle exec ruby scripts/migracion_consumos/insertar_consumos.rb --limite 10 --ejecutar  # prueba
bundle exec ruby scripts/migracion_consumos/insertar_consumos.rb --sql salida.sql --reporte incidencias.csv --ejecutar

# 4) Configuración de consumos (data_config_consumption.txt)
bundle exec ruby scripts/migracion_consumos/insertar_config_consumption.rb
bundle exec ruby scripts/migracion_consumos/insertar_config_consumption.rb --actualizar --ejecutar
```

Reglas aplicadas:

- `external_id` ya existente en DSM: se omite. Nuevo: se inserta con UUID generado.
  Con `--actualizar` se rellenan sus `cat_*_id` que estén en `NULL` usando `COALESCE`
  (no sobrescribe valores ya asignados).
- `object_status_id = CREADO` (`1f0746ed-9ae6-4055-a641-efb4bf7d0a56`); los estatus
  válidos alternos son ENVIADO A SAP, NO ENVIADO A SAP y ELIMINADO.
- Booleanos: `1` => `true`; vacío o `0` => `false`.
- Fechas `d/m/AAAA`; campos vacíos => `NULL`.
- Catálogos: el UUID se toma de DSM priorizando el de mayor uso real en consumos
  existentes (y el más antiguo si hay empate). Códigos vacíos o `0` => `NULL`.
- `insertar_catalogos.rb` inserta `cat_accounting_record_types` →
  `cat_cost_center_consumption` → `cat_sales_types` → `cat_sales_details_types` (ese orden
  por la FK de centros de costo). Omite los `external_id` existentes, usa el estatus
  `ACTIVO` y resuelve `cat_accounting_record_type_id` por código externo. `--actualizar`
  corrige nombre/descripción de las filas existentes.
- `cat_sales_details_types.external_id` es `uuid` en DSM, así que sus filas se insertan con
  `external_id = NULL` y se identifican por nombre; los nombres repetidos se comparan por
  cantidad.
- Distribuciones referenciadas que no existen en DSM => `contract_investment_distribution_id`
  `NULL` (decisión de negocio).
- 4 filas con defecto de exportación (campo extra o `|` dentro de COMENTS) se corrigen
  por `external_id` en `comun.rb`.

Configuración de consumos (`data_config_consumption`, 1,344 filas):

- La existencia se evalúa por **clave de negocio** (área, tipo de venta, tipo de contrato
  de inversión, registro contable, centro de costo y detalle de venta) comparando códigos
  externos, no UUID: la migración previa eligió otras filas duplicadas de los mismos
  catálogos. Las 1,344 claves ya existen en DSM.
- Las filas nuevas se insertan con status `ACTIVO` (consistente con esta tabla de
  configuración y los catálogos) y `account_cost` vacío => `0` (columna NOT NULL).
- `--actualizar` corrige `account_cost` y `send_sap_cost` de las filas existentes
  (DSM las tenía en `0`/`false`): 1,214 filas a corregir.

## Migración de marcas y customer_brands (scripts puntuales)

`data/entrada/marcas/Marcas.txt` (18,255 registros) es el export de submarcas de ITHIC.
Los scripts de `scripts/migracion_brands_and_customerbrands/` lo comparan contra
`core.sub_brands` (filtrado por `subsidiary_number = 0` vía `customers_brands` →
`shared_customers` → `subsidiaries`) y aplican los faltantes. `customer_brands.txt` y
`sub_brands.txt` contienen los 8 pares que se insertan en un entorno limpio.

```bash
# Comparar contra DSM y generar reportes (no escribe)
bundle exec ruby scripts/migracion_brands_and_customerbrands/comparar_marcas.rb

# Base existente (QA): corrige los 6 sub_brands conocidos y crea el shared_customer
# NACIONAL de GRUPO POSADAS si falta (simula por defecto)
bundle exec ruby scripts/migracion_brands_and_customerbrands/actualizar_marcas.rb
bundle exec ruby scripts/migracion_brands_and_customerbrands/actualizar_marcas.rb --ejecutar

# Entorno limpio: inserta shared_customer, customers_brands y sub_brands
bundle exec ruby scripts/migracion_brands_and_customerbrands/insertar_marcas.rb
bundle exec ruby scripts/migracion_brands_and_customerbrands/insertar_marcas.rb --ejecutar
```

Reglas aplicadas:

- `comparar_marcas.rb` reporta faltantes, sobrantes, `external_id` duplicados y diferencias
  de nombre/`short_name`; escribe `data/reportes/marcas/comparacion_marcas.md`,
  `faltantes_en_dsm.csv` y `diferencias_nombres.csv`, y sale con código 2 si `NO CUADRA`.
- `actualizar_marcas.rb` cambia el `external_id` de TENIS CHARLY de `45661` a `68159` y
  enlaza los 6 `sub_brands` con sus `customer_brand_id`; aborta si los IDs esperados no
  existen (en ese caso corresponde `insertar_marcas.rb`).
- `insertar_marcas.rb` usa `MARCA_SIN_MARCA` (o `MARCA_ALTERNA`) como `brand_id` y empareja
  `customer_brands.txt` con `sub_brands.txt` por posición. Si el `sub_brand_id` ya existe,
  no inserta y sugiere `actualizar_marcas.rb`.
- Ambos comandos aceptan `--sql RUTA` (escribe el plan con `BEGIN`/`COMMIT`), simulan por
  defecto, aplican en una transacción con `--ejecutar` y verifican el resultado
  (`CUADRA` / `NO CUADRA`).
- `insert_marcas.sql` y `update_marcas_qa.sql` son los planes ya generados para QA.
