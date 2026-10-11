# owner-restamp.sh — move the osionos demo rows that an OLD api-key principal owns onto the
# app's current one, per engine, inside each engine's own container (docker exec; DOCKER_HOST
# picks the daemon). Sourced by scripts/ensure-live-data-access.sh, which sets the container
# names (*_CTN), the databases (*_DBS) and note(); this file defines functions only.
#
#   stale_pg|stale_mssql WANT     rows whose owner_id is api-key:* but not WANT
#   restamp_<engine> WANT         set those rows' owner_id to WANT; notes the count
#
# An engine whose container is not running counts 0 stale rows and is skipped on restamp.
# bash (process substitution); tested through scripts/tests/live-data.bats.

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# Any api-key:* principal in the demo data that is NOT the one we hold is
# stale: rows the app can authenticate for but never see.
stale_pg() {
	local want="$1" db n=0 t
	running "${PG_CTN}" || { printf '0'; return; }
	for db in ${PG_DBS}; do
		docker exec "${PG_CTN}" psql -U postgres -d "${db}" -tAc \
			"SELECT table_name FROM information_schema.columns
			  WHERE column_name='owner_id' AND table_schema='public';" 2>/dev/null \
		| while read -r t; do
			[ -n "${t}" ] || continue
			docker exec "${PG_CTN}" psql -U postgres -d "${db}" -tAc \
				"SELECT count(*) FROM public.\"${t}\"
				  WHERE owner_id LIKE 'api-key:%' AND owner_id <> '${want}';" 2>/dev/null
		done | awk '{s+=$1} END {print s+0}'
	done | awk '{s+=$1} END {print s+0}'
}

restamp_pg() {
	local want="$1" db t total=0 n
	running "${PG_CTN}" || { note "postgres not running — skipped"; return; }
	for db in ${PG_DBS}; do
		while read -r t; do
			[ -n "${t}" ] || continue
			n="$(docker exec "${PG_CTN}" psql -U postgres -d "${db}" -tAc \
				"UPDATE public.\"${t}\" SET owner_id='${want}'
				  WHERE owner_id LIKE 'api-key:%' AND owner_id <> '${want}';" 2>/dev/null \
				| sed -n 's/^UPDATE //p')"
			total=$((total + ${n:-0}))
		done < <(docker exec "${PG_CTN}" psql -U postgres -d "${db}" -tAc \
			"SELECT table_name FROM information_schema.columns
			  WHERE column_name='owner_id' AND table_schema='public';" 2>/dev/null)
	done
	note "postgres: re-stamped ${total} rows"
}

mysql_pw() {
	docker inspect "${MYSQL_CTN}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
		| sed -n 's/^MYSQL_ROOT_PASSWORD=//p' | head -1
}

restamp_mysql() {
	local want="$1" db pw t total=0 n
	running "${MYSQL_CTN}" || { note "mysql not running — skipped"; return; }
	pw="$(mysql_pw)"
	for db in ${MYSQL_DBS}; do
		while read -r t; do
			[ -n "${t}" ] || continue
			docker exec "${MYSQL_CTN}" mysql -uroot -p"${pw}" -N -B -e \
				"UPDATE \`${db}\`.\`${t}\` SET owner_id='${want}'
				  WHERE owner_id LIKE 'api-key:%' AND owner_id <> '${want}';" 2>/dev/null || true
			n="$(docker exec "${MYSQL_CTN}" mysql -uroot -p"${pw}" -N -B -e \
				"SELECT ROW_COUNT();" 2>/dev/null || echo 0)"
			total=$((total + ${n:-0}))
		done < <(docker exec "${MYSQL_CTN}" mysql -uroot -p"${pw}" -N -B -e \
			"SELECT table_name FROM information_schema.columns
			  WHERE column_name='owner_id' AND table_schema='${db}';" 2>/dev/null)
	done
	note "mysql: re-stamped rows in ${MYSQL_DBS}"
}

mongo_args() {
	local u p
	u="$(docker inspect "${MONGO_CTN}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
		| sed -n 's/^MONGO_INITDB_ROOT_USERNAME=//p' | head -1)"
	p="$(docker inspect "${MONGO_CTN}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
		| sed -n 's/^MONGO_INITDB_ROOT_PASSWORD=//p' | head -1)"
	printf '%s\n%s\n' "${u}" "${p}"
}

restamp_mongo() {
	local want="$1" db u p out
	running "${MONGO_CTN}" || { note "mongo not running — skipped"; return; }
	{ read -r u; read -r p; } < <(mongo_args)
	for db in ${MONGO_DBS}; do
		out="$(docker exec "${MONGO_CTN}" mongosh --quiet -u "${u}" -p "${p}" \
			--authenticationDatabase admin --eval "
				const d = db.getSiblingDB('${db}');
				let n = 0;
				d.getCollectionNames().forEach(c => {
					n += d[c].updateMany(
						{ owner_id: { \$regex: '^api-key:', \$ne: '${want}' } },
						{ \$set: { owner_id: '${want}' } }
					).modifiedCount;
				});
				print(n);
			" 2>/dev/null | tail -1)"
		note "mongo ${db}: re-stamped ${out:-0} documents"
	done
}

# mssql_sql DB SQL — sqlcmd as sa inside the container. The password is the container's own
# MSSQL_SA_PASSWORD, handed to sqlcmd there, so it is on no argv and in no output here.
mssql_sql() {
	docker exec -e "Q=SET NOCOUNT ON; $2" "${MSSQL_CTN}" sh -c \
		'PATH="/opt/mssql-tools18/bin:/opt/mssql-tools/bin:$PATH" SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" \
		sqlcmd -S localhost -U sa -C -b -d "$0" -h -1 -W -Q "$Q"' "$1"
}

# mssql_per_owner_table WANT count|restamp — over every owner_id table of MSSQL_DBS, the rows
# another api-key principal owns (count), or how many of them moved onto WANT (restamp).
mssql_per_owner_table() {
	local stale="owner_id LIKE 'api-key:%' AND owner_id <> '$1'" db t
	for db in ${MSSQL_DBS}; do
		while read -r t; do
			[ -z "${t}" ] || case "$2" in
			count) mssql_sql "${db}" "SELECT count(*) FROM ${t} WHERE ${stale};" ;;
			restamp) mssql_sql "${db}" "UPDATE ${t} SET owner_id = '$1' WHERE ${stale}; SELECT @@ROWCOUNT;" ;;
			esac
		done < <(mssql_sql "${db}" "SELECT QUOTENAME(TABLE_SCHEMA) + '.' + QUOTENAME(TABLE_NAME)
			FROM INFORMATION_SCHEMA.COLUMNS WHERE COLUMN_NAME = 'owner_id';")
	done | awk '{s+=$1} END {print s+0}'
}

stale_mssql() {
	running "${MSSQL_CTN}" || { printf '0'; return; }
	mssql_per_owner_table "$1" count
}

restamp_mssql() {
	running "${MSSQL_CTN}" || { note "mssql not running — skipped"; return; }
	note "mssql: re-stamped $(mssql_per_owner_table "$1" restamp) rows in ${MSSQL_DBS}"
}
