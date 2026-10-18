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

MAKE_DIR := utils/mk

include $(MAKE_DIR)/common.mk
include $(MAKE_DIR)/pipeline.mk
include $(MAKE_DIR)/repo.mk
include $(MAKE_DIR)/certs.mk
include $(MAKE_DIR)/certs-doctor.mk
include $(MAKE_DIR)/docker-build.mk
include $(MAKE_DIR)/docker.mk
include $(MAKE_DIR)/vault42-recover.mk
include $(MAKE_DIR)/app.mk
include $(MAKE_DIR)/playground.mk
include $(MAKE_DIR)/mail.mk
include $(MAKE_DIR)/calendar.mk
include $(MAKE_DIR)/drawnosaurus.mk
include $(MAKE_DIR)/baas.mk
include $(MAKE_DIR)/agency.mk
include $(MAKE_DIR)/grobase.mk
include $(MAKE_DIR)/grobase-link.mk
include $(MAKE_DIR)/prettier.mk
include $(MAKE_DIR)/update.mk
include $(MAKE_DIR)/e2e.mk
