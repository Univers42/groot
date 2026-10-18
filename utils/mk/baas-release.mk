# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    baas-release.mk                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 20:57:48 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 20:57:49 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# BaaS SMTP release target.
baas-release-smtp:
## Build and publish the SMTP-enabled BaaS wrapper image, then run SMTP smoke tests.
	docker build -f $(BAAS_DOCKERFILE) -t $(BAAS_SMTP_IMAGE):$(BAAS_SMTP_VERSION) -t $(BAAS_SMTP_IMAGE):latest $(BAAS_CONTEXT)
	docker push $(BAAS_SMTP_IMAGE):$(BAAS_SMTP_VERSION)
	docker push $(BAAS_SMTP_IMAGE):latest
	cd $(FRONTEND_DIR) && npm run test:smtp && npm run test:email
	@echo "Published SMTP-enabled BaaS image $(BAAS_SMTP_IMAGE):$(BAAS_SMTP_VERSION) and latest."