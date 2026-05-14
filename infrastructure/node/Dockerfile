# syntax=docker/dockerfile:1.7
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Dockerfile                                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/02 23:33:05 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/04 00:37:09 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

FROM public.ecr.aws/docker/library/node:22-alpine

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
	apk add --update-cache python3 build-base cmake git bash \
	&& ln -sf /usr/bin/python3 /usr/bin/python \
	&& corepack enable \
	&& corepack prepare pnpm@10.32.1 --activate

WORKDIR /app
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
	&& chown -R node:node /app

USER node

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
