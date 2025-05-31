import jsony, std/typetraits, std/strutils, std/macros, std/sets, std/strformat

type
  Db* = distinct pointer ## Generic database pointer.
  DbError* = object of IOError ## Debby error.
  ## Debby Row type. Just a seq of strings.
  Row* = seq[string]
  ## Debby's binary datatype. Use this if your data contains nulls or non-utf8 bytes.
  Bytes* = distinct string

const ReservedNames* = [
  "select", "insert", "update", "delete", "from", "where", "join", "inner", "outer",
  "left", "right", "on", "group", "by", "order", "having", "limit", "offset", "union",
  "create", "alter", "drop", "set", "null", "not", "distinct", "as", "is", "like",
  "and", "or", "in", "exists", "any", "all", "between", "asc", "desc", "case", "when",
  "then", "else", "end", "some", "with", "table", "column", "value", "index", "primary",
  "foreign", "key", "default", "check", "unique", "constraint", "references", "varchar",
  "char", "text", "integer", "int", "smallint", "bigint", "decimal", "numeric", "float",
  "double", "real", "boolean", "date", "time", "timestamp", "user",
] ## Do not use these strings in your tables or column names.

const ReservedSet = toHashSet(ReservedNames)

proc toSnakeCase*(s: string): string =
  for c in s:
    if c.isUpperAscii():
      if len(result) > 0:
        result.add('_')
      result.add(c.toLowerAscii())
    else:
      result.add(c)

proc elemNames*[T](t: typedesc[T]): string =
  var tmp: seq[string]
  for name, field in t()[].fieldPairs:
    tmp.add name.toSnakeCase
  return tmp.join(", ")

proc tableName*[T](t: typedesc[T]): string =
  ## Converts object type name to table name.
  ($type(T)).toSnakeCase

proc dbError*(msg: string) {.noreturn.} =
  ## Raises a DbError with just a message.
  ## Does not query the database for error.
  raise newException(DbError, msg)

proc validateObj*[T: ref object](t: typedesc[T]) =
  let tmp = T()

  if T.tableName in ReservedSet:
    dbError(
      &"The '{T.tableName}' is a reserved word in SQL, please use a different name."
    )

  var foundId = false

  for name, field in tmp[].fieldPairs:
    if name == "id":
      foundId = true
      if typeof(distinctBase(field)) isNot int:
        dbError("Table's 'id' fields must be typed as 'int' or 'distinct int'.")

    let fieldName = name.toSnakeCase

    if fieldName in ReservedSet:
      dbError(
        &"The '{fieldName}' is a reserved word in SQL, please use a different name."
      )

  if not foundId:
    dbError("Table's must have primary key 'id: int' field.")

proc sqlDumpHook*[T: SomeFloat | SomeInteger](v: T): string =
  ## SQL dump hook for numbers.
  $v

proc sqlDumpHook*[T: string](v: T): string =
  ## SQL dump hook for strings.
  v

proc sqlDumpHook*[T: distinct](v: T): string =
  ## SQL dump hook for strings.
  sqlDumpHook(v.distinctBase)

proc sqlDumpHook*[T: enum](v: T): string =
  ## SQL dump hook for enums
  $v

proc sqlParseHook*[T: string](data: string, v: var T) =
  ## SQL parse hook to convert to a string.
  v = data

proc sqlParseHook*[T: SomeFloat](data: string, v: var T) =
  ## SQL parse hook to convert to any float.
  try:
    v = data.parseFloat()
  except:
    v = 0

proc sqlParseHook*[T: SomeUnsignedInt](data: string, v: var T) =
  ## SQL parse hook to convert to any integer.
  try:
    discard data.parseBiggestUInt(v)
  except:
    v = 0

proc sqlParseHook*[T: SomeSignedInt](data: string, v: var T) =
  ## SQL parse hook to convert to any integer.
  try:
    v = data.parseInt()
  except:
    v = 0

proc sqlParseHook*[T: enum](data: string, v: var T) =
  ## SQL parse hook to convert to any enum.
  try:
    v = parseEnum[T](data)
  except:
    discard # default enum value

proc sqlParseHook*[T: distinct](data: string, v: var T) =
  ## SQL parse distinct.
  sqlParseHook(data, v.distinctBase)

proc sqlParse*[T](data: string, v: var T) =
  ## SQL parse distinct.
  when compiles(sqlParseHook(data, v)):
    sqlParseHook(data, v)
  else:
    if data != "":
      v = data.fromJson(type(v))

