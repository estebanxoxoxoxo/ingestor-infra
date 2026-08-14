import { cloudEvent } from '@google-cloud/functions-framework'
import { Firestore } from '@google-cloud/firestore'
import { Storage } from '@google-cloud/storage'

/**
 * REGENERAR EL ÁRBOL EN LA BASE, del lado de Google.
 *
 * La app no hace este trabajo: sólo deja una orden en
 * `regenerateTree/{capa}` y cierra. Esta función se despierta con esa
 * escritura, recorre el bucket, compara contra el índice y escribe SÓLO la
 * diferencia — con la app cerrada, sin que la metadata del bucket viaje a
 * ninguna máquina.
 *
 * El mismo documento es el pedido y el estado: acá se va contando el
 * progreso (días revisados, días reparados, escrituras), así que la app lo
 * mira en vivo con una suscripción y no necesita preguntar nada.
 *
 * CÓMO SE ABARATA. Comparar día por día leyendo cada archivo del índice
 * cuesta una lectura por archivo — con años acumulados, decenas de miles por
 * corrida. Acá, para cada día se pide primero una AGREGACIÓN (contar +
 * sumar peso): UNA lectura que dice si ese día coincide con el bucket. Sólo
 * los días que no coinciden se abren archivo por archivo. Un lake sano se
 * revisa entero por una lectura por día.
 *
 * REGLA DE LA CARRERA con las notificaciones vivas: no se borra nada nacido
 * DESPUÉS de que arrancó el escaneo (la época viaja en el nombre del
 * archivo). Un archivo que aterrizó mientras esto corría no es un fantasma.
 *
 * Idempotente: el id de cada doc es el nombre del archivo, así que repetir
 * la corrida escribe lo mismo.
 */

const RAW_PREFIX = process.env.RAW_PREFIX ?? 'raw/v=1/'
const BRONZE_PREFIX = process.env.BRONZE_PREFIX ?? 'bronze/v=1/'
const INVENTORY = process.env.INVENTORY_COLLECTION ?? 'inventory'
const ORDERS = process.env.REGENERATE_COLLECTION ?? 'regenerateTree'
const SETTINGS = process.env.SETTINGS_COLLECTION ?? 'settings'
const LAKE_DOC = process.env.LAKE_SETTINGS_DOC ?? 'lake'
const BUCKET = process.env.BUCKET ?? ''
const DATE_KEY = process.env.DATE_PARTITION_KEY ?? 'dt'

const firestore = new Firestore({ projectId: process.env.FIRESTORE_PROJECT })
const storage = new Storage()

const prefixOf = (layer) => (layer === 'raw' ? RAW_PREFIX : BRONZE_PREFIX)
const DAY_RE = new RegExp(`${DATE_KEY}=(\\d{4}-\\d{2}-\\d{2})/`)
const baseName = (key) => key.slice(key.lastIndexOf('/') + 1)

/** La época con que el ingestor bautiza cada archivo, en milisegundos. */
function instantOf(name, updated) {
  const epoch = name.match(/^(\d{10})\D/)
  if (epoch) return Number(epoch[1]) * 1000
  return updated ? Date.parse(updated) : 0
}

/** Un id de documento válido. */
const docIdSafe = (name) =>
  name.length > 0 && name.length < 1000 && !name.includes('/') && name !== '.' && name !== '..'

cloudEvent('handler', async (event) => {
  // El path del documento viene en el evento; de ahí sale la capa.
  const subject = event.subject ?? ''
  const layer = subject.match(new RegExp(`${ORDERS}/(raw|bronze)`))?.[1]
  if (!layer) return

  const orderRef = firestore.collection(ORDERS).doc(layer)
  const order = (await orderRef.get()).data() ?? {}

  // Sólo se actúa sobre un pedido nuevo. Como el primer paso es pasar a
  // 'running', las escrituras de progreso de esta misma función no la
  // vuelven a disparar.
  if (order.state !== 'requested') return

  await orderRef.set(
    {
      state: 'running',
      startedAt: new Date().toISOString(),
      daysTotal: 0,
      daysDone: 0,
      daysRepaired: 0,
      writes: 0,
      error: null,
    },
    { merge: true },
  )

  try {
    const summary = await regenerate(layer)
    await orderRef.set(
      { state: 'done', finishedAt: new Date().toISOString(), ...summary },
      { merge: true },
    )
  } catch (error) {
    await orderRef.set(
      {
        state: 'error',
        finishedAt: new Date().toISOString(),
        error: error instanceof Error ? error.message : String(error),
      },
      { merge: true },
    )
    throw error
  }
})

