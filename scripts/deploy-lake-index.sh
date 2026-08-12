#!/bin/bash
#
# ══════════════════════════════════════════════════════════════════════
#  Índice del lake: que Firestore sepa qué hay en el bucket, sin la app
# ══════════════════════════════════════════════════════════════════════
#
# QUÉ DEJA ARMADO
#
#   bucket (raw/, bronze/) ──notificación──> Pub/Sub ──> función ──> Firestore
#
#   Cada archivo que aterriza deja su doc en
#   inventory/{capa}/days/{día}/files/{nombre} con su tamaño y su fecha;
#   cada borrado lo saca. Ocurre en segundos, con la app cerrada.
#
# POR QUÉ ASÍ Y NO DE OTRA FORMA
#
#   · Pub/Sub y no un disparador directo de Eventarc: así UNA sola función
#     atiende creados Y borrados. Con Eventarc haría falta un disparador por
#     tipo de evento, y sin el de borrado los archivos que se borren a mano
#     quedarían de fantasmas en el índice.
#   · Identidad propia para la función (no la de Vector): la que escribe el
#     índice no puede tocar el lake, y la que escribe el lake no puede tocar
#     el índice. Si una se compromete, el daño queda acotado.
#   · Sin claves en ningún lado: la función lleva puesta su service account y
#     pide el token al servidor de metadatos.
#
# QUÉ HACE, EN ORDEN
#
#   1. Service account de la función + rol para escribir Firestore.
#   2. Tópico de Pub/Sub + permiso para que GCS publique en él.
#   3. Notificaciones del bucket (raw/ y bronze/, creados y borrados).
#   4. Deploy de la función colgada del tópico.
#
# IDEMPOTENTE: correrlo de nuevo actualiza el código y saltea lo que ya está.
#
# USO
#
#   npm run infra:index
#
#   Todo se puede sobreescribir por entorno, en la misma línea:
#   BUCKET=other REGION=us-central1 npm run infra:index
#
# REQUISITOS PREVIOS
#
#   · El bucket creado (paso 5 del plan de migración).
#   · APIs habilitadas: storage, pubsub, run, cloudfunctions, firestore.
#   · Firestore creado en modo Native.
#
set -euo pipefail

# ── Parámetros ───────────────────────────────────────────────────────
# Nada está hardcodeado: todo sale del proyecto activo o del entorno.

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
# Sin proyecto activo, `get-value` devuelve "(unset)" con éxito: si no se
# corta acá, el script sigue y crea recursos con nombres absurdos.
if [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ]; then
  echo "No hay proyecto activo. Corré: gcloud config set project YOUR-PROJECT"
  exit 1
fi

BUCKET="${BUCKET:-${PROJECT}-lake}"    # el lake; el nombre se deriva del proyecto
REGION="${REGION:-us-east1}"           # dónde corre la función
SA="${SA:-index-writer}"               # identidad de la función (NO la de Vector)
TOPIC="${TOPIC:-lake-events}"          # sólo se usa acá: la función no lo conoce
FUNCTION="${FUNCTION:-index-writer}"

# Dónde vive el Firestore del índice. Por defecto, el mismo proyecto. Si la
# base estuviera en otro (p. ej. el de Firebase), se pasa acá — y hay que
# darle a la SA el rol datastore.user EN ESE proyecto.
FIRESTORE_PROJECT="${FIRESTORE_PROJECT:-$PROJECT}"

SA_EMAIL="${SA}@${PROJECT}.iam.gserviceaccount.com"

echo "project=$PROJECT"
echo "bucket=$BUCKET · region=$REGION"
echo "function=$FUNCTION · identity=$SA_EMAIL"
echo "firestore=$FIRESTORE_PROJECT · topic=$TOPIC"
echo ""

# ── 1. La identidad de la función ────────────────────────────────────
# Sólo Firestore. Sin acceso al bucket: no lo necesita, porque la
# notificación ya le trae el nombre, el tamaño y la fecha del archivo.

echo "1/4 · service account"
gcloud iam service-accounts create "$SA" \
  --display-name="Lake index -> Firestore" 2>/dev/null \
  || echo "     (ya existía)"

gcloud projects add-iam-policy-binding "$FIRESTORE_PROJECT" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/datastore.user" --condition=None >/dev/null

# Para DESPLEGAR una función con esta identidad, quien despliega tiene que
# poder "usarla". Sin esto el deploy falla con un error de IAM que no nombra
# el permiso que falta.
DEPLOYER="$(gcloud config get-value account 2>/dev/null)"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --member="user:${DEPLOYER}" --role="roles/iam.serviceAccountUser" >/dev/null

# ── 2. El tópico ─────────────────────────────────────────────────────
# El agente de servicio de GCS es una cuenta que administra Google; sin el
# permiso de publicar, las notificaciones fallan EN SILENCIO.

echo "2/4 · Pub/Sub topic"
gcloud pubsub topics create "$TOPIC" 2>/dev/null || echo "     (ya existía)"

