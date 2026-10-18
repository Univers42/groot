# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    calendar.mk                                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 20:57:56 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 20:57:57 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Calendar service targets.
calendar-up: docker-prefetch-images
## Start osionos Calendar and the Google Calendar bridge with Docker Compose.
	$(MAKE) compose-build BAKE_GROUP=calendar BAKE_TARGETS='calendar'
	docker compose up -d --no-build --pull never calendar calendar-bridge

calendar-logs:
## Follow osionos Calendar and Google Calendar bridge logs.
	docker compose logs -f calendar calendar-bridge

calendar-down:
## Stop osionos Calendar and the Google Calendar bridge containers.
	docker compose stop calendar calendar-bridge