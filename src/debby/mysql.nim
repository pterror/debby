import common, jsony, std/strutils, std/strformat, std/tables, std/macros,
    std/sets
export common, jsony

when defined(windows):
  const Lib = "(libmysql.dll|libmariadb.dll)"
elif defined(macosx):
  const Lib = "(libmysqlclient|libmariadbclient)(|.21|).dylib"
else:
  const Lib = "(libmysqlclient|libmariadbclient).so(|.21|)"

type
  PRES = pointer

  FIELD*{.final.} = object
    name*: cstring
  PFIELD* = ptr FIELD

{.push importc, cdecl, dynlib: Lib.}

proc mysql_init*(MySQL: DB): DB

proc mysql_error*(MySQL: DB): cstring

proc mysql_real_connect*(
  MySQL: DB,
  host: cstring,
  user: cstring,
  passwd: cstring,
  db: cstring,
  port: cuint,
  unix_socket: cstring,
  clientflag: int
): int

proc mysql_close*(sock: DB)

proc mysql_query*(MySQL: DB, q: cstring): cint

proc mysql_store_result*(MySQL: DB): PRES

proc mysql_num_rows*(res: PRES): uint64

proc mysql_num_fields*(res: PRES): cuint

proc mysql_fetch_row*(result: PRES): cstringArray

proc mysql_free_result*(result: PRES)

proc mysql_real_escape_string*(MySQL: DB, fto: cstring, `from`: cstring, len: int): int

proc mysql_insert_id*(MySQL: DB): uint64

proc mysql_fetch_field_direct*(res: PRES, fieldnr: cuint): PFIELD

{.pop.}

proc dbError*(db: Db) {.noreturn.} =
  ## Raises an error from the database.
  raise newException(DbError, "MySQL: " & $mysql_error(db))

proc sqlType(t: typedesc): string =
  ## Converts nim type to sql type.
  when t is string: "text"
  elif t is Bytes: "text"
  elif t is int8: "tinyint"
  elif t is uint8: "tinyint unsigned"
  elif t is int16: "smallint"
  elif t is uint16: "smallint unsigned"
  elif t is int32: "int"
  elif t is uint32: "int unsigned"
  elif t is int or t is int64: "bigint"
  elif t is uint or t is uint64: "bigint unsigned"
  elif t is float or t is float32: "float"
  elif t is float64: "double"
  elif t is bool: "boolean"
  elif t is enum: "text"
  else: "json"

proc prepareQuery(
  db: DB,
  query: string,
  args: varargs[Argument, toArgument]
): string =
  ## Generates the query based on parameters.
  when defined(debbyShowSql):
    debugEcho(query)

  if query.count('?') != args.len:
    dbError("Number of arguments and number of ? in query does not match")

  var argNum = 0
  for c in query:
    if c == '?':
      let arg = args[argNum]
      # This is a bit hacky, I am open to suggestions.
      # mySQL does not take JSON in the query
      # It must be CAST AS JSON.
      if arg.sqlType != "":
        result.add "CAST("
      result.add "'"
      var escapedArg = newString(arg.value.len * 2 + 1)
      let newLen = mysql_real_escape_string(
        db,
        escapedArg.cstring,
        arg.value.cstring,
        arg.value.len.int32
      )
      escapedArg.setLen(newLen)
      result.add escapedArg
      result.add "'"
      if arg.sqlType != "":
        result.add " AS " & arg.sqlType & ")"
      inc argNum
    else:
      result.add c

proc readRow(res: PRES, r: var seq[string], columnCount: int) =
  ## Reads a single row back.
  var row = mysql_fetch_row(res)
  for column in 0 ..< columnCount:
    r[column] = $row[column]