# En un proyecto nuevo el agente de GCS TODAVÍA NO EXISTE: `gcloud storage
# service-agent` sólo calcula su nombre y el binding falla con "does not
# exist". Pedirlo por la API JSON lo crea en el momento y devuelve su correo.
GCS_SA="$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://storage.googleapis.com/storage/v1/projects/${PROJECT}/serviceAccount" \
  | grep -o '"email_address"[^,]*' | cut -d'"' -f4)"

if [ -z "$GCS_SA" ]; then
  echo "No pude obtener el agente de servicio de GCS. ¿Está habilitada la API storage.googleapis.com?"
  exit 1
fi
echo "     agente de GCS: $GCS_SA"

gcloud pubsub topics add-iam-policy-binding "$TOPIC" \
  --member="serviceAccount:${GCS_SA}" --role="roles/pubsub.publisher" >/dev/null

# ── 3. Las notificaciones del bucket ─────────────────────────────────
# Una por capa, acotadas por prefijo: lo que caiga en schemas/, config/ o
# errors/ no genera evento y no ensucia el índice.

echo "3/4 · bucket notifications"
EXISTING="$(gcloud storage buckets notifications list "gs://${BUCKET}" 2>/dev/null || true)"

create_notification() {
  local prefix="$1"
  # Coincidencia literal en cualquier parte del listado: el formato exacto de
  # la salida cambia entre versiones de gcloud, y crear la notificación dos
  # veces significa DOS eventos por cada archivo.
  if echo "$EXISTING" | grep -qF "$prefix"; then
    echo "     (ya había una para ${prefix})"
    return
  fi
  gcloud storage buckets notifications create "gs://${BUCKET}" \
    --topic="$TOPIC" \
    --event-types=OBJECT_FINALIZE,OBJECT_DELETE \
    --object-prefix="$prefix" \
    --payload-format=json
}

create_notification "raw/v=1/"
create_notification "bronze/v=1/"

# ── 3b. Los agentes de servicio de Pub/Sub y Eventarc ────────────────
# Mismo cuento que el agente de GCS: en un proyecto nuevo NO EXISTEN hasta
# que se los pide, y el deploy falla con "does not exist". `services identity
# create` los materializa. El token creator es lo que le permite a Pub/Sub
# firmar la llamada a la función.

echo "3b/4 · service agents"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"

# --quiet: sin esto, si falta el componente `beta` gcloud PREGUNTA si lo
# instala y el script queda colgado esperando una tecla. La salida NO se
# manda a /dev/null a propósito: un prompt invisible es peor que ruido.
gcloud beta services identity create --service=pubsub.googleapis.com \
  --project="$PROJECT" --quiet || echo "     (el agente de Pub/Sub ya estaba, o no hizo falta)"
gcloud beta services identity create --service=eventarc.googleapis.com \
  --project="$PROJECT" --quiet || echo "     (el agente de Eventarc ya estaba, o no hizo falta)"

gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" --condition=None >/dev/null

# ── 4. La función ────────────────────────────────────────────────────
# --retry: si Firestore falla, Pub/Sub reintenta en vez de perder el evento.
#   Es seguro porque el id del doc es el nombre del archivo: reescribir lo
#   mismo no hace daño.
# --set-env-vars: lo ÚNICO que la función sabe. Las variables de este script
#   no llegan hasta ella; acá se resuelven sus valores y quedan guardados en
#   la configuración del servicio.

echo "4/4 · function deploy"

deploy_function() {
  gcloud functions deploy "$FUNCTION" \
    --gen2 --region="$REGION" --runtime=nodejs22 \
    --source="$(dirname "$0")/../index-function" \
    --entry-point=handler \
    --trigger-topic="$TOPIC" \
    --retry \
    --service-account="$SA_EMAIL" \
    --set-env-vars="RAW_PREFIX=raw/v=1/,BRONZE_PREFIX=bronze/v=1/,BUCKET=${BUCKET},FIRESTORE_PROJECT=${FIRESTORE_PROJECT}"
}

# Los permisos recién otorgados tardan en propagarse, y el primer deploy de un
# proyecto nuevo suele chocar con eso ("can not be accessed by IAM ... please
# retry"). Un reintento a los 90 segundos lo resuelve sin intervención.
if ! deploy_function; then
  echo ""
  echo "     El primer intento falló (típico: IAM recién creada aún propagando)."
  echo "     Reintento en 90 segundos…"
  sleep 90
  deploy_function
fi

# ── Verificación ─────────────────────────────────────────────────────

echo ""
echo "LISTO. El índice se alimenta solo, con la app cerrada."
echo ""
echo "Ver qué quedó configurado:"
echo "  gcloud functions describe $FUNCTION --gen2 --region=$REGION \\"
echo "    --format=\"value(serviceConfig.serviceAccountEmail,serviceConfig.environmentVariables,eventTrigger.pubsubTopic)\""
echo ""
echo "Verlo trabajar cuando aterrice el próximo archivo:"
echo "  gcloud functions logs read $FUNCTION --region=$REGION --limit=20"