type Argument* = object
  sqlType*: string
  value*: string

proc toArgument*[T](v: T): Argument =
  when compiles(sqlDumpHook(v)):
    result.value = sqlDumpHook(v)
  else:
    result.sqlType = "JSON"
    result.value = v.toJson()

proc get*[T, V](db: Db, t: typedesc[T], id: V): T =
  ## Gets the object by id.
  doAssert typeof(V) is typeof(t.id), "Types for id don't match"
  let res = db.query(
    t, "SELECT " & T.elemNames & " FROM " & T.tableName & " WHERE id = ?", id.int
  )
  if res.len == 1:
    return res[0]

proc update*[T: ref object](db: Db, obj: T) =
  ## Updates the row that corresponds to the object in the database.
  ## Makes sure the obj.id is set.
  var
    query = ""
    values: seq[Argument]
  query.add "UPDATE " & T.tableName & " SET\n"
  for name, field in obj[].fieldPairs:
    if name != "id":
      query.add "  " & name.toSnakeCase & " = ?,\n"
      values.add toArgument(field)
  query.removeSuffix(",\n")
  query.add "\nWHERE id = ?;"
  values.add toArgument(obj[].id.int)
  db.query(query, values)

proc delete*[T: ref object](db: Db, obj: T): int =
  ## Deletes the row that corresponds to the object from the data
  ## base. Makes sure the obj.id is set.
  db.query("DELETE FROM " & T.tableName & " WHERE id = ?;", obj.id.int)
  return db.changes()

proc delete*[T: ref object, U: int | distinct int](db: Db, t: typedesc[T], id: U): int =
  ## Deletes the row with the given id.
  db.query("DELETE FROM " & T.tableName & " WHERE id = ?;", id.int)
  return db.changes()

proc insertInner*[T: ref object](db: Db, obj: T, extra = ""): seq[Row] =
  ## Inserts the object into the database.
  if obj.id.int != 0:
    dbError("Trying to insert obj with .id != 0. Has it been already inserted?")

  var
    query = ""
    qs = ""
    values: seq[Argument]

  query.add "INSERT INTO " & T.tableName & " (\n"
  for name, field in obj[].fieldPairs:
    if name == "id" and typeof(field.distinctBase) is int:
      discard
    else:
      query.add "  " & name.toSnakeCase & ",\n"
      values.add toArgument(field)
      qs.add "?"
      qs.add ", "
  query.removeSuffix(",\n")
  qs.removeSuffix(", ")
  query.add "\n"
  query.add ") VALUES ("
  query.add qs
  query.add ")"
  query.add extra

  db.query(query, values)

template insert*[T: ref object](db: Db, objs: seq[T]) =
  ## Inserts a seq of objects into the database.
  for obj in objs:
    db.insert(obj)

template delete*[T: ref object](db: Db, objs: seq[T]): int =
  ## Deletes a seq of objects from the database.
  for obj in objs:
    result += db.delete(obj)

template delete*[T: ref object, U: int | distinct int](db: Db, t: typedesc[T], objs: seq[T]): int =
  ## Deletes a seq of ids from the database.
  for id in ids:
    result += db.delete(t, id.int)

template update*[T: ref object](db: Db, objs: seq[T]) =
  ## Updates a seq of objects into the database.
  for obj in objs:
    db.update(obj)

template upsert*[T: ref object](db: Db, obj: T) =
  ## Either updates or inserts a ref object into the database.
  ## Will read the inserted id back.
  if obj.id.int == 0:
    db.insert(obj)
  else:
    db.update(obj)

template upsert*[T: ref object](db: Db, objs: seq[T]) =
  ## Either updates or inserts a seq of object into the database.
  ## Will read the inserted id back for each object.
  for obj in objs:
    db.upsert(obj)

template createIndex*[T: ref object](db: Db, t: typedesc[T], params: varargs[string]) =
  ## Creates a index, errors out if it already exists.
  var params2: seq[string]
  for p in params:
    params2.add p.toSnakeCase
  db.query(db.createIndexStatement(t, false, params2))

template createIndexIfNotExists*[T: ref object](
    db: Db, t: typedesc[T], params: varargs[string]
) =
  ## Creates a index if it does not already exists.
  var params2: seq[string]
  for p in params:
    params2.add p.toSnakeCase
  db.query(db.createIndexStatement(t, true, params2))

