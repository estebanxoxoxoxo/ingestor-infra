# El contrato

Lo que esta plataforma escribe y lo que otros repos pueden leer. **Se declara
acá porque acá está quien lo crea**: las funciones son las que escriben
`inventory/`, así que la forma la manda esta plataforma y los lectores se
adaptan — no al revés.

Nada de esto lo protege un compilador: no hay import entre repos. Si cambia
algo de acá, hay que ir a los lectores. La lista de lectores está al final.

## 1 · Las capas y sus prefijos

```
raw     → raw/v=1/
bronze  → bronze/v=1/
```

Las escribe Redpanda Connect. Lo que caiga fuera de esos dos prefijos
(`schemas/`, `config/`) **no se indexa**: la notificación ni se genera.

## 2 · La partición diaria

```
…/dt=YYYY-MM-DD/…
```

La pone Connect con la hora UTC del **flush**, no la del evento. Consecuencia
buscada: no aparecen archivos tardíos en la carpeta de ayer.

## 3 · El nombre del archivo lleva su instante

```
1755432000-abc123.parquet
└────────┘
 época en segundos, 10 dígitos, seguida de un no-dígito
```

Lo usa `regenerate-tree-function` para la regla de la carrera: no borra nada
nacido **después** de que arrancó el escaneo. Y lo usan los lectores para
ordenar sin pedir metadata.

Si falta esa época, se cae a `lastModified`; si tampoco está, el instante es 0.

## 4 · El índice

```
inventory/{capa}/days/{día}                 ← marcador: doc VACÍO
inventory/{capa}/days/{día}/files/{nombre}  ← { size, lastModified }
```

| Campo | Tipo | Qué es |
|---|---|---|
| `size` | number | bytes. Nunca 0: un objeto de tamaño 0 no se indexa |
| `lastModified` | string ISO \| null | `timeCreated` del objeto |

**El id del doc es el nombre del archivo.** De ahí sale la idempotencia: una
notificación repetida (Pub/Sub entrega "al menos una vez") escribe lo mismo, y
la función del índice y la del remedio pueden pisarse sin hacer daño.

Un nombre sólo es id válido si no está vacío, mide menos de 1000 caracteres,
no contiene `/` y no es `.` ni `..`. Los que no cumplen se saltean.

Sólo hechos: **no hay totales guardados**. Contar archivos o sumar peso se
hace con una agregación al leer.

Quién escribe: `index-function` (en vivo) y `regenerate-tree-function` (el
remedio). Nadie más.

## 5 · La orden de regeneración

```
regenerateTree/{capa}
```

Un documento por capa que es **el pedido y el estado a la vez**. Por eso al
lector le alcanza con una suscripción: el progreso llega solo.

| Campo | Lo escribe | Valores |
|---|---|---|
| `state` | los dos | `requested` (el lector) · `running` `done` `error` (la función) |
| `requestedAt` | el lector | ISO |
| `startedAt` / `finishedAt` | la función | ISO |
| `daysTotal` / `daysDone` / `daysRepaired` / `writes` | la función | number |
| `error` | la función | string \| null |

Reglas que hay que respetar del lado del lector:

1. **Sólo `requested` dispara trabajo.** La función ignora cualquier otro
   estado — por eso sus propias escrituras de progreso no la vuelven a
   disparar.
2. **Poner el progreso en cero al pedir**, o la barra arranca mostrando el de
   la corrida anterior.
3. El disparador es una escritura sobre el documento; no hay endpoint HTTP ni
   autenticación aparte.

Se puede pedir sin ninguna app, desde la consola de Firestore:
`regenerateTree/bronze → { state: 'requested', requestedAt: <ahora> }`.

## 6 · Dónde empieza el lake

```
settings/lake → { startDay: 'YYYY-MM-DD' }
```

Lo lee `regenerate-tree-function`: los días anteriores no se regeneran ni se
borran. Sin el documento, se mira toda la historia.

Lo escribe quien tenga la UI de configuración — hoy `ingestor-monitor`. Es el
único campo de este contrato que la plataforma **lee** en vez de escribir.

---

## Lectores conocidos

| Repo | Qué consume | Dónde tiene su copia de los nombres |
|---|---|---|
| `ingestor-monitor` | 4 (lee), 5 (escribe el pedido, lee el progreso), 6 (escribe) | `src/shared/config.ts` |

Cuando aparezca otro, va en esta tabla. Es la lista de a quién avisarle.