proc query*(
  db: DB,
  query: string,
  args: varargs[Argument, toArgument]
): seq[Row] {.discardable.} =
  ## Runs a query and returns the results.
  var sql = prepareQuery(db, query, args)
  if mysql_query(db, sql.cstring) != 0:
    dbError(db)
  var res = mysql_store_result(db)
  if res != nil:
    var rowCount = mysql_num_rows(res).int
    var columnCount = mysql_num_fields(res).int
    try:
      for i in 0 ..< rowCount:
        var row = newSeq[string](columnCount)
        readRow(res, row, columnCount)
        result.add(row)
    finally:
      mysql_free_result(res)

proc openDatabase*(
    database: string,
    host = "localhost",
    port = 3306,
    user = "root",
    password = ""
): DB =
  ## Opens a database connection.
  var db = mysql_init(cast[Db](nil))
  if cast[pointer](db) == nil:
    dbError("could not open database connection")

  if mysql_real_connect(
    db,
    host.cstring,
    user.cstring,
    password.cstring,
    database.cstring,
    port.cuint,
    nil,
    0
  ) == 0:
    dbError(db)

  db.query("SET sql_mode='ANSI_QUOTES'")

  return db

proc close*(db: DB) =
  ## Closes the database connection.
  mysql_close(db)

proc tableExists*[T](db: Db, t: typedesc[T]): bool =
  ## Checks if table exists.
  for row in db.query(&"""SELECT
    table_name
FROM
    information_schema.tables
WHERE
    table_schema = DATABASE()
    AND table_name = '{T.tableName}';
"""):
    result = true
    break

proc createIndexStatement*[T: ref object](
  db: Db,
  t: typedesc[T],
  ifNotExists: bool,
  params: varargs[string]
): string =
  ## Returns the SQL code need to create an index.
  result.add "CREATE INDEX "
  if ifNotExists:
    result.add "IF NOT EXISTS "
  result.add "idx_"
  result.add T.tableName
  result.add "_"
  result.add params.join("_")
  result.add " ON "
  result.add T.tableName
  result.add " ("
  result.add params.join(", ")
  result.add ")"

proc createTableStatement*[T: ref object](db: Db, t: typedesc[T]): string =
  ## Given an object creates its table create statement.
  validateObj(T)
  let tmp = T()
  result.add "CREATE TABLE "
  result.add T.tableName
  result.add " (\n"
  for name, field in tmp[].fieldPairs:
    result.add "  "
    result.add name.toSnakeCase
    result.add " "
    result.add sqlType(type(field))
    if name == "id":
      result.add " PRIMARY KEY AUTO_INCREMENT"
    result.add ",\n"
  result.removeSuffix(",\n")
  result.add "\n)"

proc checkTable*[T: ref object](db: Db, t: typedesc[T]) =
  ## Checks to see if table matches the object.
  ## And recommends to create whole table or alter it.
  let tmp = T()
  var issues: seq[string]

  if not db.tableExists(T):
    when defined(debbyYOLO):
      db.createTable(T)
    else:
      issues.add "Table " & T.tableName & " does not exist."
      issues.add "Create it with:"
      issues.add db.createTableStatement(t)
  else:
    var tableSchema: Table[string, string]
    for row in db.query(&"""SELECT
      COLUMN_NAME,
      DATA_TYPE
    FROM
      INFORMATION_SCHEMA.COLUMNS
    WHERE
      TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = '{T.tableName}';
    """):
      let
        fieldName = row[0]
        fieldType = row[1]
      tableSchema[fieldName] = fieldType

    for fieldName, field in tmp[].fieldPairs:
      let sqlType = sqlType(type(field))

      if fieldName.toSnakeCase in tableSchema:
        if tableSchema[fieldName.toSnakeCase] == sqlType:
          discard # good everything matches
        else:
          issues.add "Field " & T.tableName & "." & fieldName & " expected type " & sqlType & " but got " & tableSchema[fieldName]
          # TODO create new table with right data
          # copy old data into new table
          # delete old table
          # rename new table
      else:
        let addFieldStatement = "ALTER TABLE " & T.tableName & " ADD COLUMN " & fieldName.toSnakeCase & " "  & sqlType & ";"
        if defined(debbyYOLO):
          db.query(addFieldStatement)
        else:
          issues.add "Field " & T.tableName & "." & fieldName & " is missing"
          issues.add "Add it with:"
          issues.add addFieldStatement

  if issues.len != 0:
    issues.add "Or compile --d:debbyYOLO to do this automatically"
    raise newException(DBError, issues.join("\n"))

