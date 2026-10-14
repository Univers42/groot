# Playwright image + openbox (maximize/minimize need a window manager) + certutil: Electron's Chromium reads the NSS db for TLS trust, and the
# dev CA must go there instead of using --ignore-certificate-errors (which hides TLS bugs).
FROM mcr.microsoft.com/playwright:v1.49.1-jammy
RUN apt-get update && apt-get install -y --no-install-recommends libnss3-tools openbox \
    && rm -rf /var/lib/apt/lists/*
