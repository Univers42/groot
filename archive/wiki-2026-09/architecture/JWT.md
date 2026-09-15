the JWT (json web token) is  like a digital signed ID  CARD.

Once we log in, the server give us a token. we then send it

# a JWT has 3 parts
xxxxxx.yyyyyyy.zzzzzz

it has 3 parts:
1. header -> algorithm info
2. payload -> user data
3. signature -> proof it wasn't tampered with

Example:
{
    "sub": "user_123",
    "email": "dev@dev.com",
    "role": "authenticated",
    "exp":1700000
}

without JWT it would look like like:
Client -> Login -> Server remembers session in