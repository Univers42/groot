// fake-kong.mjs — stands in for Kong + adapter-registry + GoTrue admin in the vm-bootstrap bats
// fixture. It runs inside the fixture's postgres container and keeps its state in that
// database, so the bootstrap's SQL reads see what its HTTP writes made, as on baas. It checks
// the same credentials baas does (service key for /admin/v1, public key plus service bearer
// for GoTrue admin) and answers 201/409 the way adapter-registry does (handler.go:74).
import { execFileSync } from 'node:child_process';
import { createServer } from 'node:http';

const SERVICE = process.env.KONG_SERVICE_API_KEY;
const PUBLIC = process.env.KONG_PUBLIC_API_KEY;

function sql(text, vars = {}) {
	const args = ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'];
	for (const [k, v] of Object.entries(vars)) args.push('-v', `${k}=${v}`);
	return execFileSync('psql', args, { input: text, encoding: 'utf8' }).trim();
}

function send(res, code, body) {
	res.writeHead(code, { 'content-type': 'application/json' });
	res.end(JSON.stringify(body));
}

async function readBody(req) {
	let raw = '';
	for await (const chunk of req) raw += chunk;
	return raw ? JSON.parse(raw) : {};
}

async function databases(req, res) {
	if (req.headers.apikey !== SERVICE) return send(res, 403, { error: 'acl' });
	const tenant = req.headers['x-tenant-id'];
	if (!tenant) return send(res, 401, { error: 'no tenant' });
	if (req.method === 'GET') {
		const rows = sql("select coalesce(json_agg(json_build_object('id', id, 'name', name, 'engine', engine)), '[]') from tenant_databases where tenant_id = :'t';", { t: tenant });
		return send(res, 200, JSON.parse(rows));
	}
	const body = await readBody(req);
	const id = sql("insert into tenant_databases (tenant_id, engine, name, connection_string) values (:'t', :'e', :'n', :'d') on conflict (tenant_id, name) do nothing returning id;", { t: tenant, e: body.engine, n: body.name, d: body.connection_string });
	return id ? send(res, 201, { id, name: body.name }) : send(res, 409, { error: 'conflict' });
}

async function users(req, res) {
	if (req.headers.apikey !== PUBLIC || req.headers.authorization !== `Bearer ${SERVICE}`) return send(res, 401, { error: 'auth' });
	const body = await readBody(req);
	if (body.email_confirm !== true) return send(res, 400, { error: 'unconfirmed' });
	const id = sql("insert into auth.users (email) values (:'e') on conflict (email) do nothing returning id;", { e: body.email });
	return id ? send(res, 201, { id, email: body.email }) : send(res, 422, { error: 'email_exists' });
}

createServer(async (req, res) => {
	try {
		if (req.url === '/admin/v1/databases') return await databases(req, res);
		if (req.url === '/auth/v1/admin/users' && req.method === 'POST') return await users(req, res);
		return send(res, 404, { error: 'no route' });
	} catch (error) {
		return send(res, 500, { error: String(error.message).slice(0, 200) });
	}
}).listen(8000);
