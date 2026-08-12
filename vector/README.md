# Vector — la config del ingestor

Fuente de verdad **versionada** del ingestor. Antes esto vivía sólo adentro de
la instancia; ahora la instancia es una copia de lo que hay acá.

| Archivo | Qué es |
|---|---|
| `vector.yaml` | La config completa: source HTTP, split de batches, filtro de bots, sinks y taps |
| `bronze_v1.schema` | Esquema parquet de bronze (17 columnas), textual del original |

Los comandos usan marcadores: `[PROJECT]` el proyecto, `[BUCKET]` el lake
(`[PROJECT]-lake`), `[VM]` la instancia, `[ZONE]` su zona, `[SA]` la service
account que lleva puesta la VM.

## Qué cambió respecto de la versión que corre en AWS

Sólo los destinos. El source, las transformaciones —incluida la corrección de
reloj y el filtro de bots— y los taps de consola son textuales.

| AWS | GCP |
|---|---|
| `s3_raw` · `aws_s3` + `region` | `gcs_raw` · `gcp_cloud_storage` |
| `s3_bronze` · `aws_s3` | `gcs_bronze` · `gcp_cloud_storage` |
| `s3_errors` · `aws_s3` | `gcs_errors` · `gcp_cloud_storage` |
| `cloudwatch` · `aws_cloudwatch_metrics` | `monitoring` · `gcp_stackdriver_metrics` |
| Credenciales del rol de instancia | Service account pegada a la VM, sin claves |

Lo que **ya venía bien** y no se tocó: `acknowledgements.enabled: true` global
y `buffer.type: disk` con `when_full: block` en los tres sinks. Con eso, el
`200 OK` al SDK sale recién cuando el destino confirmó, y un reinicio no pierde
lo que esté en cola.

## Instalación en la VM (una sola vez)

Antes de desplegar config hay que tener Vector y el directorio de buffers.
Debian 12 tiene repositorio oficial:

```bash
gcloud compute ssh [VM] --zone=[ZONE] --command="curl -1sLf https://setup.vector.dev/ | sudo -E bash && sudo apt-get install -y vector && sudo mkdir -p /var/lib/vector && sudo chown vector:vector /var/lib/vector && vector --version"
```

`/var/lib/vector` es el `data_dir` de la config: ahí viven los buffers en
disco. Si no existe con el dueño correcto, Vector no arranca.

## Despliegue de la config: repo → bucket → VM

El bucket es el intermediario, y la VM baja con su propia identidad — así no
hace falta copiar archivos entre máquinas ni guardar credenciales.

**1. Publicar** (desde donde tengas los archivos y `gcloud`):

```bash
gcloud storage cp vector.yaml bronze_v1.schema gs://[BUCKET]/config/
```

**2. Permiso de LECTURA para la VM** — una sola vez. La service account tiene
`objectCreator` para escribir el lake, pero eso **no** le deja leer:

```bash
gcloud storage buckets add-iam-policy-binding gs://[BUCKET] --member=serviceAccount:[SA]@[PROJECT].iam.gserviceaccount.com --role=roles/storage.objectViewer
```

**3. Bajar y validar** en la instancia:

```bash
gcloud compute ssh [VM] --zone=[ZONE] --command="sudo gcloud storage cp gs://[BUCKET]/config/vector.yaml /etc/vector/vector.yaml && sudo gcloud storage cp gs://[BUCKET]/config/bronze_v1.schema /etc/vector/bronze_v1.schema && sudo vector validate /etc/vector/vector.yaml"
```

**4. Aplicar sin cortar el listener**:

```bash
gcloud compute ssh [VM] --zone=[ZONE] --command="sudo systemctl reload vector"
```

Siempre `validate` **antes** de recargar: si la config no valida Vector
conserva la anterior, pero el validate te lo dice sin tocar nada.

Dos límites de la recarga en caliente: los cambios de `buffer` y `data_dir`
piden **reinicio**, y el `schema_file` **no se vigila** — si cambiás sólo el
esquema, hay que recargar igual para que lo relea.

## Prueba de humo

Desde adentro de la instancia, porque el puerto 8080 sólo escucha ahí:

```bash
gcloud compute ssh [VM] --zone=[ZONE] --command="curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/v1/batch -H 'Content-Type: application/json' -d '{\"batch\":[{\"type\":\"page\",\"event\":\"prueba\",\"messageId\":\"test-1\",\"context\":{\"userAgent\":\"Mozilla/5.0 Chrome/145\"}}]}'"
```

Tiene que devolver `200`. Después, que el archivo aparezca en el lake (raw es
rápido; bronze puede tardar hasta 10 minutos por `batch.timeout_secs: 600`):

```bash
gcloud storage ls --recursive gs://[BUCKET]/raw/
```

El user agent de la prueba importa: si mandás uno con `curl/` o `bot`, el
evento entra a raw pero **el filtro lo descarta antes de bronze** — que es
exactamente lo que pasó con el crawler de Meta los días 08-08, 08-09 y 08-11.

## Por qué bronze escribe por la API de S3

**Verificado en Vector 0.57** (la misma versión en la EC2 y en la VM):
`batch_encoding` —el campo que produce parquet— existe **sólo en el sink
`aws_s3`**. En `gcp_cloud_storage` el validate corta con *unknown field
`batch_encoding`*.

Solución sin rediseñar nada: GCS expone una **API compatible con S3**, así que
`gcs_bronze` queda como `aws_s3` con `endpoint: https://storage.googleapis.com`.
Escribe en el mismo bucket, con el mismo prefijo y el mismo parquet; para GCS
es un objeto igual a cualquier otro. `raw` y `errors` siguen con el sink
nativo, sin credenciales.

### Las claves HMAC (una sola vez)

Es el único componente que necesita credenciales. Se emiten **para la misma
service account que ya lleva la VM**, así que no aparece una identidad nueva:

```bash
gcloud storage hmac create [SA]@[PROJECT].iam.gserviceaccount.com
```

Devuelve un `accessId` y un `secret`. **Son credenciales de Google**, no de
AWS: la API de interoperabilidad de GCS imita el protocolo de S3 para que las
herramientas hechas para S3 funcionen contra Google. Por eso el `vector.yaml`
las referencia con nombres propios (`GCS_HMAC_*`) en vez de dejar que el sink
las tome de las variables `AWS_*` por convención.

En la VM van a un archivo que sólo lee root, y systemd se los pasa a Vector
por el entorno:

```bash
gcloud compute ssh [VM] --zone=[ZONE]
sudo tee /etc/vector/hmac.env > /dev/null <<'EOF'
GCS_HMAC_ACCESS_ID=EL-ACCESS-ID
GCS_HMAC_SECRET=EL-SECRET
EOF
sudo chmod 600 /etc/vector/hmac.env
sudo mkdir -p /etc/systemd/system/vector.service.d
sudo tee /etc/systemd/system/vector.service.d/hmac.conf > /dev/null <<'EOF'
[Service]
EnvironmentFile=/etc/vector/hmac.env
EOF
sudo systemctl daemon-reload && sudo systemctl restart vector
```

El secreto **no está en el repo ni en el `vector.yaml`**: sólo en ese archivo
de la instancia. Si se pierde, se emite otro y se revoca el viejo con
`gcloud storage hmac delete`.

## Lo otro a verificar en el primer arranque

**`gcp_stackdriver_metrics`** necesita que la service account pueda escribir
métricas (`roles/monitoring.metricWriter`). Es opcional: si molesta, se comenta
ese sink y el pipeline de datos no se entera.
