Gotrue, c'est un __serveur d'authentification__. Son rôle est de gérer tout le cycle de vide l'identité d'un utilisateur: inscription, connexion, génération de jetons, renouvellement de session et vérifications des utilisateurs.

```json

POST /signup
{
    "email": "alice@example.com",
    "password": "mdp"
}
``` 

gotrue hash le motj de pass avec un algorithme adapté comme Bcrypt
enregistrer l'utilisateur dans sa base de données (ou celle de notre projjet)
peut envoyer un email de confirmation


```json
POST  /token?grant_type=password
{
    "email": "alice@example.com",
    "password": "motdepasse"
}

```

GoTrue:
1. Récupère le hash du mot de passe
2. compare
3. si valide ca pass.

# après authentificaiton:

```JSON
{
    "sub": "user-id",
    "email": "dev@ex.com",
    "role":"authenticated",
    "exp": 178000000000
}
``` 

puis GoTrue signe ce JWT avec une clé secrète (HS256) OU une paire de clés (RS256/EdDSA selong la configuration)

## Verification du JWT
quand le client appelle une API:
authorization: Bearer eyfhajfouJJHDFJAO
l'API vérifie :
    - la signature;
    - la date d'expiration;
    - l'émetteur (iss);
    - l'audience (aud) si nécessaire.
si le JWT est valide, l'utilisateur est considéré comme authentifié.

## Refresh token
quand l'access token expire:

```JSON
POST /token?grant_type=refresh_token
```

Le client envoie le Refresh Token

GoTrue: 
- verifier qu'il est toujours valide;
- génère un un nouvel access token;
- peut également émettre un nouveau Refresh token (rotation) aisni, l'utilisateur n'a pas besoin de resaisir son mot de passe.


## Scenario
Gotrue est le composant principal d'authentificaion de l'écosystèm egrobase. Lorsqu'un utilisateur se connecte:
1. le SDK Supabase appelle GoTrue;
2. gotrue authentifie l'utilisateur;
Gotrue renvoie un JWT
3. CE JWT est transmis automatiquement à PostgREST;
