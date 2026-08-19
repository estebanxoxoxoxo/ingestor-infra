## VARIABLES SUGERIDAS:

[PROYECTO] sessions-ingest
[BUDGET NOMBRE] ingestor-budget
[SA] ingestor-writter
[SA2] index-writter
[REGIÓN] us-east1
[ZONA] us-east1-c 
[IP] ingestor-ip
[VM] ingestor-vm
[TIPO] e2-micro
[IMAGEN] debian-12
[TIPO-DISCO] pd-standard
[DISCO]  30GB
[FIREWALL] ingestor-firewall
[MI DOMINIO] El que se tenga disponible
[CUENTA FACTURACION] setear previamente en gcloud


## CREACIÓN Y SETEO DEL PROYECTO 
- Crear una cuenta de facturación de pago en gc, si todavia no se cuenta con una

En consola de firebase:
- Crear proyecto [PROYECTO]
- En configuracion crear una app web del mismo nombre. Esto crea por debajo el proyecto de Google Cloud. Anotar el ID final.
- Firestore Database → Crear base de datos: modo producción, ubicación nam5 (irreversible).
- Realtime Database → Crear base de datos: us-central1, modo bloqueado.
- Plan Blaze → elegir cuenta de facturación.
- Configuración del proyecto → Cuentas de servicio → Generar nueva clave privada → va al .env de la app.


## Verificación:
- gcloud billing projects describe [PROYECTO] --format="value(billingEnabled,billingAccountName)"

- Reglas de RTDB de firebase. Son dos bases con necesidades opuestas:
{ "rules": { "activeSessions": { "$conn": { ".write": true } } } }

- Fijar el proyecto
gcloud config set project [PROYECTO]

- Habilitar las APIs (cloudbuild, artifactregistry y eventarc incluidas: sin ellas el deploy de la función se traba)
gcloud services enable compute.googleapis.com storage.googleapis.com pubsub.googleapis.com run.googleapis.com cloudfunctions.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com eventarc.googleapis.com firestore.googleapis.com monitoring.googleapis.com cloudbilling.googleapis.com billingbudgets.googleapis.com bigquery.googleapis.com

- Facturación y presupuesto (el importe va en la moneda de la cuenta; el filtro acota el tope a ESTE proyecto)
gcloud billing accounts list

- gcloud billing projects link $(gcloud config get-value project) --billing-account=[CUENTA DE FACTURACIÓN]

- gcloud billing projects describe $(gcloud config get-value project) --format="value(billingEnabled,billingAccountName)"

- gcloud billing budgets list --billing-account=[CUENTA DE FACTURACIÓN] --format="table(displayName,amount.specifiedAmount.units,amount.specifiedAmount.currencyCode)"

- gcloud billing budgets create --billing-account=[CUENTA DE FACTURACIÓN] --display-name=[BUDGET NOMBRE] --budget-amount=5EUR --threshold-rule=percent=0.5 --threshold-rule=percent=1.0


## INSTALAR GCLOUD EN REPO INFRA-INGESTOR (Igual seguir utilizando gc console) 
- winget install Google.CloudSDK --include-unknown

- gcloud auth login

- gcloud config set project [PROYECTO]


## CREACIÓN DE SERVICE ACCOUNT PARA ESCRIBIR EL LAKE
- gcloud iam service-accounts create [SA] --display-name="[SA]"


## CREACIÓN DEL BUCKET
- gcloud storage buckets create gs://$(gcloud config get-value project)-lake --location=[REGION] --uniform-bucket-level-access --public-access-prevention

- gcloud storage buckets update gs://$(gcloud config get-value project)-lake --versioning

- gcloud storage buckets add-iam-policy-binding gs://$(gcloud config get-value project)-lake --member=serviceAccount:[SA]@$(gcloud config get-value project).iam.gserviceaccount.com --role=roles/storage.objectCreator

