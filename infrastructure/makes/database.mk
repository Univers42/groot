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
# Postgres and its password lifecycle now live in the standalone apps/grobase
# stack, so the root no longer owns these.
db-password-check:
## Deprecated at root: Postgres now lives in apps/grobase.
	@echo "[skip] db-password-check now lives in apps/grobase"

db-password-apply:
## Deprecated at root: Postgres now lives in apps/grobase.
	@echo "[skip] db-password-apply now lives in apps/grobase"