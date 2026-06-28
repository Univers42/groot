# Users and Roles

MongoDB enforces access control through **users** and **roles**. A user is always created in a
specific database (its *authentication database*). A role grants privileges (allowed actions on
specific resources) and can be assigned to a user.

---

## Where users live — `authSource` explained

MongoDB does not have a single global user table. Every user record lives in a specific database.
The root user (from `MONGO_INITDB_ROOT_USERNAME`) lives in `admin`. Application users typically
live in the database they need to access, or also in `admin` for cross-database roles.

When connecting, `--authenticationDatabase` (also called `authSource` in a URI) tells MongoDB
which database to look in for the user's record. Getting this wrong produces
`Authentication failed` even with correct credentials.

```
mongodb://shop_app:secret@host:27017/learn_cli?authSource=learn_cli
                                                          ^^^^^^^^^
                                             look here for the "shop_app" user record
```

---

## Built-in roles (most useful subset)

| Role | Scope | What it allows |
|------|-------|----------------|
| `read` | per-db | `find`, `listCollections`, `listIndexes` |
| `readWrite` | per-db | All `read` actions + insert, update, delete, `createCollection`, `createIndex` |
| `dbAdmin` | per-db | `createCollection`, `dropCollection`, `createIndex`, `dropIndex`, `dbStats`, `collStats`, `compact` — but NO data access |
| `userAdmin` | per-db | Create and manage users and roles in that database |
| `readAnyDatabase` | admin db | `read` across all databases |
| `readWriteAnyDatabase` | admin db | `readWrite` across all databases |
| `dbAdminAnyDatabase` | admin db | `dbAdmin` across all databases |
| `userAdminAnyDatabase` | admin db | Manage users in all databases |
| `root` | admin db | Superuser — all of the above |

Roles tagged "admin db" must be granted from the `admin` database.

---

## Creating a user

`db.createUser` is called in the database where the user record should live.

```js
// in a .js file
use("learn_cli");

db.createUser({
  user: "shop_app",
  pwd:  "shop_app_secret_123",    // never hardcode in real code — read from env
  roles: [
    { role: "readWrite", db: "learn_cli" }
  ]
});
```

Now `shop_app` can connect with `--authenticationDatabase learn_cli`:

```bash
docker exec -it mini-baas-mongo sh -lc \
  'mongosh -u shop_app -p shop_app_secret_123 \
   --authenticationDatabase learn_cli learn_cli'
```

---

## Listing and inspecting users

```js
use("learn_cli");

// All users in this database
db.getUsers()
// { users: [{ user: "shop_app", ... }], ok: 1 }

// Specific user
db.getUser("shop_app")
```

---

## Granting additional roles

```js
use("learn_cli");

// Give shop_app dbAdmin as well
db.grantRolesToUser(
  "shop_app",
  [{ role: "dbAdmin", db: "learn_cli" }]
);
```

---

## Updating a user (e.g., rotating the password)

```js
use("learn_cli");

db.updateUser("shop_app", {
  pwd: "new_secure_password_789"
});
```

You can also update `roles` inside `updateUser`; the new role list **replaces** the existing one,
so list all desired roles explicitly.

---

## Custom roles

When built-in roles are too broad, define a role that grants exactly the actions you need on
exactly the collections you allow.

```js
use("learn_cli");

db.createRole({
  role: "shop_reader",
  privileges: [
    {
      resource: { db: "learn_cli", collection: "products" },
      actions:  ["find"]
    },
    {
      resource: { db: "learn_cli", collection: "orders" },
      actions:  ["find"]
    }
  ],
  roles: []   // inherit from no existing role
});

// Assign to a user
db.createUser({
  user: "shop_readonly",
  pwd:  "read_only_pass_456",
  roles: [{ role: "shop_reader", db: "learn_cli" }]
});

// List custom roles
db.getRoles()
```

---

## Dropping users and roles

```js
use("learn_cli");

db.dropUser("shop_app");
db.dropUser("shop_readonly");
db.dropRole("shop_reader");
```

---

## Scenario — `shop_app` user on `learn_cli`

```bash
cat > /tmp/user_scenario.js << 'EOF'
use("learn_cli");

// Clean state
try { db.dropUser("shop_app");      } catch(e) {}
try { db.dropUser("shop_readonly"); } catch(e) {}
try { db.dropRole("shop_reader");   } catch(e) {}

// App user — full read-write on learn_cli
db.createUser({
  user: "shop_app",
  pwd:  "shop_app_secret_123",
  roles: [{ role: "readWrite", db: "learn_cli" }]
});
print("shop_app created");

// Custom read-only role for reporting
db.createRole({
  role: "shop_reader",
  privileges: [
    { resource: { db: "learn_cli", collection: "products" }, actions: ["find"] },
    { resource: { db: "learn_cli", collection: "orders"   }, actions: ["find"] }
  ],
  roles: []
});
print("shop_reader role created");

db.createUser({
  user: "shop_readonly",
  pwd:  "read_only_pass_456",
  roles: [{ role: "shop_reader", db: "learn_cli" }]
});
print("shop_readonly created");

// Inspect
var users = db.getUsers().users.map(u => u.user + ":" + u.roles.map(r => r.role).join(","));
print("users:", JSON.stringify(users));

var roles = db.getRoles().roles.map(r => r.role);
print("custom roles:", JSON.stringify(roles));

// Rotate shop_app password
db.updateUser("shop_app", { pwd: "rotated_password_xyz" });
print("password rotated");

// Grant dbAdmin to shop_app
db.grantRolesToUser("shop_app", [{ role: "dbAdmin", db: "learn_cli" }]);
var updated = db.getUser("shop_app").roles.map(r => r.role);
print("shop_app roles after grant:", JSON.stringify(updated));

// Cleanup
db.dropUser("shop_app");
db.dropUser("shop_readonly");
db.dropRole("shop_reader");
db.dropDatabase();
print("done");
EOF
docker cp /tmp/user_scenario.js mini-baas-mongo:/tmp/user_scenario.js
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet /tmp/user_scenario.js'
```

Expected output:

```
shop_app created
shop_reader role created
shop_readonly created
users: ["shop_readonly:shop_reader","shop_app:readWrite"]
custom roles: ["shop_reader"]
password rotated
shop_app roles after grant: ["readWrite","dbAdmin"]
done
```

---

## Gotchas / Docker notes

- **`use("learn_cli"); db.createUser(...)` creates the user in `learn_cli`**, not in `admin`.
  When the app connects it must use `authSource=learn_cli` (or `--authenticationDatabase learn_cli`),
  not `admin`. Forgetting this is the number-one auth gotcha.
- **`updateUser` roles replace, not append.** If you only want to add a role, use
  `grantRolesToUser` instead.
- **`userAdmin` does not grant data access.** A `userAdmin` can create and drop users in its
  database but cannot `find` documents. Pair it with `dbAdmin` or `readWrite` if needed.
- **Password complexity** — MongoDB does not enforce a password policy by default. The application
  layer or the deployment tooling must enforce it.
- **The root account** (`MONGO_INITDB_ROOT_USERNAME`) is your emergency key. In production,
  disable direct root connections over the network and only use application-scoped users.

---

[README](README.md) | [00-connect.md](00-connect.md) | [01-crud.md](01-crud.md) |
[02-indexes.md](02-indexes.md) | [03-aggregation-views.md](03-aggregation-views.md) |
[05-security.md](05-security.md) | [06-backup-restore.md](06-backup-restore.md)
