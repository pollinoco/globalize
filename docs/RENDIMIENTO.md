# Globalize 8.0 y Rails 8

Esta versión parte de Globalize 7.1.3 (Rails 7.0 hasta 8.1, Ruby 3.4) y corrige el comportamiento que más duele en un catálogo con dos idiomas (`es` → `en`, `en` → `es`).

## Qué estaba mal

Con fallbacks de más de un idioma, `where(title: "…")`, `order(:title)` y `exists?` hacían un `JOIN` a todas las filas de traducción y un `DISTINCT`. Un producto con español e inglés salía dos veces, `COUNT` se encarecía y el `ORDER BY` no tenía un idioma ganador: PostgreSQL ordenaba por cualquiera de las dos filas.

Otros fallos que se veían al leer o guardar:

- `cache_key` llamaba a `translation`, que **creaba** una traducción vacía del idioma actual si no existía. Esa fila podía guardarse después y cambiaba la clave de caché.
- `changed?` cargaba las traducciones con una consulta solo para saber si había cambios. Una fila que no está en memoria no puede estar sucia.
- `column_for_attribute("title")` no encontraba la columna porque los nombres traducidos son símbolos y Rails pasa strings. El tipo de la columna quedaba vacío.
- Leer un atributo sin traducción instanciaba un `Translation` nuevo por cada atributo, aunque el default fuera `NULL`.
- `validates :slug, uniqueness: { conditions: -> { … } }` no ejecutaba la lambda: `Relation#merge` no llama callables. Desde Rails 5 `:conditions` es un proc.
- Al cargar cada modelo se volvían a ignorar columnas ya ignoradas y se llamaba `reset_column_information` otra vez.
- `order("title ASC")` se mandaba tal cual a la tabla padre. En modelos cuya columna ya vive solo en `*_translations` (por ejemplo `ads.title`) esa SQL no tiene columna.

## Qué hace ahora

| Operación | SQL |
|---|---|
| `where(title: "x")`, `find_by`, `exists?` | `EXISTS` sobre los idiomas de fallback, en **una** fila de traducción. Varios atributos del mismo `where` se exigen en esa misma fila. |
| `where.not(title: "x")` | `NOT EXISTS`. El registro se excluye si **algún** idioma de la cadena tiene ese valor. |
| `order(:title)`, `order("title ASC")` | Subconsulta escalar: elige el primer idioma de la cadena con valor no nulo (`<> ''` solo si el modelo tiene `fallbacks_for_empty_translations`). |
| `distinct.order(:title)` | La misma subconsulta va también en el `SELECT`, como exige PostgreSQL. `pluck` devuelve solo las columnas pedidas. |
| `with_translations(:es)` y luego `where` | Sigue filtrando la fila ya unida. No se sustituye por `EXISTS`. |
| `select`, `pluck`, `group`, `calculate` | Siguen haciendo `JOIN`. Hacen falta las columnas en el `SELECT`. |
| `order("LOWER(title)")`, `order("p.title ASC")` | SQL libre: no se reescribe. |

`COUNT(*)` sobre un `where` traducido cuenta registros padre, no filas de traducción.

La unicidad, si hay un índice único que cubre el atributo más `locale` (y el `scope`) y el valor no cambió, no lanza el `SELECT`. Si el valor cambió, la consulta sigue y excluye al propio registro por la clave foránea, no por el id de la traducción.

## Cómo usarlo en la tienda

```ruby
# Listados: una consulta para todas las traducciones, no una por producto.
Product.includes(:translations).where(store_id: store.id)

# Búsqueda por slug o título. No hace falta with_translations.
Product.find_by(slug: params[:id])

# Orden por nombre, también junto a GROUP BY products.id.
Product.order(:title)
```

Índices que esta SQL usa de verdad:

- único `(producto_id, locale)` — ya está en `product_translations`
- único `(slug, locale)` — ya está
- índice de `title` si se filtra o se ordena por nombre

`Globalize.fallbacks` tiene que incluir el idioma actual. Si `es` solo apunta a `en`, Globalize no lee ni escribe español.

```ruby
Globalize.fallbacks = { es: %i[es en], en: %i[en es] }
```

## Qué no cambia

`with_translations` sigue siendo un `JOIN` explícito (y `DISTINCT` si pides más de un idioma). Sirve para recorrer las filas de traducción, no para filtrar el catálogo.

Los atributos traducidos que todavía tienen columna en la tabla padre se ignoran en esa tabla (`ignored_columns`) y se leen de la traducción. No hace falta volver a copiar el valor a la columna vieja.
