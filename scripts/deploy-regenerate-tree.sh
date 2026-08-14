#!/bin/bash
#
# ══════════════════════════════════════════════════════════════════════
#  Regenerar el árbol en la base: el remedio, del lado de Google
# ══════════════════════════════════════════════════════════════════════
#
# QUÉ DEJA ARMADO
#
#   app ──escribe la orden──> Firestore regenerateTree/{capa}
#                                   │
#                                   └──dispara──> función ──> lee el bucket,
#                                                 compara y escribe el diff
#
#   La app sólo deja el pedido y puede cerrarse: el trabajo ocurre en
#   Google. El MISMO documento es la orden y el estado, así que la app ve el
#   progreso con una suscripción.
#
# POR QUÉ ASÍ Y NO DE OTRA FORMA
#
#   · Disparo por documento y no por HTTP: sin endpoint que exponer, sin
#     autenticación aparte, y el progreso viaja por donde la app ya escucha.
#   · La función compara cada día con UNA agregación (contar + sumar) antes
#     de abrirlo archivo por archivo: un lake sano se revisa por una lectura
#     por día en vez de una por archivo.
#   · Reusa la identidad del índice (misma que escribe inventory/), con un
#     permiso más: leer el bucket. Sigue sin poder escribirlo.
#
# QUÉ HACE, EN ORDEN
#
#   1. Permiso de lectura del bucket para la service account del índice.
#   2. Deploy de la función colgada de las escrituras en regenerateTree/.
#
# IDEMPOTENTE: correrlo de nuevo actualiza el código y saltea lo que ya está.
#
# USO
#
#   npm run infra:regenerate
#
# REQUISITOS PREVIOS
#
#   · El índice ya desplegado (npm run infra:index): de ahí sale la SA.
#   · APIs habilitadas: run, cloudfunctions, eventarc, firestore.
#
set -euo pipefail

# ── Parámetros ───────────────────────────────────────────────────────

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
if [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ]; then
  echo "No hay proyecto activo. Corré: gcloud config set project YOUR-PROJECT"
  exit 1
fi

REGION="${REGION:-us-east1}"
# El disparador de Firestore NO va donde la función: va donde vive la base
# (acá `nam5`, multi-región). Se pregunta en vez de hardcodearlo, que es el
# error que rompe este deploy en un proyecto nuevo.
TRIGGER_LOCATION="${TRIGGER_LOCATION:-$(gcloud firestore databases describe \
  --database='(default)' --format='value(locationId)' 2>/dev/null)}"
if [ -z "$TRIGGER_LOCATION" ]; then
  echo "No pude leer la región de Firestore. ¿Existe la base '(default)'?"
  exit 1
fi
BUCKET="${BUCKET:-${PROJECT}-lake}"
FUNCTION="${FUNCTION:-regenerate-tree}"
SA_NAME="${SA_NAME:-index-writer}"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
FIRESTORE_PROJECT="${FIRESTORE_PROJECT:-$PROJECT}"
# La colección de órdenes y el doc de settings: los mismos nombres que usa
# la app (src/shared/config.ts).
ORDERS="${ORDERS:-regenerateTree}"

echo "Proyecto:  $PROJECT"
echo "Región:    $REGION  (disparador en $TRIGGER_LOCATION, donde vive Firestore)"
echo "Bucket:    $BUCKET"
echo "Función:   $FUNCTION"
echo "Identidad: $SA_EMAIL"
echo ""

# ── 1. Leer el bucket ────────────────────────────────────────────────
# La función lista objetos para compararlos con el índice. Sólo lectura: el
# lake lo escribe el ingestor, nadie más.

echo "1/2 · permisos: leer el bucket y recibir el evento"

gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectViewer" >/dev/null

# Sin esto, el deploy muere con 403 'eventarc.events.receiveEvent denied':
# el disparador entrega el evento CON ESTA identidad, así que además de
# escribir Firestore tiene que poder recibirlo. (`run.invoker` ya se lo dio
# el script del índice: es la misma service account.)
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/eventarc.eventReceiver" \
  --condition=None >/dev/null

# ── 2. La función ────────────────────────────────────────────────────
# Disparador de Firestore: cualquier escritura sobre un documento de la
# colección de órdenes. La función misma descarta las que no son pedidos
# nuevos (su primer paso es pasar el estado a 'running').
#
# --timeout: el techo de las funciones por evento. Con la comparación por
#   agregación alcanza de sobra; si algún día no alcanzara, se vuelve a
#   pedir y la corrida siguiente encuentra casi todo sano.

echo "2/2 · function deploy"

deploy_function() {
  gcloud functions deploy "$FUNCTION" \
    --gen2 --region="$REGION" --runtime=nodejs22 \
    --source="$(dirname "$0")/../regenerate-tree-function" \
    --entry-point=handler \
    --trigger-location="$TRIGGER_LOCATION" \
    --trigger-event-filters="type=google.cloud.firestore.document.v1.written" \
    --trigger-event-filters="database=(default)" \
    --trigger-event-filters-path-pattern="document=${ORDERS}/{layer}" \
    --timeout=540s \
    --memory=512Mi \
    --service-account="$SA_EMAIL" \
    --set-env-vars="RAW_PREFIX=raw/v=1/,BRONZE_PREFIX=bronze/v=1/,BUCKET=${BUCKET},FIRESTORE_PROJECT=${FIRESTORE_PROJECT},REGENERATE_COLLECTION=${ORDERS}"
}

if ! deploy_function; then
  echo ""
  echo "     El primer intento falló (típico: IAM recién creada aún propagando)."
  echo "     Reintento en 90 segundos…"
  sleep 90
  deploy_function
fi

# El disparador INVOCA el servicio con esta identidad, y el permiso se da por
# SERVICIO: tenerlo en la función del índice no alcanza. Sin esto el deploy
# sale bien, el evento se entrega… y muere en 403 'run.routes.invoke',
# reintentando en silencio.
gcloud run services add-iam-policy-binding "$FUNCTION" \
  --region="$REGION" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/run.invoker" >/dev/null

# ── Verificación ─────────────────────────────────────────────────────

echo ""
echo "LISTO. El botón de Config deja la orden; el trabajo ocurre acá."
echo ""
echo "Verla trabajar:"
echo "  gcloud functions logs read $FUNCTION --region=$REGION --limit=30"
echo ""
echo "Pedir una regeneración a mano (sin la app):"
echo "  gcloud firestore documents create-or-update ... o desde la consola:"
echo "  ${ORDERS}/bronze  →  { state: 'requested', requestedAt: <ahora> }"
