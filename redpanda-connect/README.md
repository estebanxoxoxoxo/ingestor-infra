# Redpanda Connect — el ingestor

Fuente de verdad **versionada** del ingestor que corre en la VM. Reemplazó a
Vector el 2026-08-12; la instancia es una copia de lo que hay acá.

| Archivo | Qué es |
|---|---|
| `connect.yaml` | La config completa: input HTTP, buffer durable, raw y bronze |
| `redpanda-connect.service` | La unidad de systemd (el paquete no trae una) |
| `bronze_v1.schema` | El contrato del parquet (17 columnas), como documentación — el esquema operativo vive DENTRO de `connect.yaml` |

Marcadores: `[VM]` la instancia, `[ZONE]` su zona, `[BUCKET]` el lake.

## Por qué se reemplazó Vector (verificado, no supuesto)

1. Vector sólo sabe escribir **parquet** por su sink de S3 (`batch_encoding`
   no existe en su sink de GCS — en ninguna versión).
2. Escribir a GCS por su API compatible con S3 fracasó: los SDK modernos de
   AWS agregan un checksum CRC32 **dentro de la firma** y Google no lo
   implementa → 403 `InvalidSecurity`, y Vector además lo trataba como error
   no reintentable y **descartaba los eventos**.
3. Redpanda Connect trae `parquet_encode` y salida **nativa** de GCS: la VM
   se autentica con su service account por el servidor de metadatos.
   **Cero credenciales en disco.**

## Qué garantiza el diseño

- **Durabilidad real**: buffer **sqlite** en `/var/lib/redpanda-connect/`.
  El `200` al SDK sale recién con el evento persistido; un reinicio retoma
  desde el más viejo sin entregar. (Mejor que el original: el `http_server`
  de Vector ni soportaba acknowledgements.)
- **Paridad de contrato**: bronze = mismas 17 columnas, mismos nombres,
  timestamps `TIMESTAMP(MICROS)` UTC, misma corrección de reloj contra
  `sentAt`, mismo filtro de bots (regex textual), mismos ids `""` → null.
  raw = mismo shape `[{message, path, source_type, timestamp}]` que ya leen
  la app y DuckDB.
- **Sólo loopback**: escucha en `127.0.0.1:8080`; el único frente es Caddy.
  El server de administración de Connect (`:4195`) está deshabilitado.

## Qué cambió respecto de Vector, a sabiendas

| Cambio | Motivo |
|---|---|
| raw pasa de `.log.zst` a **`.log.gz`** | El procesador de compresión no trae zstd; DuckDB y BigQuery leen gzip igual, y los `.zst` viejos siguen legibles |
| La carpeta `dt=` sale de la hora del **flush** (UTC) | Vector particionaba por timestamp del evento; con flush-time desaparecen los archivos tardíos en la carpeta de ayer (la "gracia" post-medianoche de la app queda sin trabajo, no rota) |
| Se retiró el sink `errors/` | raw guarda TODO lo que entra, malformado incluido: es la fuente de reproceso |
| Se retiraron los taps de consola y las métricas a CloudWatch/Stackdriver | Observabilidad accesoria; el journal y las métricas de la plataforma cubren la guardia |

## Instalación en la VM (una vez)

```bash
gcloud compute ssh [VM] --zone=[ZONE] --command="curl -1sLf 'https://linux.pkg.redpanda.com/setup-redpanda.deb.sh' | sudo -E bash && sudo apt-get install -y redpanda-connect && sudo useradd --system --no-create-home --shell /usr/sbin/nologin redpanda-connect 2>/dev/null; redpanda-connect --version"
```

## Despliegue de la config

```bash
npm run infra:connect
```

Sube `connect.yaml` + unidad al bucket, la VM baja con su identidad, corre
`redpanda-connect lint` y **sólo si pasa** instala y reinicia. El reinicio no
pierde nada: el buffer persiste.

## Verificación (la que se corrió en el ensayo del 2026-08-12)

1. POST local → `200`; POST por el dominio (Caddy) → `200`.
2. Tras el flush (`batching.period: 600s`): `.log.gz` en raw y `.parquet` en
   bronze.
3. El parquet abierto con DuckDB: 17 columnas, `TIMESTAMP WITH TIME ZONE`,
   el evento con user agent de bot **ausente**, `user_id` NULL por `""`, y
   `timestamp` = `received_at` − deriva del reloj.
4. El raw abierto con la query de la app (`unnest(json)`): todas las
   requests, bots incluidos.
5. Segundos después de cada archivo: su doc en Firestore, puesto por
   `index-writer`.
