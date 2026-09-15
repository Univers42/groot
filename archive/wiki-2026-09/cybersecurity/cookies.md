at their core, **cookies** are small text files that websites store on our computer or mobile device to remember specific information about us.
To understand exactly why they exist, we need to know one fundamental rule about how the internet works: **The web is stateless**.
Every time we click a link or load a new page, the web treats us as a completely new visitor who has never been there before.
Cookies asct as the website's memory, giving you a persistent identitiy and making our browsing experience smooth.

---
## The main purpose of cookies
Webites use cookies for three primary purposes:
- **Session management (Authentication)**
	- **purpose**: to keep use logged in
	- **how it works**: When we enter our username and password, the server creates a secure session ID and stores it in a cookie. when we navigate to other pages, our browser sends that cookie back to the server, allowing the website to recognize that we are authenticated without asking for credentials on every page..
- **Personalization and preferences**:
	- **purpose**: to remember our settings and preferences
	- **how it works**: Cookies can store information about our language preference, theme choice, or items in a shopping cart. This way, when we return to the website, it can provide a personalized experience based on our previous interactions.
- **Analytics and tracking**:
	- **purpose**: to understand how users interact with the website
	- **how it works**: Cookies can collect data about our browsing behavior, such as which pages we visit, how long we stay, and what links we click. This information helps website owners improve their site and provide relevant content or advertisements.


|category|lifespan|function|
|---|---|---|
|First-party cookies|can be session-based (deleted when the browser is closed) or persistent (remain until a set expiration date)|used by the website we are visiting to remember our preferences, login status, and other information relevant to our experience on that site|
|Third-party cookies|can also be session-based or persistent|set by domains other than the
|session cookies|deleted when the browser is closed|used to maintain our session state, such as keeping us logged in or remembering items in a shopping cart|
|persistent cookies|remain on our device until a set expiration date or until we manually delete them|used to remember our preferences and settings across multiple visits to the website|

in short, wihtout cookies, the modern web would feel like visiting a new website every time we click on a new page, requiring us to log in repeatedly adn start from scratch