# Security

## Reporting a vulnerability

Please do not publish browser cookies, CSRF values, bridge tokens, or other private data in a public issue. Open a minimal private security advisory on GitHub, or contact the maintainer through the e-mail address listed on the GitHub profile.

## Security model

- The Chromium extension talks only to `https://www.bilibili.com/*` and `http://127.0.0.1:17373/*`.
- The app listens on the loopback interface only.
- `scripts/build.sh` creates a random bridge token in `.build/bridge-token` and injects the same token into the app and extension build products.
- Bilibili cookies and CSRF values stay in the browser page context and are not sent to the native app.
- Account writes require an explicit in-app confirmation.
