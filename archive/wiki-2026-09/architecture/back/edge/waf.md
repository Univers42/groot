a WAF(web application firewall) protects the application form application layer attacks (HTTP/HTTPS). while it may work alongside NGINX and handle TLS termination its main job is security, not just routing or encryption.

- NGINX: Reverse proxy, load balancing, routing, serving static files, optionally TLS termination
- TLS/SSL Certificate (CA) Encrypts between client and server (HTTPS)
WAF inspects HTTP requests and block malicious traffic and server (HTTPS)
WAF --> inspects HTTP requests and block malicious traffix (SQL injections, XSS, bots, etc.)

WAF Typical role is:
- BLOCK sql injection attempts
- block cross-site-scripting
- rate limit abusive clients.
- filter malivious bots.
- enforce security rules.

## what it really is in our backend
waf is used as nginx + ModSecurity + OWASP CRS
it handles the TLS termination, L7 attack filtering , real-IP, CORS-403
