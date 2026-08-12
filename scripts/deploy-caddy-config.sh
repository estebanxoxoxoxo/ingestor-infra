#!/bin/bash
#
# ══════════════════════════════════════════════════════════════════════
#  Caddy: del repo a /etc/caddy/ de la instancia
# ══════════════════════════════════════════════════════════════════════
#
# Mismo circuito que la config de Vector: repo → bucket → VM, con validación
# antes de aplicar. Caddy recarga sin cortar conexiones.
#
# USO
#
#   npm run infra:caddy
#   VM=other-vm ZONE=us-central1-a npm run infra:caddy
#
# REQUISITO PREVIO
#
#   · Caddy instalado en la VM (ver paso 15 del plan de migración).
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
CONFIG_DIR="$(dirname "$0")/../caddy"

echo "project=$PROJECT · bucket=$BUCKET · vm=$VM · zone=$ZONE"
echo ""

echo "1/3 · upload"
gcloud storage cp "$CONFIG_DIR/Caddyfile" "gs://${BUCKET}/config/Caddyfile"

# Se baja a /tmp y se valida ahí: un Caddyfile roto no llega a pisar el que
# está sirviendo tráfico.
echo "2/3 · download + validate"
gcloud compute ssh "$VM" --zone="$ZONE" --command="\
  sudo gcloud storage cp gs://${BUCKET}/config/Caddyfile /tmp/Caddyfile && \
  sudo caddy validate --config /tmp/Caddyfile --adapter caddyfile"

# `reload` de Caddy cambia la config sin cortar conexiones en curso; si el
# servicio todavía no arrancó (primera vez), se lo inicia.
echo "3/3 · install + reload"
gcloud compute ssh "$VM" --zone="$ZONE" --command="\
  sudo install -D -m0644 /tmp/Caddyfile /etc/caddy/Caddyfile && \
  { systemctl is-active --quiet caddy && sudo systemctl reload caddy || sudo systemctl start caddy; } && \
  sleep 2 && systemctl is-active caddy"

echo ""
echo "LISTO. Caddy sirviendo con la config del repo."
echo ""
echo "El certificado se emite cuando el DNS apunte acá. Mientras tanto:"
echo "  gcloud compute ssh $VM --zone=$ZONE --command=\"journalctl -u caddy -n 20 --no-pager\""