- gcloud storage buckets add-iam-policy-binding gs://$(gcloud config get-value project)-lake --member=serviceAccount:[SA]@$(gcloud config get-value project).iam.gserviceaccount.com --role=roles/storage.objectCreator

- gcloud storage buckets add-iam-policy-binding gs://$(gcloud config get-value project)-lake --member=serviceAccount:[SA]@$(gcloud config get-value project).iam.gserviceaccount.com --role=roles/storage.objectViewer


## OBTENCIÓN DE IP A USAR EN LA FUTURA VM
- Anotá la dirección: es la que va al DNS.
gcloud compute addresses create [IP] --region [REGION] && gcloud compute addresses describe [IP] --region [REGION] --format="value(address)"


## CHEQUEO SI QUEDAN SLOTS PARA FREE TIER EN LA CUENTA DE FACTURACIÓN
- Chequear el free tier — es por cuenta de facturación, no por proyecto. Si hay una e2 de x tipo corriendo ya no hay slot gratuito
for p in $(gcloud projects list --format="value(projectId)"); do echo "== $p"; gcloud compute instances list --project=$p --format="table(name,zone,machineType.basename(),status)" 2>/dev/null; done


## CREACIÓN DE LA VM
- Crear la VM
gcloud compute instances create [VM] --zone=[ZONA] --machine-type=[TIPO] --image-family=[IMAGEN] --image-project=debian-cloud --boot-disk-type=[TIPO-DISCO] --boot-disk-size=[DISCO] --address=$(gcloud compute addresses describe [IP] --region [REGION] --format="value(address)") --service-account=[SA]@$(gcloud config get-value project).iam.gserviceaccount.com --scopes=cloud-platform --tags=http-server,https-server --deletion-protection


## Verificación (tiene que devolver el tipo, tu IP fija, la service account, y pd-standard 30)
gcloud compute instances describe [VM] --zone=[ZONA] --format="value(machineType.basename(),networkInterfaces[0].accessConfigs[0].natIP,serviceAccounts[0].email)" && gcloud compute disks describe [VM] --zone=[ZONA] --format="value(type.basename(),sizeGb)"