async function regenerate(layer) {
  const scanStartMs = Date.now()
  const startDay = await readStartDay()

  // (1) El bucket, de una sola pasada: una operación de listado por cada mil
  // objetos, agrupados por día acá mismo.
  const byDay = await listByDay(layer, startDay)

  // (2) Los días que el índice cree tener: si un día quedó sin archivos en
  // el bucket, hay que borrarlo igual.
  const markers = await firestore
    .collection(INVENTORY)
    .doc(layer)
    .collection('days')
    .listDocuments()
  for (const marker of markers) {
    if (startDay && marker.id < startDay) continue
    if (!byDay.has(marker.id)) byDay.set(marker.id, [])
  }

  const days = [...byDay.keys()].sort()
  const orderRef = firestore.collection(ORDERS).doc(layer)
  await orderRef.set({ daysTotal: days.length }, { merge: true })

  let daysDone = 0
  let daysRepaired = 0
  let writes = 0

  for (const day of days) {
    const fresh = byDay.get(day) ?? []
    // (3) UNA lectura para saber si el día está sano.
    if (await dayMatches(layer, day, fresh)) {
      daysDone += 1
      continue
    }
    // (4) Sólo los días que no coinciden se abren archivo por archivo.
    writes += await repairDay(layer, day, fresh, scanStartMs)
    daysDone += 1
    daysRepaired += 1
    await orderRef.set({ daysDone, daysRepaired, writes }, { merge: true })
  }

  return { daysTotal: days.length, daysDone, daysRepaired, writes }
}

/** El día de inicio del lake declarado en settings, o null. */
async function readStartDay() {
  const snap = await firestore.collection(SETTINGS).doc(LAKE_DOC).get()
  const value = snap.exists ? snap.data()?.startDay : null
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : null
}

/** Todo el prefijo de la capa, agrupado por partición diaria. */
async function listByDay(layer, startDay) {
  const byDay = new Map()
  const [files] = await storage.bucket(BUCKET).getFiles({ prefix: prefixOf(layer) })
  for (const file of files) {
    const size = Number(file.metadata?.size ?? 0)
    if (size === 0) continue // carpetas y objetos vacíos no son archivos
    const day = file.name.match(DAY_RE)?.[1]
    if (!day || (startDay && day < startDay)) continue
    const list = byDay.get(day) ?? []
    list.push({
      name: baseName(file.name),
      size,
      lastModified: file.metadata?.timeCreated ?? null,
    })
    byDay.set(day, list)
  }
  return byDay
}

/**
 * ¿El índice de ese día dice lo mismo que el bucket? Una agregación: dos
 * números, una lectura, sin abrir un solo documento.
 */
async function dayMatches(layer, day, fresh) {
  const snap = await filesCol(layer, day)
    .aggregate({
      files: Firestore.AggregateField.count(),
      bytes: Firestore.AggregateField.sum('size'),
    })
    .get()
  const totals = snap.data()
  const bytes = fresh.reduce((sum, file) => sum + file.size, 0)
  return Number(totals.files ?? 0) === fresh.length && Number(totals.bytes ?? 0) === bytes
}

/** El día no coincide: se lee entero, se calcula el diff y se escribe. */
async function repairDay(layer, day, fresh, scanStartMs) {
  const snap = await filesCol(layer, day).get()
  const stored = new Map(
    snap.docs.map((doc) => [doc.id, { size: Number(doc.data().size ?? 0) }]),
  )
  const now = new Set(fresh.map((file) => file.name))

  const upserts = fresh.filter((file) => stored.get(file.name)?.size !== file.size)
  const removals = [...stored.keys()].filter((name) => {
    if (now.has(name)) return false
    // Nacido después de que arrancó el escaneo: no es un fantasma.
    const instant = instantOf(name, null)
    return instant === 0 || instant < scanStartMs
  })

  if (upserts.length === 0 && removals.length === 0 && fresh.length > 0) return 0

  const writer = firestore.bulkWriter()
  let firstError = null
  writer.onWriteError((error) => {
    if (error.failedAttempts < 3) return true
    firstError ??= error
    return false
  })
  const enqueue = (write) => void write.catch(() => {})

  const dayRef = dayDoc(layer, day)
  for (const file of upserts) {
    if (!docIdSafe(file.name)) continue
    enqueue(
      dayRef
        .collection('files')
        .doc(file.name)
        .set({ size: file.size, lastModified: file.lastModified }),
    )
  }
  for (const name of removals) {
    if (!docIdSafe(name)) continue
    enqueue(dayRef.collection('files').doc(name).delete())
  }
  if (fresh.length === 0) {
    enqueue(dayRef.delete()) // día vacío: se va también su marcador
  } else if (upserts.length > 0) {
    enqueue(dayRef.set({}, { merge: true }))
  }

  await writer.close()
  if (firstError) throw firstError
  return upserts.length + removals.length
}

const dayDoc = (layer, day) =>
  firestore.collection(INVENTORY).doc(layer).collection('days').doc(day)

const filesCol = (layer, day) => dayDoc(layer, day).collection('files')
