CORS HEADER tell the browser which websites are allowed to access your API.

imagine: 

- Frontend: `https://myapp.com`
- API: `https://api.myapp.com`

when the frontend makes a request, the browser asks.
"is `https://myapp.com` allowed to call this API`

the API answers using CORS headers.

COMMON CORS headers

## WHY kong handles CORS

instead of every backend service implemetnting these headers, kong can automatically :
- Reply to `OPTIONS` preflight requests.
- Add the correct `Access-Control-*` headers to responses
- Ensure all our APIs have consisten CORS behavior

```javascript

app.use((req, res, next)) => {
    res.setHeader("Access-Control-Allow-Origin", "https://myapp.com");
    res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE");
    if (req.method === "OPTIONS") {
        return (res.sendStatus(204);
        )
    next();
    }

    //JWT verification
    app.use((req, res, next)) => {
        const token = req.headers.authorization?.split(" ")[1];
        try {
            jwt.verify(token, JWT_SECRET);
            next();
        } catch {
            res.sendStatus(401);
        }
    }
});

every service would need similar code
```

```yaml
services:
    - name: postgrest
    url: http://postgrest:3000
    routes:
        - paths:
            - rest/v1
    plugins:
        - name: cors
        - name: jwt
        - name: rate-limiting


``` 

```javascript
// NO CORS
// NO JWT
// NO rate limiting
// kong already handle those before forwarding the request.
app.get("/users", async (req, res) => {
    const users = await db.query("SELECT * FROM users");
    res.json(users.rows);
})

``` 