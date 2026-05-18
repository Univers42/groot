# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    database.mk                                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 20:58:08 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 20:58:09 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Database maintenance targets.
db-password-check:
## Verify apps/baas/.env.local matches the live Postgres password without printing it.
	@set -eu; set -a; . apps/baas/.env.local; set +a; \
	docker compose exec -T -e PGPASSWORD="$$POSTGRES_PASSWORD" postgres psql -h 127.0.0.1 -U "$${POSTGRES_USER:-postgres}" -d "$${POSTGRES_DB:-postgres}" -tAc 'select 1' >/dev/null; \
	echo 'postgres-password-ok'

db-password-apply:
## Apply POSTGRES_PASSWORD from apps/baas/.env.local to the live Postgres role.
	@set -eu; set -a; . apps/baas/.env.local; set +a; \
	docker compose exec -T -u postgres -e POSTGRES_TARGET_USER="$${POSTGRES_USER:-postgres}" -e POSTGRES_TARGET_PASSWORD="$$POSTGRES_PASSWORD" -e POSTGRES_TARGET_DB="$${POSTGRES_DB:-postgres}" postgres sh -s < apps/baas/scripts/sync-postgres-password.sh; \
	echo 'postgres-password-updated'