## SETEO DE LA VM
- Abrir 80 y 443 (el 80 lo necesita Let's Encrypt para validar el certificado)
gcloud compute firewall-rules create [FIREWALL] --network=default --allow=tcp:80,tcp:443 --target-tags=http-server,https-server --source-ranges=0.0.0.0/0

- Barrido de huérfanos (silencio es OK)
gcloud compute disks list --filter="-users:*" --format="table(name,zone,sizeGb,type.basename())"

gcloud compute addresses list --filter="status!=IN_USE" --format="table(name,address,region,status)"

- Reloj en UTC y tope al journal (disco de 30 GB: que los logs no lo coman):
gcloud compute ssh [VM] --zone=[ZONA] --command="sudo timedatectl set-timezone UTC && echo 'SystemMaxUse=200M' | sudo tee -a /etc/systemd/journald.conf && sudo systemctl restart systemd-journald && date -u"

- Swap de 1 GB (la e2-micro tiene 1 GB de RAM y ninguna red de contención):
gcloud compute ssh [VM] --zone=[ZONA] --command="sudo fallocate -l 1G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab && free -m"

- Estado general:
gcloud compute ssh [VM] --zone=[ZONA] --command="timedatectl | head -3; echo '--- swap ---'; swapon --show; echo '--- disco ---'; df -h / | tail -1"


## INSTALACIONES DE LA VM
- Que la VM tenga gcloud (lo usa para bajar la config del bucket):
gcloud compute ssh [VM] --zone=[ZONA] --command="which gcloud || (curl -1sLf https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && echo 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list && sudo apt-get update && sudo apt-get install -y google-cloud-cli)"

- Instalar Redpanda Connect y su usuario de servicio (el directorio de estado lo crea la unidad sola):
gcloud compute ssh [VM] --zone=[ZONA] --command="curl -1sLf 'https://linux.pkg.redpanda.com/setup-redpanda.deb.sh' | sudo -E bash && sudo apt-get install -y redpanda-connect && sudo useradd --system --no-create-home --shell /usr/sbin/nologin redpanda-connect 2>/dev/null; redpanda-connect --version"


## DESPLIEGUE Y SETEO REDPANDA EN VM
- Config + unidad de systemd (el script hace lint, instala, habilita y reinicia):
npm run infra:connect

- Activo y escuchando sólo en loopback (así nace, no hay endurecimiento posterior):
gcloud compute ssh [VM] --zone=[ZONA] --command="systemctl is-active redpanda-connect; systemctl is-enabled redpanda-connect; ss -tlnp | grep 127.0.0.1:8080"

- Evento de prueba:
gcloud compute ssh [VM] --zone=[ZONA] --command="curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/v1/batch -H 'Content-Type: application/json' -d '{\"batch\":[{\"type\":\"page\",\"event\":\"prueba\",\"messageId\":\"test-1\",\"context\":{\"userAgent\":\"Mozilla/5.0 Chrome/145\"}}]}'"

- Que aterrizó en el lake — los dos sinks tardan hasta 10 minutos (period: 600s); raw sale como .log.gz, bronze como .parquet:
gcloud storage ls --recursive gs://[PROYECTO]-lake/raw/ gs://[PROYECTO]-lake/bronze/


## TLS
- Apuntar el registro A de [DOMINIO]a la IP de [IP], y comprobar:
nslookup [DOMINIO]

- Instalar Caddy (una vez):
gcloud compute ssh [VM]--zone=[ZONA] --command="sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list && sudo apt-get update && sudo apt-get install -y caddy && caddy version"

- Desplegar el Caddyfile desde el repo:
npm run deploy:caddy

- Activo y escuchando en 80 y 443:
gcloud compute ssh [VM] --zone=[ZONA] --command="systemctl is-active caddy; ss -tlnp | grep -E ':80|:443'"

- Certificado emitido (tiene que aparecer certificate obtained successfully):
gcloud compute ssh [VM] --zone=[ZONA] --command="journalctl -u caddy -n 30 --no-pager | grep -iE 'certificate|error'"

- El circuito completo por HTTPS — tiene que dar 200:
curl -s -o /dev/null -w '%{http_code}\n' -X POST [DOMINIO CON HTTPS]/v1/batch -H 'Content-Type: application/json' -d '{"batch":[{"type":"page","event":"prueba-e2e","messageId":"test-2","context":{"userAgent":"Mozilla/5.0 Chrome/145"}}]}'

- Cierre: tras el flush (hasta 10 min), el evento tiene que estar en el lake y su archivo anotado en Firestore — eso valida ingestor e índice de una sola vez:
gcloud storage ls --recursive gs://[PROYECTO]-lake/raw/ gs://[PROYECTO]-lake/bronze/


## PIPELINE GENERADOR DEL ÍNDICE DE CARPETAS DEL BUCKET PARA QUE LA APP MONITOR INSPECCIONE
- Notificación + serverless que escribe en firestore
npm run infra:indexPipeline

- Verificación:
gcloud functions describe [SA2] --gen2 --region=us-east1 --format="value(serviceConfig.serviceAccountEmail,serviceConfig.environmentVariables,eventTrigger.pubsubTopic)" && gcloud storage buckets notifications list gs://[PROYECTO]-lake

- Que el índice reaccionó solo: en Firebase Console → Firestore tiene que estar inventory/raw/days/<hoy>/files/<nombre>. Si no está:
gcloud functions logs read index-writer --region=[REGION] --limit=20
(Si los logs muestran 403 run.routes.invoke, volver a correr npm run infra:index — el script otorga el permiso y Pub/Sub reintenta solo.)

- Publicar DESDE EL REPO el contrato del parquet en el lake (documentación versionada):
$ gcloud storage cp redpanda-connect/bronze_v1.schema gs://[PROYECTO]-lake/schemas/1/bronze_v1.schema