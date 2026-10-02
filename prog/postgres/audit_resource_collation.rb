# frozen_string_literal: true

require "csv"

# Audits a Postgres resource before it moves from Ubuntu 22.04 (glibc 2.35) to
# 26.04 (glibc 2.43). It checks every database for sort order on collations
# that are not proven to keep their order across that change, and for objects
# that store case-mapped values. It is fail-closed: anything it cannot check is
# reported for review, not passed as clean. Each verdict lists the actions it
# needs, most severe first (ACTIONS).
class Prog::Postgres::AuditResourceCollation < Prog::Base
  subject_is :postgres_resource

  # Lists every database. Its default is safe only when it is builtin, or libc
  # with locale C, POSIX, or C.* (case-insensitive, as Postgres compares them).
  # Anything else is unsafe, so a missing version field or a new provider
  # cannot pass as safe. The shared pg_database catalog also gives the default of
  # a database that does not allow connections. Its ctype is at risk unless it
  # is builtin or libc with ctype C or POSIX, and the ctype is C or POSIX even
  # for builtin, as text search and pg_trgm read datctype on every provider.
  # The ICU locale column was renamed in PG 17, hence the jsonb lookup.
  DATABASES_SQL = <<~SQL
    SELECT datname, datallowconn,
      NOT coalesce(datlocprovider='b' OR (datlocprovider='c' AND (lower(datcollate) IN ('c','posix') OR datcollate ILIKE 'c.%')), false) AS default_unsafe,
      datcollate,
      datlocprovider NOT IN ('b','c') OR datctype NOT IN ('C','POSIX') AS ctype_at_risk,
      datlocprovider, datctype,
      coalesce(to_jsonb(d)->>'datlocale', to_jsonb(d)->>'daticulocale') AS icu_locale
    FROM pg_database d
    ORDER BY datname;
  SQL

  # Lists a database's non-verified collations in use, then the indexes,
  # columns, domains, and other objects on them, largest index first. Index
  # rows on the default carry collation "default"; the default's own entry
  # comes from DATABASES_SQL. Postgres records every explicit COLLATE in
  # pg_depend, so a collation named only inside an expression (an index key or
  # predicate, a partition key, a constraint, a generated column) or by a range
  # or composite type is found too. Partitions are left out, so a partitioned
  # object counts once.
  DETAILS_SQL = <<~SQL
    WITH coll AS (
      SELECT oid, collname::text AS collname, collprovider::text AS provider, collcollate AS locale FROM pg_collation WHERE oid<>100
      UNION ALL
      SELECT 100, 'default', datlocprovider::text, datcollate FROM pg_database WHERE datname=current_database()
    ),
    risky AS (
      SELECT oid, collname FROM coll
      WHERE NOT coalesce(provider='b' OR (provider='c' AND (lower(locale) IN ('c','posix') OR locale ILIKE 'c.%')), false)
    ),
    dep AS (
      SELECT d.classid, d.objid, d.objsubid, d.refobjid AS coll, rel.relkind FROM pg_depend d
      LEFT JOIN pg_constraint con ON d.classid='pg_constraint'::regclass AND con.oid=d.objid
      LEFT JOIN pg_attrdef ad ON d.classid='pg_attrdef'::regclass AND ad.oid=d.objid
      LEFT JOIN pg_class rel ON rel.oid=CASE WHEN d.classid='pg_class'::regclass THEN d.objid ELSE coalesce(con.conrelid, ad.adrelid) END
      WHERE d.refclassid='pg_collation'::regclass AND d.refobjid IN (SELECT oid FROM risky)
        AND NOT coalesce(rel.relispartition AND NOT (d.classid='pg_class'::regclass AND rel.relkind='p' AND d.objsubid=0), false)
    ),
    idx AS (
      SELECT i.indexrelid, u.coll FROM pg_index i JOIN pg_class rel ON rel.oid=i.indexrelid
      JOIN pg_namespace n ON n.oid=rel.relnamespace JOIN LATERAL unnest(i.indcollation) u(coll) ON true
      WHERE NOT rel.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema')
        AND u.coll IN (SELECT oid FROM risky)
      UNION
      SELECT objid, coll FROM dep WHERE classid='pg_class'::regclass AND relkind IN ('i','I')
    ),
    col AS (
      SELECT a.attrelid, a.attname, a.attcollation AS coll FROM pg_attribute a
      JOIN pg_class rel ON rel.oid=a.attrelid JOIN pg_namespace n ON n.oid=rel.relnamespace
      WHERE a.attnum>0 AND NOT a.attisdropped AND rel.relkind IN ('r','m','p') AND NOT rel.relispartition
        AND n.nspname NOT IN ('pg_catalog','information_schema') AND a.attcollation IN (SELECT oid FROM risky WHERE oid<>100)
    ),
    dom AS (
      SELECT t.oid, t.typcollation AS coll FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
      WHERE t.typtype='d' AND n.nspname NOT IN ('pg_catalog','information_schema') AND t.typcollation IN (SELECT oid FROM risky WHERE oid<>100)
    ),
    other AS (
      SELECT dep.classid, dep.objid, dep.objsubid, dep.coll FROM dep
      LEFT JOIN pg_type t ON dep.classid='pg_type'::regclass AND t.oid=dep.objid
      WHERE NOT coalesce(dep.classid='pg_class'::regclass AND (dep.relkind IN ('i','I') OR (dep.objsubid>0 AND dep.relkind IN ('r','m','p'))), false)
        AND t.typtype IS DISTINCT FROM 'd'
    ),
    used AS (SELECT coll FROM idx UNION SELECT coll FROM col UNION SELECT coll FROM dom UNION SELECT coll FROM other)
    SELECT * FROM (
      SELECT 'collation', c.collname::text, c.collname::text, c.collprovider::text,
        CASE WHEN c.collprovider='i' THEN coalesce(to_jsonb(c)->>'colllocale', to_jsonb(c)->>'colliculocale') ELSE c.collcollate END,
        c.collctype, c.collisdeterministic, NULL::bool, NULL::bigint
      FROM pg_collation c WHERE c.oid IN (SELECT coll FROM used) AND c.oid<>100
      UNION ALL
      SELECT 'index', i.indexrelid::regclass::text, r.collname,
        NULL, NULL, NULL, NULL, x.indisunique, pg_relation_size(i.indexrelid)
      FROM idx i JOIN pg_index x ON x.indexrelid=i.indexrelid JOIN risky r ON r.oid=i.coll
      UNION ALL
      SELECT 'column', format('%s.%I', col.attrelid::regclass, col.attname), r.collname, NULL, NULL, NULL, NULL, NULL, NULL
      FROM col JOIN risky r ON r.oid=col.coll
      UNION ALL
      SELECT 'domain', dom.oid::regtype::text, r.collname, NULL, NULL, NULL, NULL, NULL, NULL
      FROM dom JOIN risky r ON r.oid=dom.coll
      UNION ALL
      SELECT 'object', pg_describe_object(o.classid, o.objid, o.objsubid), r.collname, NULL, NULL, NULL, NULL, NULL, NULL
      FROM other o JOIN risky r ON r.oid=o.coll
    ) d(kind, name, collname, provider, locale, ctype, deterministic, is_unique, size_bytes)
    ORDER BY array_position(ARRAY['collation','index','column','domain','object'], kind), size_bytes DESC NULLS LAST, name;
  SQL

  # Lists objects that store or index case-mapped values, with the source of
  # their case rules: "glibc" needs a data scan, "icu" a REINDEX. An index, a
  # generated column, a check constraint, a partition key, or a materialized
  # view is listed when its expression case-maps (lower, upper, initcap,
  # casefold, full text search, ILIKE, ~*, regex functions and classes), or
  # when it calls a function outside pg_catalog, which can case-map
  # internally. citext, pg_trgm, and tsvector are matched by type. An object's
  # collations are its own (index keys, the column) plus those of every column
  # it reads and every COLLATE it names, from pg_depend: lower(name) = 'x' as a
  # boolean key, or in a predicate, follows name's collation. Default (oid
  # 100) follows the database provider. Full text search, pg_trgm, and
  # tsvector also classify characters with the libc ctype (datctype) on every
  # provider, builtin included, so they are glibc when it is not C/POSIX. If
  # the sources differ, ICU wins, since a REINDEX also clears the glibc risk.
  # Objects on builtin or C/POSIX (ASCII) rules are left out.
  #
  # Single-quoted heredoc so the regex escapes reach Postgres. citext is matched
  # by typname, as the extension may be absent or outside search_path, and
  # through arrays and domains to any depth. An index is a citext one when a
  # key (a column, a cast, or an array element) or a column it reads is citext.
  CTYPE_SQL = <<~'SQL'
    WITH RECURSIVE citext_types(oid) AS (
      SELECT oid FROM pg_type WHERE typname = 'citext' AND typtype = 'b'
      UNION
      SELECT t.oid FROM pg_type t JOIN citext_types ct ON t.typbasetype = ct.oid OR (t.typelem = ct.oid AND t.typcategory = 'A')
    ),
    dflt AS (
      SELECT CASE WHEN datlocprovider = 'i' THEN 'icu'
                  WHEN datlocprovider = 'c' AND datctype NOT IN ('C', 'POSIX') THEN 'glibc' END AS source,
        CASE WHEN datctype NOT IN ('C', 'POSIX') THEN 'glibc' END AS ctype_source
      FROM pg_database WHERE datname = current_database()
    ),
    idx AS (
      SELECT i.indexrelid, i.indclass, pg_get_indexdef(i.indexrelid) AS def,
        array_remove(i.indcollation::oid[], 0::oid) AS colls
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE NOT c.relispartition
        AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace, 'pg_toast'::regnamespace)
    ),
    exprs AS (
      SELECT 'expression' AS kind, indexrelid::regclass::text AS object, 'pg_class'::regclass AS classid, indexrelid AS objid, def, colls
      FROM idx
      UNION ALL
      SELECT 'stored_column', format('%s.%I', a.attrelid::regclass, a.attname), 'pg_attrdef'::regclass, d.oid,
        pg_get_expr(d.adbin, d.adrelid), array_remove(ARRAY[a.attcollation], 0::oid)
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      WHERE a.attgenerated = 's' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
        AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace, 'pg_toast'::regnamespace)
      UNION ALL
      SELECT 'check_constraint',
        format('%s.%I', CASE WHEN con.conrelid <> 0 THEN con.conrelid::regclass::text ELSE con.contypid::regtype::text END, con.conname),
        'pg_constraint'::regclass, con.oid, pg_get_constraintdef(con.oid), array_remove(ARRAY[coalesce(t.typcollation, 0::oid)], 0::oid)
      FROM pg_constraint con LEFT JOIN pg_class c ON c.oid = con.conrelid LEFT JOIN pg_type t ON t.oid = con.contypid
      WHERE con.contype = 'c' AND NOT coalesce(c.relispartition, false)
        AND con.connamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
      UNION ALL
      SELECT 'partition_key', p.partrelid::regclass::text, 'pg_class'::regclass, p.partrelid, pg_get_partkeydef(p.partrelid),
        array_remove(p.partcollation::oid[], 0::oid)
      FROM pg_partitioned_table p JOIN pg_class c ON c.oid = p.partrelid
      WHERE c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
      UNION ALL
      SELECT 'materialized_view', c.oid::regclass::text, 'pg_rewrite'::regclass, r.oid, pg_get_viewdef(c.oid), '{}'
      FROM pg_class c JOIN pg_rewrite r ON r.ev_class = c.oid AND r.rulename = '_RETURN'
      WHERE c.relkind = 'm' AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
    ),
    objs AS (
      SELECT kind, object, classid, objid, colls, def ~* '\m(jsonb?_)?to_tsvector\s*\(' AS db_ctype
      FROM exprs e
      WHERE def ~* '\m(lower|upper|initcap|casefold|(jsonb?_)?to_tsvector|regexp_[a-z_]+)\s*\(|~~?\*|\[\[:|\\[wW]'
        OR EXISTS (
          SELECT 1 FROM pg_depend d JOIN pg_proc p ON p.oid = d.refobjid
          WHERE d.classid = e.classid AND d.objid = e.objid AND d.refclassid = 'pg_proc'::regclass
            AND p.pronamespace <> 'pg_catalog'::regnamespace)
      UNION ALL
      SELECT 'citext', indexrelid::regclass::text, 'pg_class'::regclass, indexrelid, colls, false
      FROM idx WHERE EXISTS (
          SELECT 1 FROM pg_attribute a WHERE a.attrelid = idx.indexrelid AND a.atttypid IN (SELECT oid FROM citext_types))
        OR EXISTS (
          SELECT 1 FROM pg_depend d JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
          WHERE d.classid = 'pg_class'::regclass AND d.objid = idx.indexrelid AND d.refclassid = 'pg_class'::regclass
            AND d.refobjsubid > 0 AND a.atttypid IN (SELECT oid FROM citext_types))
      UNION ALL
      SELECT 'pg_trgm', indexrelid::regclass::text, NULL, NULL, '{}', true
      FROM idx WHERE EXISTS (
        SELECT 1 FROM pg_opclass oc WHERE oc.oid = ANY(idx.indclass::oid[]) AND oc.opcname IN ('gin_trgm_ops', 'gist_trgm_ops'))
      UNION ALL
      SELECT 'stored_column', format('%s.%I', a.attrelid::regclass, a.attname), NULL, NULL, '{}', true
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
      WHERE a.atttypid = 'tsvector'::regtype AND c.relkind IN ('r', 'p') AND NOT c.relispartition AND a.attnum > 0 AND NOT a.attisdropped
        AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace, 'pg_toast'::regnamespace)
    ),
    sourced AS (
      SELECT o.kind, o.object,
        CASE WHEN u.coll = 100 THEN (SELECT source FROM dflt)
             WHEN pc.collprovider = 'i' THEN 'icu'
             WHEN pc.collprovider = 'c' AND pc.collctype NOT IN ('C', 'POSIX') THEN 'glibc' END AS source
      FROM objs o
      CROSS JOIN LATERAL (
        SELECT o.colls || ARRAY(
          SELECT a.attcollation FROM pg_depend d JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
          WHERE d.classid = o.classid AND d.objid = o.objid AND d.objsubid = 0 AND d.refclassid = 'pg_class'::regclass
            AND d.refobjsubid > 0 AND a.attcollation <> 0
          UNION
          SELECT d.refobjid FROM pg_depend d
          WHERE d.classid = o.classid AND d.objid = o.objid AND d.objsubid = 0 AND d.refclassid = 'pg_collation'::regclass) AS colls
      ) x
      CROSS JOIN LATERAL unnest(CASE WHEN o.db_ctype OR x.colls = '{}' THEN x.colls || 100::oid ELSE x.colls END) u(coll)
      LEFT JOIN pg_collation pc ON pc.oid = u.coll
      UNION ALL
      SELECT kind, object, (SELECT ctype_source FROM dflt) FROM objs WHERE db_ctype
    )
    SELECT kind, object, CASE WHEN bool_or(source = 'icu') THEN 'icu' ELSE 'glibc' END AS source
    FROM sourced GROUP BY kind, object HAVING bool_or(source IS NOT NULL)
    ORDER BY kind, object;
  SQL

  # Caps the object names kept per database, so the frame and log stay small.
  OBJECT_LIMIT = 50

  # Caps the databases named in a verdict, which lands in the strand's exitval.
  # The verdict still gives the totals, and the Clog line keeps every database.
  DATABASE_LIMIT = 20

  # libc locales in the ubuntu-2604 image, asserted by its build
  # (postgres-vm-images common/setup_base.sh). Their compiled LC_COLLATE data
  # and their strxfrm keys for every code point are identical from glibc 2.35
  # to 2.43, so a libc collation on them needs only REFRESH COLLATION VERSION.
  # Any other libc locale cannot load on the target, which blocks the move. A
  # locale added to the image needs the same proof before it joins this list.
  TARGET_LIBC_LOCALES = %w[C POSIX C.utf8 en_US.utf8].freeze

  # The actions a verdict can ask for, most severe first.
  ACTIONS = %w[blocker review reindex scan refresh].freeze

  frame_accessor :databases, :results

  def self.assemble(postgres_resource_id)
    Strand.create(prog: "Postgres::AuditResourceCollation", label: "start", stack: [{"subject_id" => postgres_resource_id}])
  end

  def before_run
    pop "postgres resource is gone" if postgres_resource.nil? || postgres_resource.destroying_set?
  end

  label def start
    register_deadline(nil, 15 * 60, page: false)
    hop_enumerate
  end

  # Each label run does at most one query, so a label stays well inside the
  # strand lease however many databases the resource has.
  label def enumerate
    databases =
      begin
        parse_databases(server.run_query(DATABASES_SQL))
      rescue Sshable::SshError => e
        pop_unreachable(e.stderr.lines.first.to_s.strip)
      end
    pop_unreachable("no databases returned") if databases.empty?

    # Two queries per database, each with a 60s statement timeout.
    register_deadline(nil, (5 + 2 * databases.size) * 60, allow_extension: true, page: false)
    self.databases = databases
    self.results = []
    hop_audit_details
  end

  label def audit_details
    self.results = results + [database_details(databases[results.size])]
    hop_audit_ctype
  end

  label def audit_ctype
    *done, current = results
    self.results = done + [current.merge(database_ctype(databases[done.size]))]
    hop_report if results.size == databases.size
    hop_audit_details
  end

  label def report
    flagged_databases = results.select { it["flagged"] }.map { it["name"] }
    unverified_databases = results.reject { it["details_verified"] && it["ctype_verified"] }.map { it["name"] }
    ctype_databases = results.reject { it["ctype_object_count"].zero? }.to_h do
      [it["name"], {"objects" => it["ctype_objects"], "total" => it["ctype_object_count"], "sources" => it["ctype_sources"]}]
    end
    details = results.select { it["details"] }.to_h { [it["name"], it["details"]] }
    actions = resource_actions(results, unverified_databases)
    flagged = !flagged_databases.empty? || !unverified_databases.empty?

    result = {databases: results, flagged_databases:, unverified_databases:, ctype_databases:, details:, actions:, flagged:}
    Clog.emit("postgres collation audit", {postgres_collation_audit: result.merge(resource: postgres_resource.ubid, project: UBID.from_uuidish(postgres_resource.project_id).to_s)})

    totals = {"flagged" => flagged_databases.size, "unverified" => unverified_databases.size, "ctype" => ctype_databases.size}
    if flagged
      pop({"msg" => "flagged", "flagged_databases" => flagged_databases.first(DATABASE_LIMIT), "unverified_databases" => unverified_databases.first(DATABASE_LIMIT),
           "ctype_databases" => ctype_databases.first(DATABASE_LIMIT).to_h, "details" => details.first(DATABASE_LIMIT).to_h, "database_totals" => totals, "actions" => actions})
    elsif !ctype_databases.empty?
      pop({"msg" => "ctype_review", "ctype_databases" => ctype_databases.first(DATABASE_LIMIT).to_h, "database_totals" => totals, "actions" => actions})
    else
      pop({"msg" => "clean"})
    end
  end

  def server
    @server ||= begin
      server = postgres_resource.representative_server
      pop({"msg" => "skipped", "reason" => "no representative server"}) unless server&.vm
      server
    end
  end

  # Describes one database's non-verified collations, each with the action it
  # needs, and the objects on them. The database is flagged when it has any: an
  # unsafe default (known from DATABASES_SQL) or a DETAILS_SQL row. Objects on a
  # "refresh" collation are left out: their order is unchanged, so there is
  # nothing to rebuild. A non-connectable database can only report its default,
  # and a failed query keeps the default but marks the database unverified.
  def database_details(database)
    collations = database["default_unsafe"] ? [default_collation(database)] : []
    return database_result(database, collations, []) unless database["connectable"]

    begin
      rows = CSV.parse(server.run_query(DETAILS_SQL, dbname: conninfo(database["name"])))
    rescue Sshable::SshError
      return database_result(database, collations, [], verified: false)
    end

    collation_rows, object_rows = rows.partition { it[0] == "collation" }
    collations += collation_rows.map do |_, name, _, provider, locale, ctype, deterministic|
      {"collation" => name, "provider" => provider, "locale" => locale, "ctype" => ctype, "deterministic" => deterministic == "t", "action" => collation_action(provider, [locale, ctype])}
    end
    action_for = collations.to_h { [it["collation"], it["action"]] }
    objects = object_rows.filter_map do |kind, name, collation, *, unique, size|
      next if action_for[collation] == "refresh"
      object = {"kind" => kind, "object" => name, "collation" => collation, "action" => action_for[collation]}
      (kind == "index") ? object.merge("unique" => unique == "t", "size_bytes" => size.to_i) : object
    end
    database_result(database, collations, objects)
  end

  def database_result(database, collations, objects, verified: true)
    result = {"name" => database["name"], "connectable" => database["connectable"], "flagged" => !collations.empty?, "details_verified" => verified}
    result["details"] = {"collations" => collations, "objects" => objects.first(OBJECT_LIMIT), "object_total" => objects.length} unless collations.empty?
    result
  end

  # Lists one database's case-mapping objects. It runs in every connectable
  # database, as an explicit ICU or libc collation can put an object at risk
  # where the database ctype is not. A failed query is unverified, and so is a
  # database it cannot connect to whose own ctype is at risk. template0 is
  # skipped, as it cannot hold user objects and its ctype is often C.UTF8, which
  # would flag nearly every cluster.
  def database_ctype(database)
    none = {"ctype_verified" => true, "ctype_objects" => [], "ctype_object_count" => 0, "ctype_sources" => {}}
    return none if database["name"] == "template0"
    return none.merge("ctype_verified" => !database["ctype_at_risk"]) unless database["connectable"]

    objects = CSV.parse(server.run_query(CTYPE_SQL, dbname: conninfo(database["name"]))).map { |kind, object, source| {"kind" => kind, "object" => object, "source" => source} }
    {"ctype_verified" => true, "ctype_objects" => objects.first(OBJECT_LIMIT), "ctype_object_count" => objects.length, "ctype_sources" => objects.map { it["source"] }.tally}
  rescue Sshable::SshError
    none.merge("ctype_verified" => false)
  end

  # The database default as a collation entry. Postgres does not allow a
  # nondeterministic default.
  def default_collation(database)
    locale = (database["provider"] == "i") ? database["icu_locale"] : database["default_collation"]
    {"collation" => "default", "provider" => database["provider"], "locale" => locale, "ctype" => database["ctype"], "deterministic" => true,
     "action" => collation_action(database["provider"], [database["default_collation"], database["ctype"]])}
  end

  # ICU brings its own sort and case tables, which move with the ICU version, so
  # an index on it needs a REINDEX. A libc collation is safe to refresh only if
  # every locale it names is on the target image.
  def collation_action(provider, locales)
    return "reindex" if provider == "i"
    (locales.compact.map { normalize_locale(it) } - TARGET_LIBC_LOCALES).empty? ? "refresh" : "blocker"
  end

  # Brings a glibc locale name to the form `locale -a` prints: the codeset is
  # lowercased without dashes, so en_US.UTF-8 and en_US.utf8 compare equal.
  def normalize_locale(name)
    base, codeset = name.split(".", 2)
    codeset ? "#{base}.#{codeset.downcase.delete("-")}" : base
  end

  def resource_actions(results, unverified_databases)
    actions = results.flat_map { |db| db.dig("details", "collations")&.map { it["action"] } || [] }
    actions += results.flat_map { it["ctype_sources"].keys }.map { (it == "icu") ? "reindex" : "scan" }
    actions << "review" unless unverified_databases.empty?
    ACTIONS & actions
  end

  # Maps the DATABASES_SQL rows to typed values, one hash per database. The
  # keys are strings, as the list is kept in the frame.
  def parse_databases(output)
    CSV.parse(output).map do |row|
      {"name" => row[0], "connectable" => row[1] == "t", "default_unsafe" => row[2] == "t", "default_collation" => row[3], "ctype_at_risk" => row[4] == "t",
       "provider" => row[5], "ctype" => row[6], "icu_locale" => row[7]}
    end
  end

  # psql reads a -d value that contains "=" or starts with a URI prefix as a
  # connection string. Database names are customer-controlled, so each one goes
  # in as a quoted conninfo value.
  def conninfo(dbname)
    "dbname='#{dbname.gsub(/[\\']/) { "\\#{it}" }}'"
  end

  def pop_unreachable(error)
    Clog.emit("postgres collation audit unreachable", {postgres_collation_audit: {resource: postgres_resource.ubid, error:}})
    pop({"msg" => "unreachable", "error" => error})
  end
end
