kong

/auth --> Gotrue
/rest/v1 --> PostgREST
/storage        -> Storage
/realtime       -> Realtime
/fucntions      -> Edge Functions

why OpenResty (Nginx + Lua) ?
kong is built on OpenResty, which is essentially :
nginx -> handles HTTP traffice essentially
LUA -> lets kong exectue custom logic on every request.

## What does kong do ?
suppose the client sends:

```json
GET /rest/v1/users
Authorization: Bearer <JWT>
apikey: anon-key

``` 


if then:

1. Matches the route
- `/rest/v1/*` -> send to PostgREST
2. Runs plugins
- check the apikey
- validate teh JWT (if configured)
- Apply rate limits.
- Handle CORS.
- Log the request.

> kongg is used into trusterr internal work. it doesn't need to perform TLS itself. 

