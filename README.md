# Infra

Todo lo que corre fuera de la app, versionado acá. La nube es una copia de
esto, nunca al revés.

```
infra/
  redpanda-connect/  el ingestor (VM): connect.yaml + unidad de systemd
  caddy/             el frente TLS (VM): Caddyfile
  index-function/    la función que mantiene el índice: código fuente
  scripts/           despliegues idempotentes
```

## El índice se alimenta solo

**GCS → Pub/Sub → función → Firestore.** Cada archivo que aterriza en
`raw/v=1/` o `bronze/v=1/` deja su doc en
`inventory/{capa}/days/{día}/files/{nombre}`; cada borrado lo saca. Pasa con la
app cerrada, en segundos.

```bash
bash infra/scripts/deploy-lake-index.sh
```

Un solo comando hace todo: la service account (`index-writer`, con **sólo**
`roles/datastore.user` — no puede tocar el lake), el tópico, las
notificaciones del bucket y el deploy de la función. Es idempotente: correrlo
de nuevo actualiza el código y no duplica nada.

Por qué Pub/Sub y no un disparador directo de Eventarc: así **una sola
función** atiende creados y borrados; con Eventarc haría falta un disparador
por tipo de evento.

### Cómo convive con la app

- **La función es LA fuente**: la app lee siempre Firebase (suscripción +
  agregaciones) y jamás lista el bucket por su cuenta.
- **Full sync** (el botón) es la única excepción: un escaneo manual que
  REPARA Firestore — notificaciones perdidas, función caída, borrados a mano.
- Ambos escriben los MISMOS docs (id = nombre del archivo): pisarse es
  inofensivo.

### Verificar

```bash
gcloud functions logs read index-writer --region=us-east1 --limit=20
```

## El ingestor

`redpanda-connect/` tiene la config, la unidad de systemd y el porqué del
reemplazo de Vector (2026-08-12), con su README. Se despliega con
`npm run infra:connect`; el frente TLS con `npm run infra:caddy`.

## Retirado

- **Vector** (2026-08-12): no sabe escribir parquet hacia GCS, y la vía de la
  API compatible con S3 choca con el checksum de los SDK modernos de AWS. El
  detalle verificado está en `redpanda-connect/README.md`; su config vive en
  el historial de git.
- **La Lambda de AWS** (S3 → Lambda → Firestore, con la credencial de
  Firebase guardada del lado de AWS): nunca se desplegó y se borró del repo.
  El equivalente es `deploy-lake-index.sh`, sin credenciales cruzadas.
