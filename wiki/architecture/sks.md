by hand (raw):

const res = await fetch('https://api/<url>?owner_id=eq.42', {
    method: 'POST',
    headers: {
        'apikey': PUBLIC_KEY,
        'Authorization': `Bearer ${session.access_token}`, // we manage refresh ourself 
    }
})

with the SDK:

```bash
const row = await grobase.from('projects').insert({ name: 'demo' }); // typed, auth + errors handled
```

