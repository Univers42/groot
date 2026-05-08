# Astro Starter Kit: Basics

```sh
npm create astro@latest -- --template basics
```

> 🧑‍🚀 **Seasoned astronaut?** Delete this file. Have fun!

## 🚀 Project Structure

Inside of your Astro project, you'll see the following folders and files:

```text
/
├── public/
│   └── favicon.svg
├── src
│   ├── assets
│   │   └── astro.svg
│   ├── components
│   │   └── Welcome.astro
│   ├── layouts
│   │   └── Layout.astro
│   └── pages
│       └── index.astro
└── package.json
```

To learn more about the folder structure of an Astro project, refer to [our guide on project structure](https://docs.astro.build/en/basics/project-structure/).

## 🧞 Commands

All commands are run from the root of the project, from a terminal:

| Command                   | Action                                           |
| :------------------------ | :----------------------------------------------- |
| `npm install`             | Installs dependencies                            |
| `npm run dev`             | Starts local dev server at `localhost:4321`      |
| `npm run build`           | Build your production site to `./dist/`          |
| `npm run preview`         | Preview your build locally, before deploying     |
| `npm run astro ...`       | Run CLI commands like `astro add`, `astro check` |
| `npm run astro -- --help` | Get help using the Astro CLI                     |

## Local HTTPS on localhost

The secure local endpoint is `https://localhost:4322/`. Generate and trust the mini-baas-infra development CA once, then start the HTTPS dev server:

```sh
npm run cert:localhost
npm run cert:trust
npm run dev:https
```

After `npm run cert:trust`, restart the browser so Chromium/Firefox reload the local CA trust store. If a plain HTTP dev server is already using port `4322`, stop it before running `npm run dev:https`; otherwise browsers can report `ERR_SSL_PROTOCOL_ERROR` because the HTTPS URL is talking to an HTTP listener.

For this workspace, `.env.local` can also set `ASTRO_DEV_HTTPS=true` and `PUBLIC_SITE_URL=https://localhost:4322`, which makes `npm run dev` serve HTTPS on the same port.

## 👀 Want to learn more?

Feel free to check [our documentation](https://docs.astro.build) or jump into our [Discord server](https://astro.build/chat).
