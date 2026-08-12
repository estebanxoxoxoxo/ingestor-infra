import { cloudEvent } from '@google-cloud/functions-framework'
import { Firestore } from '@google-cloud/firestore'

/**
 * GCS → Firestore: el índice del bucket se mantiene solo, con la app cerrada.
 *
 * Cada objeto que aterriza en `raw/` o `bronze/` deja su doc de metadata en
 * `inventory/{capa}/days/{día}/files/{nombre}`; cada borrado lo saca. SÓLO
 * hechos que la notificación ya trae (nombre, tamaño, fecha): nada derivado —
 * los totales se piden con agregaciones al leer.
 *
 * Idempotente por diseño: el id del doc es el nombre del archivo, así que una
 * notificación repetida (Pub/Sub entrega "al menos una vez") escribe lo mismo.
 * Si Firestore falla, se lanza el error y Pub/Sub reintenta.
 *
 * Sin credenciales: corre con su propia service account y toma el token del
 * entorno.
 */

/**
 * Todo lo que la función necesita saber viaja por el ENTORNO, puesto en el
 * deploy (`--set-env-vars`). Las variables del script de despliegue no llegan
 * hasta acá: viven sólo mientras corre el script.
 */
const RAW_PREFIX = process.env.RAW_PREFIX ?? 'raw/v=1/'
const BRONZE_PREFIX = process.env.BRONZE_PREFIX ?? 'bronze/v=1/'
const INVENTORY = process.env.INVENTORY_COLLECTION ?? 'inventory'
/** Bucket esperado: si otro publicara en el mismo tópico, no se indexa. */
const BUCKET = process.env.BUCKET ?? ''
/**
 * Proyecto del Firestore a escribir. Sin esto, el cliente usa el proyecto
 * donde está desplegada la función — correcto sólo si la base vive ahí mismo.
 */
const FIRESTORE_PROJECT = process.env.FIRESTORE_PROJECT ?? ''

const db = new Firestore(FIRESTORE_PROJECT ? { projectId: FIRESTORE_PROJECT } : {})

const layerOf = (key) =>
  key.startsWith(RAW_PREFIX) ? 'raw' : key.startsWith(BRONZE_PREFIX) ? 'bronze' : null

/** La key de un objeto se parte en las tres piezas del índice. */
function partsOf(key) {
  const layer = layerOf(key)
  if (!layer) return null
  const day = key.match(/dt=(\d{4}-\d{2}-\d{2})\//)?.[1]
  if (!day) return null
  const name = key.slice(key.lastIndexOf('/') + 1)
  // Un nombre vacío es la "carpeta" que crea la consola: no es un archivo.
  if (!name) return null
  return { layer, day, name }
}

cloudEvent('handler', async (event) => {
  const message = event.data?.message
  if (!message) return

  // La notificación de GCS trae lo importante en los atributos; el cuerpo es
  // la metadata completa del objeto.
  const attributes = message.attributes ?? {}
  const key = attributes.objectId ?? ''
  const eventType = attributes.eventType ?? ''

  if (BUCKET && attributes.bucketId !== BUCKET) return

  const parts = partsOf(key)
  if (!parts) return // fuera de las capas indexadas (schemas/, config/, errors/)

  const { layer, day, name } = parts
  const dayRef = db.collection(INVENTORY).doc(layer).collection('days').doc(day)
  const fileRef = dayRef.collection('files').doc(name)

  if (eventType === 'OBJECT_DELETE') {
    await fileRef.delete()
    return
  }

  if (eventType !== 'OBJECT_FINALIZE') return

  const metadata = message.data
    ? JSON.parse(Buffer.from(message.data, 'base64').toString('utf8'))
    : {}
  const size = Number(metadata.size ?? 0)
  if (!size) return // objeto de tamaño 0: no es data

  await Promise.all([
    fileRef.set({
      size,
      lastModified: metadata.timeCreated ?? metadata.updated ?? new Date().toISOString(),
    }),
    // El marcador del día: doc vacío que hace que el día "exista" en el árbol.
    dayRef.set({}, { merge: true }),
  ])
})
