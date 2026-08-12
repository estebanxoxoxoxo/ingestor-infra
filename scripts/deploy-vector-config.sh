#!/bin/bash
#
# ══════════════════════════════════════════════════════════════════════
#  Config de Vector: del repo a /etc/vector/ de la instancia
# ══════════════════════════════════════════════════════════════════════
#
# QUÉ HACE
#
#   repo ──sube──> bucket/config/ ──baja──> VM:/etc/vector/ ──> reload
#
#   El bucket es el intermediario a propósito: la VM baja con su PROPIA
#   identidad, así no hay que copiar archivos entre máquinas ni guardar
#   credenciales en ningún lado.
#
# ORDEN SEGURO
#
#   1. Sube los dos archivos al bucket.
#   2. Se asegura de que la VM pueda LEER el bucket (tiene objectCreator para
#      escribir el lake, y eso no alcanza para leer).
#   3. En la VM: baja el esquema a su lugar, baja la config a /tmp y la
#      VALIDA ahí. Si no valida, corta y no toca la config vigente.
#   4. Recién entonces instala la config y recarga en caliente: el listener
#      no se cae y ninguna request se pierde.
#
# IDEMPOTENTE: correrlo de nuevo publica la versión actual del repo.
#
# USO
#
#   npm run infra:vector
#   VM=other-vm ZONE=us-central1-a npm run infra:vector
#
# REQUISITOS PREVIOS
#
#   · La VM existe y tiene Vector instalado (ver infra/vector/README.md).
#   · /var/lib/vector existe y es del usuario vector.
#
set -euo pipefail

# ── Parámetros ───────────────────────────────────────────────────────

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
if [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ]; then
  echo "No hay proyecto activo. Corré: gcloud config set project YOUR-PROJECT"
  exit 1
fi

BUCKET="${BUCKET:-${PROJECT}-lake}"
VM="${VM:-ingestor-vm}"
ZONE="${ZONE:-us-east1-c}"

# La carpeta con los archivos, relativa a este script: no depende de dónde
# estés parado al invocarlo.
CONFIG_DIR="$(dirname "$0")/../vector"

echo "project=$PROJECT · bucket=$BUCKET"
echo "vm=$VM · zone=$ZONE"
echo ""

# ── 1. Publicar en el bucket ─────────────────────────────────────────

echo "1/4 · upload"
gcloud storage cp "$CONFIG_DIR/vector.yaml" "$CONFIG_DIR/bronze_v1.schema" \
  "gs://${BUCKET}/config/"

# ── 2. Permiso de lectura para la identidad de la VM ─────────────────
# La cuenta se lee de la propia instancia: un dato menos que mantener a mano.

echo "2/4 · read permission"
VM_SA="$(gcloud compute instances describe "$VM" --zone="$ZONE" \
  --format="value(serviceAccounts[0].email)")"
echo "     identidad de la VM: $VM_SA"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${VM_SA}" --role="roles/storage.objectViewer" >/dev/null

# ── 3. Bajar y VALIDAR antes de pisar nada ───────────────────────────
# El esquema va directo a su lugar porque la config lo referencia por ruta
# absoluta; la config se valida en /tmp y sólo se instala si pasa.

echo "3/4 · download + validate"
gcloud compute ssh "$VM" --zone="$ZONE" --command="\
  sudo gcloud storage cp gs://${BUCKET}/config/bronze_v1.schema /etc/vector/bronze_v1.schema && \
  sudo gcloud storage cp gs://${BUCKET}/config/vector.yaml /tmp/vector.yaml && \
  sudo vector validate /tmp/vector.yaml"

# ── 4. Instalar y recargar en caliente ───────────────────────────────

echo "4/4 · install + reload"
# `reload` sobre un servicio parado falla: la primera vez (o después de una
# config inválida) Vector todavía no está corriendo, así que hay que
# arrancarlo. De ahí en más, siempre reload: no corta el listener.
gcloud compute ssh "$VM" --zone="$ZONE" --command="\
  sudo install -D -m0644 /tmp/vector.yaml /etc/vector/vector.yaml && \
  { systemctl is-active --quiet vector && sudo systemctl reload vector || sudo systemctl start vector; } && \
  sleep 2 && systemctl is-active vector"

echo ""
echo "LISTO. Config aplicada sin cortar el listener."
echo ""
echo "Ver el journal:"
echo "  gcloud compute ssh $VM --zone=$ZONE --command=\"journalctl -u vector -n 30 --no-pager\""
