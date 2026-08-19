connect.yaml tiene hardcodeado el nombre del bucket. Modificarlo segun el caso


# ingestor-infra

La plataforma del pipeline: lo que corre en la nube, versionado acá. **La nube
es una copia de esto, nunca al revés.**

Salió de `ingestor-monitor/infra/` el 2026-08-17, con su historia. Vive
separado porque nada de esto *es* el monitor: el ingestor y el índice siguen
corriendo con la app desinstalada, y el monitor es apenas uno de sus lectores.

```
redpanda-connect/         el ingestor (VM): connect.yaml + unidad de systemd
caddy/                    el frente TLS (VM): Caddyfile
index-function/           el índice se alimenta solo: fuente de la función
regenerate-tree-function/ el remedio del índice: fuente de la función
scripts/                  los cuatro despliegues, idempotentes
CONTRATO.md               lo que otros repos leen y escriben. Se toca acá
```

## El camino de un evento

```
SDK ──POST──> Caddy (TLS) ──> Redpanda Connect ──> lake  raw/ + bronze/
                                                     │
                              notificación de GCS ───┘
                                     ↓
                                  Pub/Sub ──> index-function ──> Firestore
                                                                 inventory/
                                                                     ↓
                                                              los lectores
                                                           (ingestor-monitor,
                                                             BigQuery, …)
```

Nadie lista el bucket para saber qué hay: para eso está el índice, y por eso
existe.

## Las cuatro piezas

### `redpanda-connect/` — el ingestor

Corre en la VM. Recibe el POST en `127.0.0.1:8080`, lo persiste en un buffer
sqlite (el `200` al SDK sale recién con el evento en disco) y escribe las dos
capas: `raw/` en `.log.gz` y `bronze/` en `.parquet` de 17 columnas. Reemplazó
a Vector el 2026-08-12; el porqué verificado está en su README.

```bash
pnpm run deploy:connect
```

Sube la config al bucket, la VM la baja con su identidad, corre
`redpanda-connect lint` y **sólo si pasa** instala y reinicia. El reinicio no
pierde nada: el buffer persiste.

### `caddy/` — el frente TLS

Termina TLS con certificado automático de Let's Encrypt y proxea al 8080. Es
lo único expuesto: Connect escucha sólo en loopback.

```bash
pnpm run deploy:caddy
```

Baja a `/tmp`, valida y recién ahí pisa: un Caddyfile roto no llega a tocar el
que está sirviendo tráfico.

### `index-function/` — el índice se alimenta solo

**GCS → Pub/Sub → función → Firestore.** Cada archivo que aterriza en
`raw/v=1/` o `bronze/v=1/` deja su doc en
`inventory/{capa}/days/{día}/files/{nombre}`; cada borrado lo saca. Pasa en
segundos, sin que ninguna app esté abierta.

```bash
pnpm run deploy:index
```

Un solo comando hace todo: la service account (`index-writer`, con **sólo**
`roles/datastore.user` — no puede tocar el lake), el tópico, las
notificaciones del bucket y el deploy. Idempotente: correrlo de nuevo
actualiza el código y no duplica nada.

Por qué Pub/Sub y no un disparador directo de Eventarc: así **una sola
función** atiende creados y borrados; con Eventarc haría falta un disparador
por tipo de evento, y sin el de borrado los archivos borrados a mano
quedarían de fantasmas en el índice.

### `regenerate-tree-function/` — el remedio

**Firestore → función → Firestore.** Cuando el índice quedó mal —una
notificación perdida, la función caída, un borrado a mano— alguien escribe
`regenerateTree/{capa}` con `state: 'requested'` y esta función recorre el
bucket, lo compara contra el índice y escribe **sólo la diferencia**. El mismo
documento es el pedido y el estado, así que quien lo pidió ve el progreso con
una suscripción y puede cerrarse mientras tanto.

```bash
pnpm run deploy:regenerate
```

Requiere el índice ya desplegado: reusa su service account, con un permiso más
(leer el bucket). Sigue sin poder escribirlo.

Lo que lo hace barato: comparar día por día leyendo cada archivo costaría una
lectura por archivo. Acá cada día se compara primero con **una agregación**
(contar + sumar peso): una lectura que dice si ese día coincide con el bucket.
Sólo los días que no coinciden se abren archivo por archivo. Un lake sano se
revisa entero por una lectura por día.

Las dos funciones escriben los MISMOS docs (el id es el nombre del archivo),
así que pisarse es inofensivo: la del índice y la del remedio pueden correr a
la vez.

## Las dos funciones son de Google Cloud, no de Firebase

Se despliegan con `gcloud functions deploy --gen2` y usan
`@google-cloud/functions-framework`. No hay `firebase.json` ni
`firebase-functions`: el CLI de Firebase no participa. Gen2 significa que por
debajo corren como servicios de Cloud Run — por eso los scripts terminan
otorgando `roles/run.invoker`.

Lo que cambia entre ellas es qué las despierta: a `index-function`, un tópico
de Pub/Sub; a `regenerate-tree-function`, Eventarc sobre una escritura de
Firestore. Sólo la segunda es "de Firestore", y sólo en el sentido de que
Firestore la dispara. Las dos **escriben** Firestore.

## Verificar

```bash
gcloud functions logs read index-writer --region=us-east1 --limit=20
```

```bash
gcloud functions logs read regenerate-tree --region=us-east1 --limit=30
```

```bash
gcloud compute ssh ingestor-vm --zone=us-east1-c --command="journalctl -u redpanda-connect -n 30 --no-pager"
```

## Retirado

- **Vector** (2026-08-12): no sabe escribir parquet hacia GCS, y la vía de la
  API compatible con S3 choca con el checksum de los SDK modernos de AWS. El
  detalle verificado está en `redpanda-connect/README.md`; su config vive en
  el historial de git.
- **La Lambda de AWS** (S3 → Lambda → Firestore, con la credencial de
  Firebase guardada del lado de AWS): nunca se desplegó y se borró del repo.
  El equivalente es `deploy-lake-index.sh`, sin credenciales cruzadas.
