#!/bin/bash
#
# ══════════════════════════════════════════════════════════════════════
#  Redpanda Connect: del repo a la instancia
# ══════════════════════════════════════════════════════════════════════
#
# Mismo circuito que tenía la config de Vector: repo → bucket → VM, con
# LINT antes de pisar nada. La VM baja con su propia identidad.
#
#   1. Sube connect.yaml y la unidad de systemd al bucket.
#   2. En la VM: baja a /tmp y corre `redpanda-connect lint`. Si no pasa,
#      corta y la config vigente queda intacta.
#   3. Instala config + unidad y REINICIA el servicio. El reinicio no pierde
#      nada: el buffer sqlite persiste y el 200 al SDK sólo se dio por
#      eventos ya escritos en él.
#
# USO
#
#   npm run infra:connect
#   VM=other-vm ZONE=us-central1-a npm run infra:connect
#
# REQUISITO PREVIO: el binario instalado en la VM y el usuario de servicio
# creado (pasos del plan de migración; el binario se busca en el PATH).
#
set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
if [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ]; then
  echo "No hay proyecto activo. Corré: gcloud config set project YOUR-PROJECT"
  exit 1
fi

BUCKET="${BUCKET:-${PROJECT}-lake}"
VM="${VM:-ingestor-vm}"
ZONE="${ZONE:-us-east1-c}"
CONFIG_DIR="$(dirname "$0")/../redpanda-connect"

echo "project=$PROJECT · bucket=$BUCKET · vm=$VM · zone=$ZONE"
echo ""

echo "1/3 · upload"
gcloud storage cp "$CONFIG_DIR/connect.yaml" "$CONFIG_DIR/redpanda-connect.service" \
  "gs://${BUCKET}/config/"

echo "2/3 · download + lint"
# La identidad de la VM tiene objectCreator para ESCRIBIR el lake; eso no le
# permite LEER su propia config del bucket. Se otorga acá (idempotente) para
# que una instalación desde cero no muera en la descarga.
VM_SA="$(gcloud compute instances describe "$VM" --zone="$ZONE" \
  --format="value(serviceAccounts[0].email)")"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${VM_SA}" --role="roles/storage.objectViewer" >/dev/null
gcloud compute ssh "$VM" --zone="$ZONE" --command="\
  sudo gcloud storage cp gs://${BUCKET}/config/connect.yaml /tmp/connect.yaml && \
  sudo gcloud storage cp gs://${BUCKET}/config/redpanda-connect.service /tmp/redpanda-connect.service && \
  redpanda-connect lint /tmp/connect.yaml && echo LINT_OK"

echo "3/3 · install + restart"
gcloud compute ssh "$VM" --zone="$ZONE" --command="\
  sudo install -D -m0644 /tmp/connect.yaml /etc/redpanda-connect/connect.yaml && \
  sudo install -D -m0644 /tmp/redpanda-connect.service /etc/systemd/system/redpanda-connect.service && \
  sudo systemctl daemon-reload && \
  sudo systemctl enable --now redpanda-connect >/dev/null 2>&1 && \
  sudo systemctl restart redpanda-connect && \
  sleep 3 && systemctl is-active redpanda-connect"

echo ""
echo "LISTO. Ingestor sirviendo con la config del repo."
echo ""
echo "Journal:"
echo "  gcloud compute ssh $VM --zone=$ZONE --command=\"journalctl -u redpanda-connect -n 30 --no-pager\""
