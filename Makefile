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

# common.mk holds the variables other modules read while they are parsed and
# pipeline.mk holds `make all`, so both load first; every other module loads
# itself by being in the directory.
include $(MAKE_DIR)/common.mk $(MAKE_DIR)/pipeline.mk
include $(sort $(filter-out $(MAKE_DIR)/common.mk $(MAKE_DIR)/pipeline.mk,$(wildcard $(MAKE_DIR)/*.mk)))

# Documented targets are commands, not files (./playground is a directory).
.PHONY: $(MAKE_HELP_PHONY)

# `all` is an ordered prerequisite list (secrets, backend, env, frontends,
# healthcheck); under -j make would start them together. Nothing here is
# written for parallel runs.
.NOTPARALLEL:
