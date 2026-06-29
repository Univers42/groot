PostgREST is a server that automatically turns a PostgreSQL into a REST API. isntead of writing backend endpoint ourself, PosttGREST exposes the databases tables and functions as HTTP endpoints

A REST API is a way for application to communicated over HTTP using standard methods:
- `GET` -> read data
- `POST` -> create data
- `PATCH` -> update data
- `DELETE` -> delete data

Example: 
```md
GET /users
```

return all users.

POST /users
{
    "name": "Alice"
}

CREATES new user

So,PostgREST = a tool that automaticaly create a REST API form our postgreSQL.. so that means 


# Express
```js
app.get("/users", async (req, res) )=> {
    const users = await db.query("SELECT * FROM users");
    res.json(users.rows);
}
``` 

we are responsible for :
- writing every endpoint.
- writing SQL queries
- validatijg input
- Checking permissions
- formatting responses.

with POSTGREST automatically we provide 
GET /users
GET /users?id=eq.1
POST /users?id=eq.1
DELETE /users?id=eq.1

