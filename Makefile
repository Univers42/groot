# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 20:57:38 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 20:57:41 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Makefile coordinator for Track Binocle infrastructure.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

MAKE_DIR := infrastructure/makes

include $(MAKE_DIR)/common.mk
include $(MAKE_DIR)/pipeline.mk
include $(MAKE_DIR)/repo.mk
include $(MAKE_DIR)/certs.mk
include $(MAKE_DIR)/certs-doctor.mk
include $(MAKE_DIR)/docker-build.mk
include $(MAKE_DIR)/compose.mk
include $(MAKE_DIR)/docker.mk
include $(MAKE_DIR)/vault.mk
include $(MAKE_DIR)/vault-invite.mk
include $(MAKE_DIR)/vault-shared.mk
include $(MAKE_DIR)/vault-shared-repair.mk
include $(MAKE_DIR)/vault-session-auth.mk
include $(MAKE_DIR)/vault-session-admin.mk
include $(MAKE_DIR)/vault-session-tokens.mk
include $(MAKE_DIR)/vault-session-aliases.mk
include $(MAKE_DIR)/fly.mk
include $(MAKE_DIR)/vault-auth.mk
include $(MAKE_DIR)/vault-recovery.mk
include $(MAKE_DIR)/env.mk
include $(MAKE_DIR)/database.mk
include $(MAKE_DIR)/app.mk
include $(MAKE_DIR)/playground.mk
include $(MAKE_DIR)/mail.mk
include $(MAKE_DIR)/calendar.mk
include $(MAKE_DIR)/baas.mk
include $(MAKE_DIR)/agency.mk
include $(MAKE_DIR)/gourmand.mk
include $(MAKE_DIR)/baas-release.mk
include $(MAKE_DIR)/baas-verify.mk
