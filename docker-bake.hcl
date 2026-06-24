# Frontends-only: the backend (postgres/kong/etc.) lives in the standalone
# grobase stack now, so the root bake no longer builds it.
group "default" {
  targets = [
    "osionos-app",
    "mail",
    "calendar",
    "opposite-osiris-node",
  ]
}

group "secrets" {
  targets = ["vault"]
}

group "testing" {
  targets = [
    "osionos-app",
    "mail",
    "calendar",
    "opposite-osiris-node",
    "playground-simulation",
  ]
}

group "playground" {
  targets = ["playground-simulation"]
}

target "vault" {
  context    = "./apps/baas/mini-baas-infra/docker/services/vault"
  dockerfile = "Dockerfile"
  tags = [
    "track-binocle-vault:local",
  ]
}

target "osionos-app" {
  context    = "./apps/osionos/app"
  dockerfile = "docker/services/node/Dockerfile"
  tags       = ["track-binocle/osionos-app:local"]
}

target "mail" {
  context    = "./apps/mail"
  dockerfile = "Dockerfile"
  target     = "dev"
  tags = [
    "track-binocle/mail:local",
    "track-binocle/mail-bridge:local",
  ]
}

target "calendar" {
  context    = "./apps/calendar"
  dockerfile = "Dockerfile"
  target     = "dev"
  tags = [
    "track-binocle/calendar:local",
    "track-binocle/calendar-bridge:local",
  ]
}

target "opposite-osiris-node" {
  context    = "."
  dockerfile = "apps/opposite-osiris/docker/services/node/Dockerfile"
  tags = [
    "track-binocle/opposite-osiris-deps:local",
    "track-binocle/auth-gateway:local",
    "track-binocle/opposite-osiris:local",
  ]
}

target "playground-simulation" {
  context    = "./apps/osionos/app"
  dockerfile = "docker/services/browser-tests/Dockerfile"
  tags       = ["track-binocle/playground-simulation:local"]
}
group "grobase" {
  targets = ["grobase-site"]
}

target "grobase-site" {
  context    = "./apps/grobase/vendor/grobase-website"
  dockerfile = "Dockerfile"
  target     = "dev"
  tags       = ["track-binocle/grobase-site:local"]
}