proc insert*[T: ref object](db: Db, obj: T) =
  ## Inserts the object into the database.
  ## Reads the ID of the inserted ref object back.
  discard db.insertInner(obj)
  obj.id = typeof(obj.id)(mysql_insert_id(db).int)

proc query*[T](
  db: Db,
  t: typedesc[T],
  query: string,
  args: varargs[Argument, toArgument]
): seq[T] =
  ## Query the table, and returns results as a seq of ref objects.
  ## This will match fields to column names.
  ## This will also use JSONy for complex fields.
  let tmp = T()

  var
    sql = prepareQuery(db, query, args)

  if mysql_query(db, sql.cstring) != 0:
    dbError(db)

  var res = mysql_store_result(db)
  if res != nil:

    var rowCount = mysql_num_rows(res).int
    var columnCount = mysql_num_fields(res).int
    var headerIndex: seq[int]

    for i in 0 ..< columnCount:
      let field = mysql_fetch_field_direct(res, i.cuint)
      if field == nil:
        dbError("Field is nil")
      let columnName = $field[].name
      var
        j = 0
        found = false
      for fieldName, field in tmp[].fieldPairs:
        if columnName == fieldName.toSnakeCase:
          found = true
          headerIndex.add(j)
          break
        inc j
      if not found:
        raise newException(
          DBError,
          "Can't map query to object, missing " & $columnName
        )

    try:
      for j in 0 ..< rowCount:
        var row = newSeq[string](columnCount)
        readRow(res, row, columnCount)
        let tmp = T()
        var i = 0
        for fieldName, field in tmp[].fieldPairs:
          sqlParse(row[headerIndex[i]], field)
          inc i
        result.add(tmp)
    finally:
      mysql_free_result(res)

template withTransaction*(db: Db, body) =
  ## Transaction block.

  # Start a transaction
  discard db.query("START TRANSACTION;")

  try:
    body

    # Commit the transaction
    discard db.query("COMMIT;")
  except Exception as e:
    discard db.query("ROLLBACK;")
    raise e

proc sqlDumpHook*(v: bool): string =
  ## SQL dump hook to convert from bool.
  if v: "1"
  else: "0"

proc sqlParseHook*(data: string, v: var bool) =
  ## SQL parse hook to convert to bool.
  v = data == "1"

proc sqlDumpHook*(data: Bytes): string =
  ## MySQL-specific dump hook for binary data.
  let hexChars = "0123456789abcdef"
  var hexStr = "\\x"
  for ch in data.string:
    let code = ch.ord
    hexStr.add hexChars[code shr 4]  # Dividing by 16
    hexStr.add hexChars[code and 0x0F]  # Modulo operation with 16
  return hexStr

proc sqlParseHook*(data: string, v: var Bytes) =
  ## MySQL-specific parse hook for binary data.
  if not (data.len >= 2 and data[0] == '\\' and data[1] == 'x'):
    raise newException(DbError, "Invalid binary representation" )
  var buffer = ""
  for i in countup(2, data.len - 1, 2):  # Parse the hexadecimal characters two at a time
    let highNibble = hexNibble(data[i])  # Extract the high nibble
    let lowNibble = hexNibble(data[i + 1])  # Extract the low nibble
    let byte = (highNibble shl 4) or lowNibble  # Convert the high and low nibbles to a byte
    buffer.add chr(byte)  # Convert the byte to a character and append it to the result string
  v = buffer.Bytes