# Filter macro is complex:

const allowed = @["!=", ">=", "<=", ">", "<", "and", "or", "not"]

proc findByStrVal(node: NimNode, s: string): NimNode =
  ## Walks all children nodes, looking for matching string value.
  if node.kind == nnkSym and node.strVal == s:
    return node
  for child in node.children:
    let n = child.findByStrVal(s)
    if n != nil:
      return n

proc walk(n: NimNode, params: var seq[NimNode]): string =
  ## Walks the Nim nodes and converts them from Nim to SQL expression.
  ## Values are removed and replaced with ? and then put in the params seq.
  ## it.model == model -> model = ?, [model]
  ## it.year >= a and it.year < b -> year>=? and year<?, [a, b]
  case n.kind
  of nnkSym:
    if n.strVal == "==":
      return "="
    elif n.strVal in allowed:
      return n.strVal
    else:
      params.add n
      return "?"
  of nnkHiddenDeref:
    return walk(n[0], params)
  of nnkHiddenStdConv:
    return walk(n[1], params)
  of nnkDotExpr:
    if n[0].repr() == "it":
      result.add repr(n[1]).toSnakeCase
    else:
      params.add n
      result.add "?"
  of nnkInfix:
    result.add "("
    result.add walk(n[1], params)
    let op = n[0].repr()
    if op == "==":
      result.add "="
    else:
      result.add op
    result.add walk(n[2], params)
    result.add ")"
  of nnkPrefix:
    result.add "("
    result.add n[0].repr()
    result.add walk(n[1], params)
    result.add ")"
  of nnkStmtListExpr:
    return walk(n[1], params)
  of nnkStrLit:
    params.add n
    return "?"
  of nnkIntLit:
    return n.repr()
  of nnkCall, nnkCommand:
    params.add n
    let itNode = n.findByStrVal("it")
    if itNode != nil:
      error("Cannot pass `it` to any calling functions", itNode)
    return "?"
  else:
    assert false, $n.kind & " not supported: " & n.treeRepr()

proc innerSelect*[T: ref object](
    db: Db, it: T, where: string, args: varargs[Argument, toArgument]
): seq[T] =
  ## Used by innerFilter to make the db.select call.
  let statement = "SELECT " & T.elemNames & " FROM " & T.tableName & " WHERE " & where
  db.query(T, statement, args)

macro innerFilter(db, it, expression: typed): untyped =
  ## Typed marco that makes the call to innerSelect
  var params: seq[NimNode]
  let clause = walk(expression, params)
  var call = nnkCall.newTree(newIdentNode("innerSelect"), db, it, newStrLitNode(clause))
  for param in params:
    call.add(param)
  return call

template filter*[T: ref object](db: Db, t: typedesc[T], expression: untyped): untyped =
  ## Filters type's table with a Nim like filter expression.
  ## db.filter(Auto, it.year > 1990)
  ## db.filter(Auto, it.make == "Ferrari" or it.make == "Lamborghini")
  ## db.filter(Auto, it.year >= startYear and it.year < endYear)

  block:
    # Inject the `it` into the expression.
    var it {.inject.}: T = T()
    # Pass the expression to a typed macro to convert it to SQL where clause.
    innerFilter(db, it, expression)

proc filter*[T](db: Db, t: typedesc[T]): seq[T] =
  ## Filter without a filter clause just returns everything.
  db.query(t, ("SELECT " & T.elemNames & " FROM " & T.tableName))

proc hexNibble*(ch: char): int =
  ## Encodes a hex char.
  case ch
  of '0' .. '9':
    return ch.ord - '0'.ord
  of 'a' .. 'f':
    return ch.ord - 'a'.ord + 10
  of 'A' .. 'F':
    return ch.ord - 'A'.ord + 10
  else:
    raise newException(DbError, "Invalid hexadecimal digit: " & $ch)

proc dropTable*[T](db: Db, t: typedesc[T]) =
  ## Removes tables, errors out if it does not exist.
  db.query("DROP TABLE " & T.tableName)

proc dropTableIfExists*[T](db: Db, t: typedesc[T]) =
  ## Removes tables if it exists.
  db.query("DROP TABLE IF EXISTS " & T.tableName)

proc createTable*[T: ref object](db: Db, t: typedesc[T]) =
  ## Creates a table, errors out if it already exists.
  db.query(db.createTableStatement(t))
